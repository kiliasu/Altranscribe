import 'dart:async';
import 'dart:typed_data';

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/file_transcriber.dart';
import 'package:altranscribe/data/services/files/pause_cutter.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_terms.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// Answers each line when the test says so, and counts how many waited at
/// once.
class SlowTranslator extends FakeTranslator {
  final waiting = <Completer<String>>[];
  final started = <String>[];
  int inFlight = 0;
  int peak = 0;
  @override
  Future<String> translate(
    String text,
    String source,
    String target, {
    List<TranslationContext> context = const [],
    String rules = defaultTranslationRules,
    List<TranslationTerm> terms = const [],
  }) async {
    started.add(text);
    inFlight++;
    if (inFlight > peak) peak = inFlight;
    final completer = Completer<String>();
    waiting.add(completer);
    try {
      return await completer.future;
    } finally {
      inFlight--;
    }
  }

  void answerAll() {
    for (final (i, completer) in waiting.indexed) {
      if (!completer.isCompleted) completer.complete('译$i');
    }
  }
}

class CountingStore extends MemoryStore {
  int saves = 0;
  @override
  Future<void> save(TranscriptRecord record) {
    saves++;
    return super.save(record);
  }
}

/// Three pieces of two seconds, each announced as read before it is given.
class ProgressDecoder extends AudioFileDecoder {
  @override
  Future<int?> durationMs(String path) async => 6000;
  @override
  Stream<FileAudioChunk> decode(
    String path, {
    int chunkSeconds = 20,
    PauseCutter? cutter,
  }) async* {
    for (var i = 0; i < 3; i++) {
      onDecoded?.call((i + 1) * 2000);
      yield FileAudioChunk(Uint8List(64000), i * 2000, (i + 1) * 2000);
    }
  }

  @override
  Future<void> cancel() async {}
}

TranscriptRecord record(int lines) => TranscriptRecord(
  id: 'session-1',
  createdAt: DateTime(2026),
  language: 'en',
  targetLanguage: 'zh',
  sources: ['file'],
  inputFile: 'talk.wav',
  lines: [
    for (var i = 0; i < lines; i++)
      TranscriptLine(
        source: 'file',
        startMs: i * 1000,
        endMs: (i + 1) * 1000,
        text: 'Sentence $i.',
      ),
  ],
);

/// Lets the awaiting workers take their next steps.
Future<void> pump() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'a file translates several lines at once, in order, and saves rarely',
    () async {
      final translator = SlowTranslator();
      final store = CountingStore();
      final current = record(10);
      var changes = 0;
      final done = FileTranscriber(ProgressDecoder()).process(
        record: current,
        translator: translator,
        store: store,
        options: const CleanupOptions(),
        onChanged: () => changes++,
        parallel: 4,
      );
      await pump();
      expect(translator.started, [
        'Sentence 0.',
        'Sentence 1.',
        'Sentence 2.',
        'Sentence 3.',
      ]);
      expect(
        current.lines.take(4).map((line) => line.translationStatus),
        everyElement('pending'),
      );
      expect(current.lines[4].translationStatus, 'none');
      // A line that finishes frees its place for the next; the others go on.
      translator.waiting[1].complete('二');
      await pump();
      expect(translator.started.last, 'Sentence 4.');
      expect(current.lines[1].translation, '二');
      expect(translator.inFlight, 4);
      while (translator.started.length < 10 ||
          translator.waiting.any((item) => !item.isCompleted)) {
        translator.answerAll();
        await pump();
      }
      await done;
      expect(translator.peak, 4);
      expect(
        current.lines.map((line) => line.translationStatus),
        everyElement('done'),
      );
      expect(current.lines[1].translation, '二');
      expect(current.status, 'completed');
      // Ten lines changed twenty times; the disk saw a few writes and the
      // screen a few updates.
      expect(store.saves, lessThanOrEqualTo(4));
      expect(changes, lessThanOrEqualTo(8));
    },
  );

  test(
    'cancelling while lines translate side by side leaves the rest interrupted',
    () async {
      final translator = SlowTranslator();
      final current = record(6);
      final task = FileTranscriber(ProgressDecoder());
      final done = task.process(
        record: current,
        translator: translator,
        store: MemoryStore(),
        options: const CleanupOptions(),
        onChanged: () {},
        parallel: 3,
      );
      await pump();
      expect(translator.started, hasLength(3));
      translator.waiting[0].complete('一');
      await pump();
      await task.cancel();
      translator.answerAll();
      await done;
      expect(current.lines[0].translation, '一');
      expect(
        current.lines.skip(1).map((line) => line.translationStatus),
        everyElement('interrupted'),
      );
      expect(current.status, 'interrupted');
    },
  );

  test(
    'a file reports its length, the audio read and the audio transcribed',
    () async {
      final engine = FakeEngine()..response = Completer<String>();
      final task = FileTranscriber(ProgressDecoder());
      final current = record(0);
      final run = task.transcribe(
        record: current,
        engine: engine,
        store: MemoryStore(),
        onChanged: () {},
      );
      await pump();
      // The first piece is with the engine while the decoder reads on.
      expect(task.durationMs, 6000);
      expect(task.decodedMs, 2000);
      expect(task.processedMs, 0);
      engine.response!.complete('Hello there.');
      expect(await run, isTrue);
      expect(task.decodedMs, 6000);
      expect(task.processedMs, 6000);
      expect(current.lines, hasLength(3));
    },
  );

  test("FFmpeg's description of a file gives its length", () {
    expect(
      FfmpegAudioDecoder.parseDuration(
        "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'talk.m4a':\n"
        '  Duration: 01:13:19.25, start: 0.000000, bitrate: 64 kb/s',
      ),
      4399250,
    );
    expect(FfmpegAudioDecoder.parseDuration('  Duration: 00:00:02.5,'), 2500);
    expect(FfmpegAudioDecoder.parseDuration('  Duration: N/A, start'), isNull);
    expect(FfmpegAudioDecoder.parseDuration(''), isNull);
  });
}
