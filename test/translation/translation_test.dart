import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';
import '../transcription/realtime_test.dart' show until;

void main() {
  test(
    'translation overload marks skipped translations while ASR continues',
    () async {
      final controller = fakeController();
      addTearDown(controller.dispose);
      final translator = controller.translator as FakeTranslator;
      translator.response = Completer<String>();
      await controller.start(
        microphone: false,
        system: true,
        language: 'en',
        targetLanguage: 'zh',
      );
      for (int i = 0; i < 10; i++) {
        (controller.audio as FakeAudio).events.add(chunk('system', i * 2000));
        await until(() => controller.record!.lines.length > i);
      }
      expect(controller.phase, SessionPhase.listening);
      expect(
        controller.record!.lines.last.translationError,
        'translationTooSlow',
      );
      expect(controller.pendingTranslations, 9);
      translator.response!.complete('译文');
      await controller.stop();
      expect(controller.record!.lines.length, 10);
      expect(
        controller.record!.lines
            .where((line) => line.translationStatus == 'done')
            .length,
        9,
      );
      expect(controller.record!.lines.last.text, isNotEmpty);
    },
  );

  test('GPU detection requires a model GPU backend, not a loaded DLL', () {
    expect(
      WhisperService.gpuBackendFromLog(
        'load_backend: loaded CUDA backend from ggml-cuda.dll',
      ),
      isNull,
    );
    expect(
      WhisperService.gpuBackendFromLog(
        'whisper_backend_init_gpu: using CUDA0 backend\nload_backend: loaded CPU backend',
      ),
      'CUDA0',
    );
    expect(
      WhisperService.gpuBackendFromLog(
        'whisper_backend_init_gpu: using Vulkan0 backend',
      ),
      'Vulkan0',
    );
  });

  test(
    'ASR continues while translation waits, and stop saves both languages',
    () async {
      final controller = fakeController();
      addTearDown(controller.dispose);
      final translator = controller.translator as FakeTranslator;
      translator.response = Completer<String>();
      await controller.start(
        microphone: true,
        system: true,
        language: 'en',
        targetLanguage: 'zh',
      );
      (controller.audio as FakeAudio).events.addAll([
        chunk('system', 2000),
        chunk('microphone', 0),
      ]);
      await until(() => controller.record!.lines.length == 2);
      expect(
        controller.record!.lines.every(
          (line) => line.translationStatus == 'pending',
        ),
        isTrue,
      );
      expect(controller.pending, 0);
      expect(controller.pendingTranslations, 2);
      final stopped = controller.stop();
      expect(controller.phase, SessionPhase.stopping);
      translator.response!.complete('这是译文。');
      await stopped;
      final record = controller.records.single;
      expect(record.targetLanguage, 'zh');
      expect(record.lines.map((line) => line.source), ['microphone', 'system']);
      expect(record.lines.every((line) => line.translation == '这是译文。'), isTrue);
      expect(
        record.lines.every((line) => line.translationStatus == 'done'),
        isTrue,
      );
      expect(
        translator.calls.every((call) => call.$2 == 'en' && call.$3 == 'zh'),
        isTrue,
      );
    },
  );

  test(
    'failed translation preserves original and does not stop transcription',
    () async {
      final controller = fakeController();
      addTearDown(controller.dispose);
      (controller.translator as FakeTranslator).failure = 'Service unavailable';
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
            controller.record!.lines.first.translationStatus == 'failed',
      );
      expect(controller.phase, SessionPhase.listening);
      expect(controller.error, isNull);
      await controller.stop();
      final line = controller.records.single.lines.single;
      expect(line.text, isNotEmpty);
      expect(line.translation, isNull);
      expect(line.translationError, contains('Service unavailable'));
    },
  );

  test('same-language output does not call the translation model', () async {
    final controller = fakeController()..generateSummary = false;
    addTearDown(controller.dispose);
    await controller.start(
      microphone: true,
      system: false,
      language: 'zh',
      targetLanguage: 'zh',
    );
    (controller.audio as FakeAudio).finalEvents.add(chunk('microphone', 0));
    await controller.stop();
    final translator = controller.translator as FakeTranslator;
    expect(translator.prepared, 0);
    expect(translator.calls, isEmpty);
    expect(
      controller.record!.lines.single.translation,
      controller.record!.lines.single.text,
    );
  });

  test(
    'concurrent ASR and translation snapshots preserve the latest record',
    () async {
      final root = Directory('build/test-data');
      await root.create(recursive: true);
      final directory = await root.createTemp('translation-');
      addTearDown(() => directory.delete(recursive: true));
      final store = RecordStore(directory);
      final line = TranscriptLine(
        source: 'system',
        startMs: 0,
        endMs: 3000,
        text: 'Hello',
        translationStatus: 'pending',
      );
      final record = TranscriptRecord(
        id: 'session-1234',
        createdAt: DateTime(2026),
        language: 'en',
        targetLanguage: 'zh',
        translationModel: 'test-model',
        sources: ['system'],
        lines: [line],
      );
      final first = store.save(record);
      line.translation = '你好';
      line.translationStatus = 'done';
      final second = store.save(record);
      record.status = 'completed';
      await Future.wait([first, second, store.save(record)]);
      final restored = (await store.loadRecords()).single;
      expect(restored.lines.single.translation, '你好');
      expect(restored.targetLanguage, 'zh');
      expect(restored.status, 'completed');
      final legacy = TranscriptLine.fromJson({
        'source': 'system',
        'startMs': 0,
        'endMs': 100,
        'text': 'Old record',
      });
      expect(legacy.translationStatus, 'none');
      line.translationStatus = 'pending';
      expect(
        TranscriptLine.fromJson(line.toJson()).translationStatus,
        'interrupted',
      );
    },
  );

  test('Ollama adapter uses installed models and returns only complete translations', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final service = LocalLlmService();
    addTearDown(() async {
      service.stop();
      await server.close(force: true);
    });
    final address = 'http://127.0.0.1:${server.port}';
    final requests = <Map<String, dynamic>>[];
    bool incomplete = false;
    server.listen((request) async {
      Object body;
      switch (request.uri.path) {
        case '/api/tags':
          body = {
            'models': [
              {'name': 'local-model'},
            ],
          };
        case '/api/ps':
          body = {
            'models': [
              {'name': 'local-model', 'size_vram': 1024},
            ],
          };
        case '/api/chat':
          requests.add(
            jsonDecode(
              await request.cast<List<int>>().transform(utf8.decoder).join(),
            ) as Map<String, dynamic>,
          );
          body = {
            'message': {'content': '你好，世界。'},
            'done': true,
            'done_reason': incomplete ? 'length' : 'stop',
          };
        default:
          request.response.statusCode = 404;
          body = {'error': 'Unexpected path'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
    expect(await service.models(address), ['local-model']);
    await service.prepare(address, 'local-model');
    expect(await service.translate('Hello world.', 'en', 'zh'), '你好，世界。');
    expect(service.backend, 'GPU · Ollama');
    expect(requests.single['stream'], false);
    expect(
      requests.single['messages'][0]['content'],
      contains('Simplified Chinese'),
    );
    expect(requests.single['messages'][1]['content'], 'Hello world.');
    incomplete = true;
    await expectLater(
      service.translate('Hello world.', 'en', 'zh'),
      throwsFormatException,
    );
    await expectLater(
      service.prepare(address, 'missing-model'),
      throwsFormatException,
    );
    expect(
      () => LocalLlmService.localAddress('https://external.example'),
      throwsFormatException,
    );
  });
}
