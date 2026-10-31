import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/silero_vad.dart';

/// Speech probabilities for 16-bit mono 16 kHz audio, one per 512 samples.
typedef SpeechDetector = Future<Float32List> Function(Uint8List pcm);

/// Silero, run in a background isolate on the bundled ggml model. Quiet
/// recordings are raised to speech level first: the detector hears little in
/// a distant lecture at its recorded level.
SpeechDetector sileroDetector(Uint8List model) =>
    (pcm) => Isolate.run(() => _detect(model, pcm));

Float32List _detect(Uint8List model, Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  final samples = Float32List(pcm.length ~/ 2);
  var energy = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final value = data.getInt16(2 * i, Endian.little) / 32768;
    samples[i] = value;
    energy += value * value;
  }
  final rms = samples.isEmpty ? 0.0 : math.sqrt(energy / samples.length);
  final gain = rms <= 0 ? 1.0 : (0.06 / rms).clamp(1.0, 40.0);
  if (gain > 1) {
    for (var i = 0; i < samples.length; i++) {
      samples[i] = (samples[i] * gain).clamp(-1.0, 1.0);
    }
  }
  return SileroVad.parse(model).probabilities(samples);
}

/// Cuts a file's decoded audio into pieces of at most [maxMs] that end in a
/// pause, so no word is split between two requests. Only the last [searchMs]
/// before each limit is listened to: the latest pause of at least a quarter
/// second there ends the piece, else the longest one, else the least
/// speech-like moment. Pieces follow each other without gaps.
class PauseCutter {
  PauseCutter({
    required this.maxMs,
    required this.searchMs,
    required this.detector,
  }) : assert(searchMs < maxMs);
  final int maxMs;
  final int searchMs;
  final SpeechDetector detector;

  /// The detector hears this much before the search starts, to settle.
  static const warmUpMs = 1000;
  static const _bytesPerMs = 32;
  static const _window = SileroVad.window * 2;

  /// Below this a window counts as a pause, as whisper.cpp ends speech.
  static const pauseProbability = .35;

  /// A pause this many windows long (256 ms) can end a piece by itself.
  static const _wholePause = 8;

  Stream<FileAudioChunk> cut(Stream<FileAudioChunk> audio) async* {
    final buffer = BytesBuilder(copy: false);
    var start = -1;
    final maxBytes = maxMs * _bytesPerMs;
    await for (final chunk in audio) {
      if (start < 0) start = chunk.startMs * _bytesPerMs;
      buffer.add(chunk.pcm);
      while (buffer.length > maxBytes) {
        final available = buffer.takeBytes();
        final end = await _cutPoint(
          Uint8List.sublistView(available, 0, maxBytes),
        );
        yield FileAudioChunk(
          Uint8List.sublistView(available, 0, end),
          start ~/ _bytesPerMs,
          (start + end) ~/ _bytesPerMs,
        );
        buffer.add(Uint8List.sublistView(available, end));
        start += end;
      }
    }
    if (buffer.length >= 2) {
      final rest = buffer.takeBytes();
      yield FileAudioChunk(
        rest,
        start ~/ _bytesPerMs,
        (start + rest.length) ~/ _bytesPerMs,
      );
    }
  }

  /// Where to end [piece], which is exactly [maxMs] long, in bytes.
  Future<int> _cutPoint(Uint8List piece) async {
    final search = piece.length - searchMs * _bytesPerMs;
    // Windows start on the 512-sample grid of the listened region.
    final listened = math.max(
      0,
      search - (warmUpMs * _bytesPerMs + _window - 1) ~/ _window * _window,
    );
    final probabilities = await detector(
      Uint8List.sublistView(piece, listened),
    );
    final first = (search - listened) ~/ _window;
    final window = choosePause(probabilities, first);
    final end = listened + window.$1 * _window + (window.$2 * _window) ~/ 2;
    // Whole samples only, and never an empty piece.
    return math.max(2, math.min(piece.length, end) & ~1);
  }

  /// The pause to cut at among [probabilities] from window [first] on, as
  /// (first window, length in windows).
  static (int, int) choosePause(Float32List probabilities, int first) {
    (int, int)? latestWhole;
    (int, int)? longest;
    var run = 0;
    for (var i = first; i <= probabilities.length; i++) {
      if (i < probabilities.length && probabilities[i] < pauseProbability) {
        run++;
        continue;
      }
      if (run > 0) {
        final pause = (i - run, run);
        if (run >= _wholePause) latestWhole = pause;
        if (longest == null || run >= longest.$2) longest = pause;
        run = 0;
      }
    }
    if (latestWhole ?? longest case final pause?) return pause;
    var quietest = math.max(first, probabilities.length - 1);
    for (var i = probabilities.length - 1; i >= first; i--) {
      if (probabilities[i] < probabilities[quietest]) quietest = i;
    }
    return (quietest, 1);
  }
}
