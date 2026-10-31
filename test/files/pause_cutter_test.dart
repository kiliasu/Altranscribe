import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/pause_cutter.dart';
import 'package:altranscribe/data/services/files/silero_vad.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/synthetic_voice.dart';

final model = File('assets/models/ggml-silero-v5.1.2.bin').readAsBytesSync();

/// [pcm] as a decoder delivers it, in chunks of [chunkMs].
Stream<FileAudioChunk> chunks(Uint8List pcm, int chunkMs) async* {
  for (var start = 0; start < pcm.length; start += chunkMs * 32) {
    final end = (start + chunkMs * 32).clamp(0, pcm.length);
    yield FileAudioChunk(
      Uint8List.sublistView(pcm, start, end),
      start ~/ 32,
      end ~/ 32,
    );
  }
}

void main() {
  test('the bundled Silero model hears the voice and not the silence', () {
    final vad = SileroVad.parse(model);
    final probabilities = vad.probabilities(
      speechWithPauses([-1000, 3000, -1000]),
    );
    // 32 ms windows: the middle of the voice and of each silence.
    expect(probabilities.sublist(45, 110).every((p) => p > .9), isTrue);
    expect(probabilities.sublist(0, 25).every((p) => p < .05), isTrue);
    expect(probabilities.sublist(135).every((p) => p < .05), isTrue);
  });

  test('the detector keeps its state between calls, until reset', () {
    final audio = speechWithPauses([-500, 2000, -500]);
    final whole = SileroVad.parse(model).probabilities(audio);
    final split = SileroVad.parse(model);
    final cut = 40 * SileroVad.window;
    final parts = [
      ...split.probabilities(Float32List.sublistView(audio, 0, cut)),
      ...split.probabilities(Float32List.sublistView(audio, cut)),
    ];
    expect(parts, whole);
    split.reset();
    expect(split.probabilities(audio), whole);
  });

  test('a file that is not a ggml VAD model is refused', () {
    expect(
      () => SileroVad.parse(Uint8List.fromList(List.filled(64, 1))),
      throwsFormatException,
    );
  });

  test(
    'pieces end in the latest pause before the limit and lose nothing',
    () async {
      // Pauses at 9.0, 18.6, 28.1 and 37.5 seconds.
      final pcm = pcm16(
        speechWithPauses([
          9000,
          -600,
          9000,
          -500,
          9000,
          -400,
          9000,
          -700,
          5000,
        ]),
      );
      for (final chunkMs in [1000, 7000]) {
        final pieces = await PauseCutter(
          maxMs: 30000,
          searchMs: 12000,
          detector: sileroDetector(model),
        ).cut(chunks(pcm, chunkMs)).toList();
        expect(pieces, hasLength(2));
        // The pause at 28.1-28.5 s is later than the longer one at 18.6 s.
        expect(pieces.first.endMs, inInclusiveRange(28100, 28500));
        expect(pieces.last.startMs, pieces.first.endMs);
        expect(pieces.last.endMs, pcm.length ~/ 32);
        expect(
          pieces.map((piece) => piece.pcm.length).reduce((a, b) => a + b),
          pcm.length,
        );
        expect(
          Uint8List.fromList([for (final piece in pieces) ...piece.pcm]),
          pcm,
        );
      }
    },
  );

  test('a quiet recording is cut in its pauses too', () async {
    // About 40 dB below the voice above, like a distant lecture.
    final pcm = pcm16(
      speechWithPauses([12000, -500, 14000, -600, 9000], peak: .005),
    );
    final pieces = await PauseCutter(
      maxMs: 30000,
      searchMs: 12000,
      detector: sileroDetector(model),
    ).cut(chunks(pcm, 5000)).toList();
    expect(pieces.first.endMs, inInclusiveRange(26500, 27100));
  });

  test('without a pause, the least speech-like moment ends the piece', () {
    final probabilities = Float32List.fromList(
      List.generate(100, (i) => i == 70 ? .4 : .9),
    );
    expect(PauseCutter.choosePause(probabilities, 50), (70, 1));
  });

  test('a short pause is taken only when no whole one is there', () {
    Float32List speech(List<(int, int)> pauses) {
      final probabilities = Float32List.fromList(List.filled(200, .95));
      for (final (start, length) in pauses) {
        probabilities.fillRange(start, start + length, .1);
      }
      return probabilities;
    }

    // The latest pause of at least eight windows wins over a longer one.
    expect(
      PauseCutter.choosePause(speech([(60, 20), (150, 8), (180, 3)]), 50),
      (150, 8),
    );
    // Short pauses only: the longest, and the later of equals.
    expect(PauseCutter.choosePause(speech([(60, 4), (120, 6), (170, 6)]), 50), (
      170,
      6,
    ));
    // A pause before the search region does not count.
    expect(PauseCutter.choosePause(speech([(10, 30), (90, 2)]), 50), (90, 2));
  });

  test(
    'a piece always ends after its start, whatever the detector says',
    () async {
      final pcm = Uint8List(80 * 32000);
      final pieces = await PauseCutter(
        maxMs: 30000,
        searchMs: 12000,
        detector: (pcm) async => Float32List(0),
      ).cut(chunks(pcm, 10000)).toList();
      expect(pieces.every((piece) => piece.endMs > piece.startMs), isTrue);
      expect(
        pieces.every((piece) => piece.endMs - piece.startMs <= 30000),
        isTrue,
      );
      expect(pieces.last.endMs, 80000);
    },
  );
}
