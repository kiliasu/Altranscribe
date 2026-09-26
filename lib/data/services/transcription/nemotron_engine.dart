import 'dart:async';
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

  /// A live stream for one capture source; [onText] receives partial lines
  /// and, once the speaker pauses, the finished line.
  Future<NemotronLive> openLive({
    required String source,
    required String language,
    required void Function(CloudLiveText) onText,
  }) async {
    final worker = _worker;
    if (worker == null) throw StateError('nemotronNotRunning');
    final id = 'nemotron-$source-${_streamIds++}';
    await worker.call({'op': 'open', 'id': id, 'language': language});
    return NemotronLive._(worker, id, source, onText);
  }

  @override
  Future<void> stop() async {
    final worker = _worker;
    _worker = null;
    model = null;
    worker?.kill();
  }
}

/// One capture source fed frame by frame. The worker segments speech by the
/// timing of the tokens it decodes, so line times come from the model; the
/// stream itself is never reset, which keeps words at pauses from being lost.
class NemotronLive {
  NemotronLive._(this._worker, this.id, this.source, this.onText);
  final _Worker _worker;
  final String id;
  final String source;
  final void Function(CloudLiveText) onText;
  final _pending = <(Uint8List, int, int)>[];
  Future<void>? _draining;
  bool _closed = false;
  int _segment = 0;
  int _fedMs = 0;
  int _clockOffsetMs = 0;
  String _lastPartial = '';

  /// Completes once queued audio has been decoded.
  Future<void> get idle => _draining ?? Future.value();

  /// Audio waiting for the model, in milliseconds; grows when decoding is
  /// slower than real time.
  int get backlogMs =>
      _pending.fold(0, (sum, frame) => sum + (frame.$3 - frame.$2));

  void add(Uint8List pcm, int startMs, int endMs) {
    if (_closed) return;
    // Session time runs on while capture is paused; stream time does not.
    _clockOffsetMs = startMs - _fedMs;
    _fedMs += pcm.length ~/ 32;
    _pending.add((pcm, startMs, endMs));
    _draining ??= _drain().whenComplete(() => _draining = null);
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty && !_closed) {
      // Everything queued goes in one call; decoding cost follows the audio,
      // not the number of messages.
      final frames = List.of(_pending);
      _pending.clear();
      final builder = BytesBuilder(copy: false);
      for (final frame in frames) {
        builder.add(frame.$1);
      }
      final result = await _worker.call({
        'op': 'feed',
        'id': id,
        'pcm': builder.takeBytes(),
      });
      if (!_closed) _handle(result);
    }
  }

  int _ms(Object? seconds) =>
      _clockOffsetMs + ((seconds as num) * 1000).round();

  void _handle(Map<Object?, Object?> result) {
    for (final segment in result['finals'] as List? ?? const []) {
      final piece = segment as Map;
      final start = _ms(piece['start']);
      onText(
        CloudLiveText(
          id: '$id-${_segment++}',
          source: source,
          text: piece['text'] as String,
          startMs: start,
          endMs: math.max(start + 200, _ms(piece['end'])),
          finalized: true,
          timingEstimated: true,
        ),
      );
      _lastPartial = '';
    }
    final partial = result['partial'] as Map?;
    final text = partial?['text'] as String? ?? '';
    if (text.isEmpty || text == _lastPartial) return;
    _lastPartial = text;
    final start = _ms(partial!['start']);
    onText(
      CloudLiveText(
        id: '$id-$_segment',
        source: source,
        text: text,
        startMs: start,
        endMs: math.max(start + 200, _ms(partial['end'])),
        timingEstimated: true,
      ),
    );
  }

  /// Closes the current segment, as when capture pauses.
  Future<void> flush() async {
    if (_closed) return;
    await _draining;
    if (_closed) return;
    _handle(await _worker.call({'op': 'flush', 'id': id}));
  }

  /// Delivers whatever is still buffered as a final line and frees the stream.
  Future<void> finish() async {
    if (_closed) return;
    await _draining;
    if (_closed) return;
    _closed = true;
    _handle(await _worker.call({'op': 'finish', 'id': id}));
  }

  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    try {
      await _worker.call({'op': 'close', 'id': id});
    } catch (_) {}
  }
}

/// Brings quiet speech up to a working level, as the capture path's automatic
/// gain does for live sources: rises over a few chunks, falls at once, never
/// clips.
class _Gain {
  double gain = 1;
  static const target = 0.06;
  static const maximum = 40.0;

  void apply(Float32List samples) {
    if (samples.isEmpty) return;
    var energy = 0.0;
    for (final sample in samples) {
      energy += sample * sample;
    }
    final rms = math.sqrt(energy / samples.length);
    if (rms > 0.0005) {
      final wanted = (target / rms).clamp(1.0, maximum);
      gain = wanted < gain ? wanted : gain + (wanted - gain) * 0.3;
    }
    if (gain <= 1.001) return;
    for (var i = 0; i < samples.length; i++) {
      samples[i] = (samples[i] * gain).clamp(-1.0, 1.0);
    }
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

/// A live stream inside the worker. Tokens are never cleared; [segmentStart]
/// marks where the current line begins in the token list.
class _StreamState {
  _StreamState(this.stream);
  final sherpa.OnlineStream stream;
  final gain = _Gain();
  int fedSamples = 0;
  int audioSamples = 0;
  int segmentStart = 0;
  double get fedSeconds => fedSamples / _rate;

  /// Real audio only, without the silence added to flush the model.
  double get audioSeconds => audioSamples / _rate;
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

  sherpa.OnlineRecognizerResult decodeAll(sherpa.OnlineStream stream) {
    final current = requireRecognizer();
    while (current.isReady(stream)) {
      current.decode(stream);
    }
    return current.getResult(stream);
  }

  _StreamState requireStream(Object? id) {
    final state = streams[id as String];
    if (state == null) throw StateError('nemotronStreamClosed');
    return state;
  }

  void feed(_StreamState state, Float32List samples, {bool audio = true}) {
    if (audio) state.gain.apply(samples);
    state.stream.acceptWaveform(samples: samples, sampleRate: _rate);
    state.fedSamples += samples.length;
    if (audio) state.audioSamples += samples.length;
  }

  Map<String, Object?> piece(
    _StreamState state,
    sherpa.OnlineRecognizerResult result,
    int from,
    int to,
  ) => {
    'text': result.tokens.sublist(from, to).join().trim(),
    'start': result.timestamps[from],
    // A token's time is its onset; the word runs a little past it.
    'end': math.min(result.timestamps[to - 1] + 0.3, state.audioSeconds),
  };

  /// Splits decoded tokens into finished lines and the line still growing.
  Map<String, Object?> segments(
    _StreamState state,
    sherpa.OnlineRecognizerResult result, {
    required bool closing,
  }) {
    final finals = <Map<String, Object?>>[];
    final tokens = result.tokens;
    final times = result.timestamps;
    final count = math.min(tokens.length, times.length);
    while (state.segmentStart < count) {
      final first = times[state.segmentStart];
      final last = times[count - 1];
      final gap = state.fedSeconds - last;
      final short = count - state.segmentStart < _shortLineTokens;
      if (closing ||
          gap >= _shortLineGapSeconds ||
          (gap >= _lineGapSeconds && !short)) {
        finals.add(piece(state, result, state.segmentStart, count));
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
      finals.add(piece(state, result, state.segmentStart, cut));
      state.segmentStart = cut;
    }
    return {
      'ok': true,
      'finals': finals,
      if (state.segmentStart < count)
        'partial': piece(state, result, state.segmentStart, count),
    };
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
            _Gain().apply(samples);
            stream.acceptWaveform(samples: samples, sampleRate: _rate);
            // Trailing silence lets the transducer emit its last words.
            stream.acceptWaveform(
              samples: Float32List(_rate * 4 ~/ 5),
              sampleRate: _rate,
            );
            stream.inputFinished();
            reply.send({'ok': true, 'text': decodeAll(stream).text.trim()});
          } finally {
            stream.free();
          }
        case 'open':
          final id = request['id'] as String;
          freeStream(id);
          streams[id] = _StreamState(
            open(request['language'] as String? ?? ''),
          );
          reply.send({'ok': true});
        case 'feed':
          final state = requireStream(request['id']);
          feed(state, _toFloat(request['pcm'] as Uint8List));
          reply.send(segments(state, decodeAll(state.stream), closing: false));
        case 'flush':
          final state = requireStream(request['id']);
          // A second of silence lets the model finish the line it is on.
          feed(state, Float32List(_rate), audio: false);
          reply.send(segments(state, decodeAll(state.stream), closing: true));
        case 'finish':
          final id = request['id'] as String;
          final state = requireStream(id);
          feed(state, Float32List(_rate * 4 ~/ 5), audio: false);
          state.stream.inputFinished();
          final answer = segments(
            state,
            decodeAll(state.stream),
            closing: true,
          );
          freeStream(id);
          reply.send(answer);
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
