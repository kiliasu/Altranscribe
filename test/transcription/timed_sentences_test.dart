import 'dart:typed_data';

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/file_transcriber.dart';
import 'package:altranscribe/data/services/files/pause_cutter.dart';
import 'package:altranscribe/data/services/transcription/transcript_assembler.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

List<TimedWord> words(String text, int startMs, {int step = 300}) => [
  for (final (i, word) in text.split(' ').indexed)
    TimedWord(word, startMs + i * step, startMs + i * step + step - 50),
];

class PiecesDecoder extends AudioFileDecoder {
  PiecesDecoder(this.pieces);
  final List<(int, int)> pieces;
  @override
  Stream<FileAudioChunk> decode(
    String path, {
    int chunkSeconds = 20,
    PauseCutter? cutter,
  }) async* {
    for (final (start, end) in pieces) {
      yield FileAudioChunk(Uint8List((end - start) * 32), start, end);
    }
  }

  @override
  Future<void> cancel() async {}
}

/// Answers each piece with the next transcript and its word times.
class TimedEngine extends FakeEngine implements TimedSpeechEngine {
  TimedEngine(this.results);
  final List<TimedTranscript> results;
  var _next = 0;
  @override
  Future<TimedTranscript> transcribeTimed(
    Uint8List wave,
    String language,
  ) async => results[_next++];
}

void main() {
  test('sentences take their words\' times, whatever the punctuation', () {
    final timed = timedSentences(
      'Good morning, everyone. Today we start chapter three!',
      [
        ...words('good morning everyone', 1000),
        ...words('today we start chapter three', 5000),
      ],
      9000,
    );
    expect(timed.map((s) => s.text), [
      'Good morning, everyone.',
      'Today we start chapter three!',
    ]);
    expect([timed[0].startMs, timed[0].endMs], [1000, 1850]);
    expect([timed[1].startMs, timed[1].endMs], [5000, 6450]);
    expect(timed.any((s) => s.estimated), isFalse);
  });

  test('Chinese is timed character by character', () {
    final timed = timedSentences('大家好。我们开始吧！', [
      for (final (i, character) in '大家好我们开始吧'.split('').indexed)
        TimedWord(character, 2000 + i * 200, 2150 + i * 200),
    ], 5000);
    expect(timed.map((s) => [s.startMs, s.endMs]), [
      [2000, 2550],
      [2600, 3550],
    ]);
  });

  test('sentences the words do not reach share the rest by length', () {
    final timed = timedSentences(
      'First one here. Then two. And three.',
      words('first one here', 0),
      10000,
    );
    expect(timed[0].estimated, isFalse);
    expect(timed[1].estimated && timed[2].estimated, isTrue);
    expect(timed[1].startMs, timed[0].endMs);
    expect(timed[2].endMs, 10000);
    expect(timed[1].endMs, lessThan(timed[2].endMs));
  });

  test(
    'a file read by a timing engine keeps each sentence where it was said',
    () async {
      final record = TranscriptRecord(
        id: 'session-1',
        createdAt: DateTime(2026),
        language: 'en',
        inputFile: 'lecture.wav',
        sources: ['file'],
        lines: [],
      );
      final engine = TimedEngine([
        TimedTranscript('Welcome back. Last time we saw', [
          ...words('welcome back', 2000),
          ...words('last time we saw', 26000),
        ]),
        TimedTranscript('how vectors add. Now matrices.', [
          ...words('how vectors add', 100),
          ...words('now matrices', 6000),
        ]),
      ]);
      final ok =
          await FileTranscriber(PiecesDecoder([(0, 28000), (28000, 40000)]))
              .transcribe(
                record: record,
                engine: engine,
                store: MemoryStore(),
                onChanged: () {},
              );
      expect(ok, isTrue);
      expect(record.lines.map((line) => line.text), [
        'Welcome back.',
        // Cut at a pause mid-sentence, the halves join again.
        'Last time we saw how vectors add.',
        'Now matrices.',
      ]);
      expect(record.lines.map((line) => [line.startMs, line.endMs]), [
        [2000, 2550],
        [26000, 28950],
        [34000, 34550],
      ]);
      expect(record.lines.every((line) => !line.timingEstimated), isTrue);
    },
  );

  test('a failed piece leaves the record final with the error', () async {
    final record = TranscriptRecord(
      id: 'session-2',
      createdAt: DateTime(2026),
      language: 'en',
      inputFile: 'lecture.wav',
      sources: ['file'],
      lines: [],
      targetLanguage: 'zh',
    );
    final engine = FakeEngine()..failure = 'engineStopped';
    final store = MemoryStore();
    final transcriber = FileTranscriber(PiecesDecoder([(0, 1000)]));
    expect(
      await transcriber.transcribe(
        record: record,
        engine: engine,
        store: store,
        onChanged: () {},
      ),
      isFalse,
    );
    expect(record.status, 'error');
    expect((await store.loadRecords()).single.status, 'error');
    expect(record.lines, isEmpty);
  });
}
