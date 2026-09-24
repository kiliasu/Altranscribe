import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/services/transcription/transcript_assembler.dart';
import 'package:altranscribe/data/services/remote/shared_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';
import '../files/file_transcription_test.dart' show FileDecoderFake;
import 'realtime_test.dart' show until;
import '../remote/remote_test.dart' show startHost;

class SequenceEngine extends FakeEngine {
  SequenceEngine(this.texts);
  final List<String> texts;
  int calls = 0;
  Completer<void>? first;
  @override
  Future<String> transcribe(Uint8List wave, String language) async {
    final index = calls++;
    if (index == 0) await first?.future;
    return texts[index];
  }
}

Map<String, Object?> snapshot(
  int end, {
  bool partial = true,
  bool continues = false,
  int start = 0,
  String source = 'microphone',
}) => {
  ...chunk(source, start),
  'endMs': end,
  'partial': partial,
  'continues': continues,
};

TranscriptRecord record() => TranscriptRecord(
  id: 'session-100',
  createdAt: DateTime(2026),
  language: 'zh',
  sources: ['microphone', 'system'],
  lines: [],
);

void main() {
  test('reading boundaries preserve abbreviations, decimals, punctuation and emoji', () {
    expect(
      transcriptSentences(
        'Dr. Smith uses v3.5. It costs 2.50 dollars. 中文第一句。第二句！',
      ),
      ['Dr. Smith uses v3.5.', 'It costs 2.50 dollars.', '中文第一句。', '第二句！'],
    );
    expect(transcriptSentences('他说：“你好。”然后离开。'), ['他说：“你好。”', '然后离开。']);
    final long = '${'词语😀' * 120}。';
    final parts = transcriptSentences(long);
    expect(parts.length, greaterThan(1));
    expect(parts.every((part) => part.runes.length <= 100), true);
    expect(parts.join(), long);
    expect(parts.every((part) => !part.contains('\uFFFD')), true);
    expect(
      transcriptSentences('See https://example.com/a.b for details.\nNext.'),
      ['See https://example.com/a.b for details.', 'Next.'],
    );
  });

  test('snapshots revise the same audio window; final sentences retain timing and reload', () {
    final item = record(), assembler = TranscriptAssembler();
    void add(String text, int end, {bool partial = true}) => assembler.accept(
      item,
      source: 'microphone',
      startMs: 0,
      endMs: end,
      text: text,
      partial: partial,
    );
    add('识别错字', 3000);
    expect(item.lines.single.transcriptionStatus, 'partial');
    add('识别正确内容。还有后续', 6000);
    expect(item.lines.map((line) => line.text), ['识别正确内容。', '还有后续']);
    expect(
      item.lines.every((line) => line.transcriptionStatus == 'partial'),
      true,
    );
    add('识别正确内容。还有后续完整句。', 8000, partial: false);
    expect(item.lines.length, 2);
    expect(item.lines.first.startMs, 0);
    expect(item.lines.last.endMs, 8000);
    expect(item.lines.first.endMs, item.lines.last.startMs);
    expect(item.lines.every((line) => line.timingEstimated), true);
    final loaded = TranscriptRecord.fromJson(item.toJson());
    expect(
      loaded.lines.every((line) => line.transcriptionStatus == 'done'),
      true,
    );
    expect(loaded.lines.last.text, '还有后续完整句。');
    expect(loaded.lines.last.timingEstimated, true);
    final old = Map<String, dynamic>.from(item.lines.first.toJson())
      ..remove('timingEstimated');
    expect(TranscriptLine.fromJson(old).timingEstimated, false);
  });

  test(
    'unfinished tails join only continuous adjacent audio from the same source',
    () {
      final item = record(), assembler = TranscriptAssembler();
      List<TranscriptLine> add(
        String source,
        int start,
        int end,
        String text, {
        bool continues = false,
      }) => assembler.accept(
        item,
        source: source,
        startMs: start,
        endMs: end,
        text: text,
        continues: continues,
      );
      add('microphone', 0, 15000, '我们今天主要讨论的是', continues: true);
      add('system', 1000, 16000, '另一段声音。');
      final merged = add('microphone', 15000, 21000, '如何及时显示字幕。下一步再验证。');
      expect(merged.map((line) => line.text), [
        '我们今天主要讨论的是如何及时显示字幕。',
        '下一步再验证。',
      ]);
      expect(
        item.lines.where((line) => line.source == 'system').single.text,
        '另一段声音。',
      );
      add('microphone', 25000, 27000, '这是新句');
      add('microphone', 27000, 28000, '暂停后继续');
      expect(item.lines.last.text, '暂停后继续'); // No continuity marker.
      add('system', 16000, 18000, 'Finished.', continues: true);
      add('system', 18000, 19000, 'Next.');
      expect(item.lines.any((line) => line.text == 'Finished. Next.'), false);
    },
  );

  test('preview is removed when the final VAD result has no speech', () {
    final item = record(), assembler = TranscriptAssembler();
    assembler.accept(
      item,
      source: 'system',
      startMs: 0,
      endMs: 3000,
      text: 'Unconfirmed guess',
      partial: true,
    );
    assembler.accept(item, source: 'system', startMs: 0, endMs: 4000, text: '');
    expect(item.lines, isEmpty);
  });

  test('live preview appears before finalization, replaces itself and translates final sentences', () async {
    final engine = SequenceEngine(['草稿', '正确原文。还没说完', '正确原文。现在说完了。']);
    final audio = FakeAudio(), translator = FakeTranslator();
    final live =
        RealtimeController(
            audio: audio,
            engine: engine,
            store: MemoryStore(),
            translator: translator,
          )
          ..initialized = true
          ..generateSummary = false;
    addTearDown(live.dispose);
    await live.start(
      microphone: true,
      system: false,
      language: 'zh',
      targetLanguage: 'en',
    );
    audio.events.add(snapshot(3000));
    await until(() => live.record!.lines.isNotEmpty);
    expect(live.record!.lines.single.text, '草稿');
    expect(live.active, true);
    expect(translator.calls, isEmpty);
    audio.events.add(snapshot(6000));
    await until(() => live.record!.lines.length == 2);
    expect(live.record!.lines.any((line) => line.text == '草稿'), false);
    audio.finalEvents.add(snapshot(8000, partial: false));
    await live.stop();
    expect(live.records.single.lines.map((line) => line.text), [
      '正确原文。',
      '现在说完了。',
    ]);
    expect(translator.calls.map((call) => call.$1), ['正确原文。', '现在说完了。']);
    expect(
      live.records.single.lines.every(
        (line) => line.translationStatus == 'done',
      ),
      true,
    );
  });

  test('slow inference coalesces previews and keeps final audio ahead of stale snapshots', () async {
    final engine = SequenceEngine(['Early preview', 'Final sentence.'])
      ..first = Completer<void>();
    final audio = FakeAudio();
    final live =
        RealtimeController(audio: audio, engine: engine, store: MemoryStore())
          ..initialized = true
          ..generateSummary = false;
    addTearDown(live.dispose);
    await live.start(microphone: true, system: false, language: 'en');
    audio.events.add(snapshot(3000));
    await until(() => engine.calls == 1);
    audio.events.addAll(List.generate(20, (_) => snapshot(6000)));
    audio.events.add(snapshot(9000, partial: false));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(live.pending, 2);
    expect(live.error, isNull);
    engine.first!.complete();
    await until(
      () => live.record!.lines.lastOrNull?.transcriptionStatus == 'done',
    );
    await live.stop();
    expect(engine.calls, 2);
    expect(live.records.single.lines.single.text, 'Final sentence.');
  });

  test('joining a tail discards its stale in-flight translation and translates the new whole', () async {
    final engine = SequenceEngine(['The next', 'sentence continues.']);
    final audio = FakeAudio(), translator = FakeTranslator();
    final stale = translator.response = Completer<String>();
    final live =
        RealtimeController(
            audio: audio,
            engine: engine,
            store: MemoryStore(),
            translator: translator,
          )
          ..initialized = true
          ..generateSummary = false;
    addTearDown(live.dispose);
    await live.start(
      microphone: true,
      system: false,
      language: 'en',
      targetLanguage: 'zh',
    );
    audio.events.add(snapshot(15000, partial: false, continues: true));
    await until(() => translator.calls.length == 1);
    audio.events.add(snapshot(20000, start: 15000, partial: false));
    await until(
      () => live.record!.lines.single.text == 'The next sentence continues.',
    );
    expect(live.record!.lines.single.translation, isNull);
    translator.response = null;
    stale.complete('旧译文');
    await live.stop();
    expect(live.records.single.lines.single.translation, '测试译文');
    expect(translator.calls.map((call) => call.$1), [
      'The next',
      'The next sentence continues.',
    ]);
  });

  test('many short sentences in one audio window do not exhaust the translation queue', () async {
    final engine = SequenceEngine([
      List.generate(12, (i) => 'Sentence $i.').join(' '),
    ]);
    final audio = FakeAudio(), translator = FakeTranslator();
    final live =
        RealtimeController(
            audio: audio,
            engine: engine,
            store: MemoryStore(),
            translator: translator,
          )
          ..initialized = true
          ..generateSummary = false;
    addTearDown(live.dispose);
    await live.start(
      microphone: true,
      system: false,
      language: 'en',
      targetLanguage: 'zh',
    );
    audio.finalEvents.add(snapshot(15000, partial: false));
    await live.stop();
    expect(live.records.single.lines.length, 12);
    expect(translator.calls.length, 12);
    expect(
      live.records.single.lines.every(
        (line) => line.translationStatus == 'done',
      ),
      true,
    );
    expect(live.pendingTranslations, 0);
  });

  test('file sentences split and join before cleanup and translation without losing content', () async {
    final engine = SequenceEngine([
      'First sentence. The next',
      'sentence continues. Last sentence!',
    ]);
    final translator = FakeTranslator();
    final live =
        RealtimeController(
            audio: FakeAudio(),
            engine: engine,
            store: MemoryStore(),
            translator: translator,
            fileDecoder: FileDecoderFake(),
          )
          ..initialized = true
          ..generateSummary = false;
    addTearDown(live.dispose);
    await live.startFiles(
      paths: ['fixture.wav'],
      language: 'en',
      targetLanguage: 'zh',
      summaryLanguage: 'zh',
      options: const CleanupOptions(),
    );
    final lines = live.records.single.lines;
    expect(lines.map((line) => line.text), [
      'First sentence.',
      'The next sentence continues.',
      'Last sentence!',
    ]);
    expect(lines.first.startMs, 0);
    expect(lines.last.endMs, 4000);
    expect(
      translator.calls.map((call) => call.$1),
      lines.map((line) => line.text),
    );
    expect(lines.every((line) => line.translationStatus == 'done'), true);
  });

  test(
    'Whisper Remote uses the same provisional and final sentence assembly',
    () async {
      final host = SharedHost(
        engine: SequenceEngine([
          'Remote draft',
          'Remote final. Next sentence.',
        ]),
        translator: FakeTranslator(),
      );
      await startHost(host);
      addTearDown(() async {
        await host.stop();
        host.dispose();
      });
      final live = fakeController()
        ..useRemote = true
        ..generateSummary = false;
      live.remoteConnection.address = host.address;
      live.remoteConnection.token = host.token;
      addTearDown(live.dispose);
      await live.start(microphone: true, system: false, language: 'en');
      final audio = live.audio as FakeAudio;
      audio.events.add(snapshot(3000));
      await until(() => live.record!.lines.isNotEmpty);
      expect(live.record!.lines.single.transcriptionStatus, 'partial');
      audio.finalEvents.add(snapshot(5000, partial: false));
      await live.stop();
      expect(live.records.single.lines.map((line) => line.text), [
        'Remote final.',
        'Next sentence.',
      ]);
      expect(host.running, true);
    },
  );
}
