import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:altranscribe/data/services/cloud/cloud_live.dart'
    show CloudLiveText;
import 'package:altranscribe/data/services/models/model_catalog.dart';

import 'whisper_service.dart';

/// NVIDIA's Nemotron streaming transducers through sherpa-onnx. Decoding runs
/// in a worker isolate, so neither captions nor the interface wait on the
/// model, and quiet audio is brought up to a working level before it is fed.
class NemotronEngine implements SpeechEngine {
  NemotronEngine({this.libraryPath, int? threads})
    : threads = threads ?? defaultThreads;

  /// Folder holding `sherpa-onnx-c-api` and ONNX Runtime; null lets the
  /// package find the libraries bundled with the app.
  final String? libraryPath;
  final int threads;
  @override
  String backend = 'Nemotron';
  _Worker? _worker;
  NemotronModel? model;
  int _streamIds = 0;

  bool get running => _worker != null;

  /// Half the cores, within two and eight: enough for real time without
  /// starving capture and the interface.
  static int get defaultThreads => math.min(
    Platform.isAndroid ? 4 : 8,
    math.max(2, Platform.numberOfProcessors ~/ 2),
  );

  /// [modelPath] is the folder of one [NemotronModel]; [executable] and
  /// [compute] are Whisper concerns and ignored.
  @override
  Future<void> start(
    String executable,
    String modelPath,
    Directory directory, {
    ComputeMode compute = ComputeMode.automatic,
  }) async {
    await stop();
    final folder = Directory(modelPath);
    final id = folder.path
        .split(RegExp(r'[/\\]'))
        .where((part) => part.isNotEmpty)
        .lastOrNull;
    final entry = ModelCatalog.nemotronModels
        .where((item) => item.id == id)
        .firstOrNull;
    final files =
        entry?.files.map((file) => file.name) ?? NemotronModel.fileNames;
    for (final name in files) {
      if (!await File('${folder.path}/$name').exists()) {
        throw const FormatException('nemotronModelMissing');
      }
    }
    // A folder outside the catalog (a manual export) is told apart by its
    // vocabulary: the multilingual model carries far more tokens.
    final multilingual =
        entry?.multilingual ??
        await File('${folder.path}/tokens.txt').length() > 40000;
    final worker = await _Worker.spawn(libraryPath);
    try {
      await worker.call({
        'op': 'load',
        'dir': folder.path,
        'threads': threads,
        'multilingual': multilingual,
      });
    } catch (_) {
      worker.kill();
      rethrow;
    }
    _worker = worker;
    model = entry;
    backend = 'CPU · Nemotron · ${entry?.shortLabel ?? id}';
  }

  /// Whole-window recognition for files and non-streaming callers.
  @override
  Future<String> transcribe(Uint8List wave, String language) async {
    final worker = _worker;
    if (worker == null) throw StateError('nemotronNotRunning');
    final pcm = wave.length > 44 ? Uint8List.sublistView(wave, 44) : wave;
    final result = await worker.call({
      'op': 'transcribe',
      'pcm': pcm,
      'language': language,
    });
    return result['text'] as String;
  }

  /// A live stream for one capture source. [onText] receives the growing
  /// line and, once the speaker pauses, the finished one; [onAmend] adds
  /// punctuation that the model only settles after a line was finished.
  Future<NemotronLive> openLive({
    required String source,
    required String language,
    required void Function(CloudLiveText) onText,
    void Function(String id, String suffix)? onAmend,
  }) async {
    final worker = _worker;
    if (worker == null) throw StateError('nemotronNotRunning');
    final id = 'nemotron-$source-${_streamIds++}';
    await worker.call({'op': 'open', 'id': id, 'language': language});
    return NemotronLive._(worker, id, source, onText, onAmend);
  }

  @override
  Future<void> stop() async {
    final worker = _worker;
    _worker = null;
    model = null;
    worker?.kill();
  }
}

class _Frame {
  _Frame(this.pcm, this.startMs);
  final Uint8List pcm;
  final int startMs;
  int get durationMs => pcm.length ~/ 32;
}

class _Marker {
  _Marker(this.op);
  final String op;
  final done = Completer<void>();
}

/// One capture source fed frame by frame. Frames and pause or stop markers go
/// through one queue, so audio captured after a resume can never be decoded
/// before the pause that preceded it. Each pause ends the model's stream and
/// starts a fresh one; line times map stream time back to session time.
class NemotronLive {
  NemotronLive._(this._worker, this.id, this.source, this.onText, this.onAmend);
  final _Worker _worker;
  final String id;
  final String source;
  final void Function(CloudLiveText) onText;
  final void Function(String id, String suffix)? onAmend;
  final _queue = Queue<Object>();
  Future<void>? _draining;
  bool _closed = false;
  int _segment = 0;
  String? _lastFinalId;
  String _lastPartial = '';

  /// Where the current stream's audio sits in session time: (stream ms,
  /// session ms) pairs, one more whenever capture skipped ahead.
  final _anchors = <(int, int)>[];
  int _streamMs = 0;
  int _expectedStartMs = 0;

  /// Completes once queued audio has been decoded.
  Future<void> get idle => _draining ?? Future.value();

  /// Audio waiting for the model, in milliseconds; grows when decoding is
  /// slower than real time.
  int get backlogMs => _queue.whereType<_Frame>().fold(
    0,
    (sum, frame) => sum + frame.durationMs,
  );

  void add(Uint8List pcm, int startMs, int endMs) {
    if (_closed) return;
    _queue.add(_Frame(pcm, startMs));
    _pump();
  }

  /// Closes the current line and stream, as when capture pauses.
  Future<void> flush() => _mark('flush');

  /// Delivers whatever is still buffered as a final line and frees the stream.
  Future<void> finish() => _mark('finish');

  Future<void> _mark(String op) {
    if (_closed) return Future.value();
    final marker = _Marker(op);
    _queue.add(marker);
    if (op == 'finish') _closed = true;
    _pump();
    return marker.done.future;
  }

  void _pump() {
    _draining ??= _drain().whenComplete(() => _draining = null);
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final head = _queue.removeFirst();
      if (head is _Marker) {
        try {
          final result = await _worker.call({'op': head.op, 'id': id});
          _handle(result);
          // The next audio starts a new stream at stream time zero.
          _anchors.clear();
          _streamMs = 0;
          head.done.complete();
        } catch (e, s) {
          head.done.completeError(e, s);
        }
        continue;
      }
      // Consecutive frames go in one call; the worker still decides in
      // fixed 100 ms steps, so how frames are grouped changes nothing.
      final frames = <_Frame>[head as _Frame];
      while (_queue.isNotEmpty && _queue.first is _Frame) {
        frames.add(_queue.removeFirst() as _Frame);
      }
      final builder = BytesBuilder(copy: false);
      for (final frame in frames) {
        if (_anchors.isEmpty || (frame.startMs - _expectedStartMs).abs() > 40) {
          _anchors.add((_streamMs, frame.startMs));
        }
        _streamMs += frame.durationMs;
        _expectedStartMs = frame.startMs + frame.durationMs;
        builder.add(frame.pcm);
      }
      final result = await _worker.call({
        'op': 'feed',
        'id': id,
        'pcm': builder.takeBytes(),
      });
      _handle(result);
    }
  }

  int _sessionMs(Object? seconds) {
    final ms = ((seconds as num) * 1000).round();
    var anchor = _anchors.isEmpty ? (0, 0) : _anchors.first;
    for (final candidate in _anchors) {
      if (candidate.$1 > ms) break;
      anchor = candidate;
    }
    return anchor.$2 + ms - anchor.$1;
  }

  void _handle(Map<Object?, Object?> result) {
    for (final event in result['events'] as List? ?? const []) {
      final item = event as Map;
      if (item['type'] == 'amend') {
        final target = _lastFinalId;
        if (target != null) onAmend?.call(target, item['text'] as String);
        continue;
      }
      final start = _sessionMs(item['start']);
      final lineId = '$id-${_segment++}';
      onText(
        CloudLiveText(
          id: lineId,
          source: source,
          text: item['text'] as String,
          startMs: start,
          endMs: math.max(start + 200, _sessionMs(item['end'])),
          finalized: true,
          continues: item['continues'] == true,
          timingEstimated: true,
        ),
      );
      _lastFinalId = lineId;
      _lastPartial = '';
    }
    final partial = result['partial'] as Map?;
    final text = partial?['text'] as String? ?? '';
    if (text.isEmpty || text == _lastPartial) return;
    _lastPartial = text;
    final start = _sessionMs(partial!['start']);
    onText(
      CloudLiveText(
        id: '$id-$_segment',
        source: source,
        text: text,
        startMs: start,
        endMs: math.max(start + 200, _sessionMs(partial['end'])),
        timingEstimated: true,
      ),
    );
  }

  Future<void> cancel() async {
    if (_closed && _queue.isEmpty && _draining == null) return;
    _closed = true;
    for (final item in _queue) {
      if (item is _Marker && !item.done.isCompleted) item.done.complete();
    }
    _queue.clear();
    try {
      await _worker.call({'op': 'close', 'id': id});
    } catch (_) {}
  }
}

/// Samples per decision step: the gain and the line breaks are decided on
/// these fixed 100 ms blocks, never on however much audio arrived at once.
const _block = 1600;

/// Brings quiet speech up to a working level, as the capture path's automatic
/// gain does for live sources: rises over a few blocks, falls at once, never
/// clips.
class _Gain {
  double gain = 1;
  static const target = 0.06;
  static const maximum = 40.0;

  static double rms(Float32List samples) {
    var energy = 0.0;
    for (final sample in samples) {
      energy += sample * sample;
    }
    return samples.isEmpty ? 0 : math.sqrt(energy / samples.length);
  }

  static void scale(Float32List samples, double gain) {
    if (gain <= 1.001) return;
    for (var i = 0; i < samples.length; i++) {
      samples[i] = (samples[i] * gain).clamp(-1.0, 1.0);
    }
  }

  void apply(Float32List block) {
    final level = rms(block);
    if (level > 0.0005) {
      final wanted = (target / level).clamp(1.0, maximum);
      gain = wanted < gain ? wanted : gain + (wanted - gain) * 0.3;
    }
    scale(block, gain);
  }

  /// One gain for a whole window, from the level of its speech: a file
  /// window has no history to ramp up from.
  static void normalize(Float32List samples) {
    final levels = <double>[];
    for (var i = 0; i + _block <= samples.length; i += _block) {
      final level = rms(Float32List.sublistView(samples, i, i + _block));
      if (level > 0.0005) levels.add(level);
    }
    if (levels.isEmpty) return;
    levels.sort();
    final speech = levels[(levels.length * 3) ~/ 4];
    scale(samples, (target / speech).clamp(1.0, maximum));
  }
}

Float32List _toFloat(Uint8List pcm) {
  final count = pcm.lengthInBytes ~/ 2;
  final data = ByteData.sublistView(pcm, 0, count * 2);
  final samples = Float32List(count);
  for (var i = 0; i < count; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
  }
  return samples;
}

class _Worker {
  _Worker._(this._isolate, this._port);
  final Isolate _isolate;
  final SendPort _port;

  static Future<_Worker> spawn(String? libraryPath) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      (ready.sendPort, libraryPath),
      errorsAreFatal: true,
      debugName: 'nemotron',
    );
    final first = await ready.first;
    if (first is! SendPort) {
      isolate.kill(priority: Isolate.immediate);
      throw StateError('nemotronLibraryMissing');
    }
    return _Worker._(isolate, first);
  }

  Future<Map<Object?, Object?>> call(Map<String, Object?> message) async {
    final reply = ReceivePort();
    _port.send({...message, 'reply': reply.sendPort});
    final answer = await reply.first as Map<Object?, Object?>;
    if (answer['error'] case final String error) {
      throw StateError(error);
    }
    return answer;
  }

  void kill() => _isolate.kill(priority: Isolate.immediate);
}

/// A live stream inside the worker. Tokens are never cleared while the
/// stream lives; [segmentStart] marks where the current line begins.
class _StreamState {
  _StreamState(this.stream, this.language);
  sherpa.OnlineStream stream;
  final String language;
  final gain = _Gain();
  Float32List remainder = Float32List(0);
  int fedSamples = 0;
  int audioSamples = 0;
  int segmentStart = 0;
  List<String> tokens = const [];
  List<double> times = const [];
  double get fedSeconds => fedSamples / _rate;
  double get audioSeconds => audioSamples / _rate;

  void restart(sherpa.OnlineStream next) {
    stream.free();
    stream = next;
    fedSamples = 0;
    audioSamples = 0;
    segmentStart = 0;
    tokens = const [];
    times = const [];
    remainder = Float32List(0);
  }
}

const _rate = 16000;

/// Silence after the last token that ends a line; it includes the model's own
/// delay of roughly one chunk. Short lines wait for a longer pause, so a slow
/// speaker's breaths do not cut every phrase in two.
const _lineGapSeconds = 1.5;
const _shortLineGapSeconds = 2.6;
const _shortLineTokens = 8;

/// Lines longer than this are cut at the widest pause found after eight
/// seconds, so captions keep turning over during long stretches of speech.
const _lineMaxSeconds = 15.0;

/// The model writes sentence punctuation only once it hears the next word,
/// so a line cut at a pause gets its full stop as the next line's first
/// token. Such tokens belong to the line before.
final _punctuation = RegExp(r'^[.,!?;:。，！？；：、…]+$');

void _workerMain((SendPort, String?) boot) {
  final (ready, libraryPath) = boot;
  try {
    if (libraryPath != null && Platform.isWindows) {
      // ONNX Runtime sits next to the C API; loading it first keeps the
      // loader from searching elsewhere.
      DynamicLibrary.open('$libraryPath\\onnxruntime.dll');
    }
    sherpa.initBindings(libraryPath);
  } catch (e) {
    ready.send('$e');
    return;
  }
  final port = ReceivePort();
  ready.send(port.sendPort);
  sherpa.OnlineRecognizer? recognizer;
  var multilingual = true;
  final streams = <String, _StreamState>{};

  sherpa.OnlineRecognizer requireRecognizer() {
    final current = recognizer;
    if (current == null) throw StateError('nemotronNotRunning');
    return current;
  }

  sherpa.OnlineStream open(String language) {
    final stream = requireRecognizer().createStream();
    if (multilingual) {
      stream.setOption(
        key: 'language',
        value: language.isEmpty ? 'auto' : language,
      );
    }
    return stream;
  }

  _StreamState requireStream(Object? id) {
    final state = streams[id as String];
    if (state == null) throw StateError('nemotronStreamClosed');
    return state;
  }

  /// Decodes what the model can, refreshing the token cache only when
  /// something was decoded: results cover the whole stream, so reading them
  /// after every block would grow costly over a long session.
  void decode(_StreamState state) {
    final current = requireRecognizer();
    var decoded = false;
    while (current.isReady(state.stream)) {
      current.decode(state.stream);
      decoded = true;
    }
    if (!decoded) return;
    final result = current.getResult(state.stream);
    final count = math.min(result.tokens.length, result.timestamps.length);
    state.tokens = result.tokens.sublist(0, count);
    state.times = result.timestamps.sublist(0, count);
  }

  Map<String, Object?> piece(
    _StreamState state,
    int from,
    int to, {
    bool continues = false,
  }) => {
    'type': 'final',
    'text': state.tokens.sublist(from, to).join().trim(),
    // Tokens decoded during added silence are placed at the audio's end.
    'start': math.min(state.times[from], state.audioSeconds),
    // A token's time is its onset; the word runs a little past it.
    'end': math.min(state.times[to - 1] + 0.3, state.audioSeconds),
    'continues': continues,
  };

  /// Splits decoded tokens into finished lines, in order with the
  /// punctuation that belongs to the line before.
  void segment(
    _StreamState state,
    List<Map<String, Object?>> events, {
    required bool closing,
  }) {
    final tokens = state.tokens;
    final times = state.times;
    final count = tokens.length;
    while (state.segmentStart < count &&
        _punctuation.hasMatch(tokens[state.segmentStart].trim())) {
      events.add({'type': 'amend', 'text': tokens[state.segmentStart].trim()});
      state.segmentStart++;
    }
    while (state.segmentStart < count) {
      final first = times[state.segmentStart];
      final last = times[count - 1];
      final gap = state.fedSeconds - last;
      final short = count - state.segmentStart < _shortLineTokens;
      if (closing ||
          gap >= _shortLineGapSeconds ||
          (gap >= _lineGapSeconds && !short)) {
        events.add(piece(state, state.segmentStart, count));
        state.segmentStart = count;
        break;
      }
      if (last - first < _lineMaxSeconds) break;
      var cut = count;
      var widest = 0.0;
      for (var i = state.segmentStart + 1; i < count; i++) {
        final gap = times[i] - times[i - 1];
        if (times[i] - first >= 8 && gap >= widest) {
          widest = gap;
          cut = i;
        }
      }
      // Cut mid-speech: the sentence may go on in the next line.
      events.add(piece(state, state.segmentStart, cut, continues: true));
      state.segmentStart = cut;
    }
  }

  /// Feeds real audio in fixed blocks, deciding after each one.
  void feed(
    _StreamState state,
    Float32List samples,
    List<Map<String, Object?>> events,
  ) {
    var data = samples;
    if (state.remainder.isNotEmpty) {
      data = Float32List(state.remainder.length + samples.length)
        ..setAll(0, state.remainder)
        ..setAll(state.remainder.length, samples);
    }
    var offset = 0;
    while (data.length - offset >= _block) {
      final block = Float32List.sublistView(data, offset, offset + _block);
      state.gain.apply(block);
      state.stream.acceptWaveform(samples: block, sampleRate: _rate);
      state.fedSamples += _block;
      state.audioSamples += _block;
      decode(state);
      segment(state, events, closing: false);
      offset += _block;
    }
    state.remainder = Float32List.fromList(data.sublist(offset));
  }

  /// Feeds what is left, lets the model finish on added silence, and closes
  /// the stream's last line.
  List<Map<String, Object?>> close(_StreamState state) {
    final events = <Map<String, Object?>>[];
    if (state.remainder.isNotEmpty) {
      final rest = state.remainder;
      state.remainder = Float32List(0);
      state.gain.apply(rest);
      state.stream.acceptWaveform(samples: rest, sampleRate: _rate);
      state.fedSamples += rest.length;
      state.audioSamples += rest.length;
    }
    state.stream.acceptWaveform(samples: Float32List(_rate), sampleRate: _rate);
    state.fedSamples += _rate;
    state.stream.inputFinished();
    decode(state);
    segment(state, events, closing: true);
    return events;
  }

  Map<String, Object?> partial(_StreamState state) {
    if (state.segmentStart >= state.tokens.length) return const {};
    final line = piece(state, state.segmentStart, state.tokens.length);
    return {'text': line['text'], 'start': line['start'], 'end': line['end']};
  }

  void freeStream(String id) {
    streams.remove(id)?.stream.free();
  }

  port.listen((message) {
    final request = message as Map<Object?, Object?>;
    final reply = request['reply'] as SendPort;
    try {
      switch (request['op']) {
        case 'load':
          recognizer?.free();
          final dir = request['dir'] as String;
          multilingual = request['multilingual'] == true;
          recognizer = sherpa.OnlineRecognizer(
            sherpa.OnlineRecognizerConfig(
              feat: const sherpa.FeatureConfig(
                sampleRate: _rate,
                featureDim: 80,
              ),
              model: sherpa.OnlineModelConfig(
                transducer: sherpa.OnlineTransducerModelConfig(
                  encoder: '$dir/encoder.int8.onnx',
                  decoder: '$dir/decoder.int8.onnx',
                  joiner: '$dir/joiner.int8.onnx',
                ),
                tokens: '$dir/tokens.txt',
                numThreads: request['threads'] as int,
                provider: 'cpu',
                debug: false,
              ),
              // Lines are cut here from token timing, not by the recognizer.
              enableEndpoint: false,
            ),
          );
          reply.send({'ok': true});
        case 'transcribe':
          final stream = open(request['language'] as String? ?? '');
          try {
            final samples = _toFloat(request['pcm'] as Uint8List);
            _Gain.normalize(samples);
            stream.acceptWaveform(samples: samples, sampleRate: _rate);
            // Trailing silence lets the transducer emit its last words.
            stream.acceptWaveform(
              samples: Float32List(_rate * 4 ~/ 5),
              sampleRate: _rate,
            );
            stream.inputFinished();
            final current = requireRecognizer();
            while (current.isReady(stream)) {
              current.decode(stream);
            }
            reply.send({
              'ok': true,
              'text': current.getResult(stream).text.trim(),
            });
          } finally {
            stream.free();
          }
        case 'open':
          final id = request['id'] as String;
          freeStream(id);
          final language = request['language'] as String? ?? '';
          streams[id] = _StreamState(open(language), language);
          reply.send({'ok': true});
        case 'feed':
          final state = requireStream(request['id']);
          final events = <Map<String, Object?>>[];
          feed(state, _toFloat(request['pcm'] as Uint8List), events);
          reply.send({'ok': true, 'events': events, 'partial': partial(state)});
        case 'flush':
          final state = requireStream(request['id']);
          final events = close(state);
          // Audio after a pause starts on a fresh stream at time zero.
          state.restart(open(state.language));
          reply.send({'ok': true, 'events': events});
        case 'finish':
          final id = request['id'] as String;
          final state = requireStream(id);
          final events = close(state);
          freeStream(id);
          reply.send({'ok': true, 'events': events});
        case 'close':
          freeStream(request['id'] as String);
          reply.send({'ok': true});
        default:
          throw StateError('nemotronUnknownOp');
      }
    } catch (e) {
      reply.send({'error': e.toString()});
    }
  });
}
