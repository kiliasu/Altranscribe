import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:io';

import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';
import '../transcription/realtime_test.dart' show until;

Future<TranscriptRecord> saveSession(RealtimeController controller) async {
  controller.generateSummary = false;
  await controller.start(microphone: false, system: true, language: 'en');
  (controller.audio as FakeAudio).finalEvents.add(chunk('system', 0));
  await controller.stop();
  return controller.records.firstWhere(
    (item) => item.id == controller.record!.id,
  );
}

class FailingStore extends MemoryStore {
  bool fail = false;
  @override
  Future<void> save(TranscriptRecord record) async {
    if (fail) throw const FileSystemException('Disk unavailable');
    await super.save(record);
  }

  @override
  Future<void> delete(String id) async {
    if (fail) throw const FileSystemException('Disk unavailable');
    await super.delete(id);
  }
}

class DelayedReadStore extends MemoryStore {
  Completer<void>? nextRead;
  final reading = Completer<void>();
  @override
  Future<List<TranscriptRecord>> loadRecords() async {
    final snapshot = await super.loadRecords();
    final delay = nextRead;
    nextRead = null;
    if (delay != null) {
      reading.complete();
      await delay.future;
    }
    return snapshot;
  }
}

void main() {
  test(
    'record deletion persists and does not affect other records or settings',
    () async {
      final root = Directory('build/test-data');
      await root.create(recursive: true);
      final directory = await root.createTemp('delete-record-');
      addTearDown(() => directory.delete(recursive: true));
      final store = RecordStore(directory);
      final controller = RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: store,
        translator: FakeTranslator(),
      )..initialized = true;
      addTearDown(controller.dispose);
      final first = await saveSession(controller);
      final second = await saveSession(controller);
      final temporary = File('${directory.path}/${first.id}.json.tmp');
      await temporary.writeAsString('Interrupted snapshot');
      await controller.deleteRecord(first.id);
      expect(await temporary.exists(), false);
      expect((await store.loadRecords()).single.id, second.id);
      expect(await File('${directory.path}/${first.id}.json').exists(), false);
      expect(await File('${directory.path}/settings.json').exists(), true);
      // Deletion is serialized after snapshots already being written.
      final saving = store.save(first);
      final deleting = store.delete(first.id);
      await Future.wait([saving, deleting]);
      expect((await store.loadRecords()).single.id, second.id);
      expect(() => store.delete('../settings'), throwsArgumentError);
    },
  );

  test(
    'failed deletion retains the record and active records cannot be deleted',
    () async {
      final store = FailingStore();
      final controller = RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: store,
        translator: FakeTranslator(),
      )..initialized = true;
      addTearDown(controller.dispose);
      final saved = await saveSession(controller);
      store.fail = true;
      await expectLater(
        controller.deleteRecord(saved.id),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.records.single.id, saved.id);
      expect(controller.updatingRecordId, isNull);
      store.fail = false;
      await controller.start(microphone: true, system: false, language: 'en');
      final active = controller.record!;
      controller.records.add(active);
      await expectLater(controller.deleteRecord(active.id), throwsStateError);
      expect(() => controller.discard(), throwsStateError);
      await controller.togglePause();
      await controller.discard();
      expect(controller.records.single.id, saved.id);
    },
  );

  for (final pendingTranslation in [false, true]) {
    test(
      'discard waits for pending ${pendingTranslation ? 'translation' : 'inference'} and skips summary',
      () async {
        final controller = fakeController();
        addTearDown(controller.dispose);
        final engine = controller.engine as FakeEngine;
        final translator = controller.translator as FakeTranslator;
        if (pendingTranslation) {
          translator.response = Completer<String>();
        } else {
          engine.response = Completer<String>();
        }
        await controller.start(
          microphone: true,
          system: true,
          language: 'en',
          targetLanguage: 'zh',
        );
        final id = controller.record!.id;
        (controller.audio as FakeAudio).events.add(chunk('microphone', 0));
        await until(
          () => pendingTranslation
              ? controller.translating
              : controller.recognizing,
        );
        await controller.togglePause();
        final discarded = controller.discard();
        expect(controller.phase, SessionPhase.stopping);
        if (pendingTranslation) {
          translator.response!.complete('迟到的译文');
        } else {
          engine.response!.complete('Late transcription');
        }
        await discarded;
        expect(controller.phase, SessionPhase.idle);
        expect(controller.record, isNull);
        expect(controller.records, isEmpty);
        expect((controller.store as MemoryStore).values.containsKey(id), false);
        expect(translator.summaryCalls, isEmpty);
        expect(controller.pending, 0);
        await controller.start(microphone: false, system: true, language: 'en');
        expect(controller.phase, SessionPhase.listening);
        await controller.stop();
      },
    );
  }
  test(
    'an offline LLM reports a readable error and leaves backfill retryable',
    () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final controller =
          RealtimeController(
              audio: FakeAudio(),
              engine: FakeEngine(),
              store: MemoryStore(),
              translator: FakeTranslator(),
            )
            ..initialized = true
            ..translationAddress = 'http://127.0.0.1:$port'
            ..translationModel = 'installed-model';
      addTearDown(controller.dispose);
      final original = await saveSession(controller);
      await expectLater(
        controller.generateRecordSummary(original.id, 'zh'),
        throwsFormatException,
      );
      expect(controller.records.single.summaryError, 'llmUnavailable');
      expect(controller.records.single.needsSummary, true);
      expect(
        controller.records.single.lines.single.text,
        original.lines.single.text,
      );
    },
  );

  test('stopping a session cannot replace a concurrently renamed record with stale data', () async {
    final store = DelayedReadStore();
    final controller = RealtimeController(
      audio: FakeAudio(),
      engine: FakeEngine(),
      store: store,
      translator: FakeTranslator(),
      recordSummarizer: FakeTranslator(),
    )..initialized = true;
    addTearDown(controller.dispose);
    final original = await saveSession(controller);
    await controller.start(microphone: true, system: false, language: 'en');
    final gate = Completer<void>();
    store.nextRead = gate;
    final stopping = controller.stop();
    await store.reading.future;
    await controller.renameRecord(original.id, '并发保存的新标题');
    gate.complete();
    await stopping;
    expect(
      controller.records.firstWhere((item) => item.id == original.id).title,
      '并发保存的新标题',
    );
  });

  test(
    'rename persists without LLM and rejects blank or oversized titles',
    () async {
      final root = Directory('build/test-data');
      await root.create(recursive: true);
      final directory = await root.createTemp('record-actions-');
      addTearDown(() => directory.delete(recursive: true));
      final store = RecordStore(directory);
      await store.initialize();
      final controller = RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: store,
        translator: FakeTranslator(),
        recordSummarizer: FakeTranslator(),
      )..initialized = true;
      addTearDown(controller.dispose);
      final original = await saveSession(controller);
      await controller.renameRecord(original.id, '  我的会议  ');
      final restored = (await store.loadRecords()).single;
      expect(restored.title, '我的会议');
      expect(controller.record!.title, '我的会议');
      expect(restored.lines.single.text, original.lines.single.text);
      expect(restored.createdAt, original.createdAt);
      expect(restored.summaryStatus, 'none');
      expect((controller.recordSummarizer as FakeTranslator).prepared, 0);
      await expectLater(
        controller.renameRecord(original.id, '  '),
        throwsFormatException,
      );
      await expectLater(
        controller.renameRecord(original.id, '长' * 121),
        throwsFormatException,
      );
      expect((await store.loadRecords()).single.title, '我的会议');
    },
  );

  test('backfill saves title and summary, preserves a manual title and avoids duplicate generation', () async {
    final controller = fakeController();
    addTearDown(controller.dispose);
    final original = await saveSession(controller);
    await controller.generateRecordSummary(original.id, 'zh');
    var restored = (await controller.store.loadRecords()).single;
    expect(restored.title, '测试标题');
    expect(restored.summary, '测试摘要');
    expect(restored.summaryLanguage, 'zh');
    expect(restored.summaryProvider, 'ollama');
    expect(restored.createdAt, original.createdAt);
    expect(restored.lines.single.toJson(), original.lines.single.toJson());
    await controller.generateRecordSummary(original.id, 'zh');
    expect(
      (controller.recordSummarizer as FakeTranslator).summaryCalls.length,
      1,
    );
    final next = await saveSession(controller);
    final nextId = next.id;
    await controller.renameRecord(nextId, '手动标题');
    await controller.generateRecordSummary(nextId, 'zh');
    restored = (await controller.store.loadRecords()).firstWhere(
      (item) => item.id == nextId,
    );
    expect(restored.title, '手动标题');
    expect(restored.summary, '测试摘要');
  });

  test('backfill failure retains transcript and can retry', () async {
    final controller = fakeController();
    addTearDown(controller.dispose);
    final original = await saveSession(controller);
    final llm = controller.recordSummarizer as FakeTranslator;
    llm.prepareFailure = 'llmUnavailable';
    await expectLater(
      controller.generateRecordSummary(original.id, 'zh'),
      throwsStateError,
    );
    var saved = controller.records.single;
    expect(saved.needsSummary, true);
    expect(saved.summaryStatus, 'failed');
    expect(saved.summaryError, contains('llmUnavailable'));
    expect(saved.title, isNull);
    expect(saved.status, 'completed');
    expect(saved.lines.single.text, original.lines.single.text);
    expect(controller.updatingRecordId, isNull);
    llm.prepareFailure = null;
    await controller.generateRecordSummary(original.id, 'zh');
    saved = (await controller.store.loadRecords()).single;
    expect(saved.summaryStatus, 'done');
    expect(saved.summaryError, isNull);
  });

  test(
    'backfill uses an independent LLM while live translation continues',
    () async {
      final controller = fakeController();
      addTearDown(controller.dispose);
      final original = await saveSession(controller);
      final llm = controller.recordSummarizer as FakeTranslator;
      llm.summaryResponse = Completer<RecordSummary>();
      final generated = controller.generateRecordSummary(original.id, 'zh');
      await until(() => llm.summaryCalls.isNotEmpty);
      expect(controller.updatingRecordId, original.id);
      await expectLater(
        controller.generateRecordSummary(original.id, 'zh'),
        throwsStateError,
      );
      await expectLater(
        controller.renameRecord(original.id, 'Too early'),
        throwsStateError,
      );
      await controller.start(
        microphone: true,
        system: false,
        language: 'en',
        targetLanguage: 'zh',
      );
      (controller.audio as FakeAudio).events.add(chunk('microphone', 0));
      await until(
        () =>
            controller.record!.lines.isNotEmpty &&
            controller.record!.lines.single.translationStatus == 'done',
      );
      expect(controller.phase, SessionPhase.listening);
      expect((controller.translator as FakeTranslator).calls.length, 1);
      llm.summaryResponse!.complete(const RecordSummary('后台标题', '后台摘要'));
      await generated;
      expect(controller.phase, SessionPhase.listening);
      await controller.stop();
      expect(
        controller.records.firstWhere((item) => item.id == original.id).title,
        '后台标题',
      );
    },
  );

  test(
    'failed disk writes do not publish edited titles or generated summaries',
    () async {
      final store = FailingStore();
      final controller = RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: store,
        translator: FakeTranslator(),
        recordSummarizer: FakeTranslator(),
      )..initialized = true;
      addTearDown(controller.dispose);
      final original = await saveSession(controller);
      store.fail = true;
      await expectLater(
        controller.renameRecord(original.id, 'Unsaved'),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.records.single.title, isNull);
      await expectLater(
        controller.generateRecordSummary(original.id, 'zh'),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.records.single.summaryStatus, 'none');
      expect(
        (controller.recordSummarizer as FakeTranslator).summaryCalls,
        isEmpty,
      );
      expect(controller.updatingRecordId, isNull);
    },
  );
}
