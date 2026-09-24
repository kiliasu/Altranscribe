import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';
import '../transcription/realtime_test.dart' show until;

void main() {
  test('separate settings and summary preference survive reopening', () async {
    final root = Directory('build/test-data');
    await root.create(recursive: true);
    final directory = await root.createTemp('settings-');
    addTearDown(() => directory.delete(recursive: true));
    final store = RecordStore(directory);
    await store.initialize();
    await store.saveSettings({
      'model': r'C:\old-install\ggml-large-v3-turbo.bin',
      'microphoneDevice': 'mic-42',
    });
    RealtimeController create() => RealtimeController(
      audio: FakeAudio(),
      engine: FakeEngine(),
      store: store,
      translator: FakeTranslator(),
      catalog: FakeModelCatalog(),
    );
    final first = create();
    addTearDown(first.dispose);
    await first.initialize();
    expect(first.model, 'build/test-models/ggml-large-v3-turbo.bin');
    expect(first.generateSummary, true);
    expect(first.llmProvider, LlmProvider.ollama);
    first.llmProvider = LlmProvider.openAICompatible;
    first.translationAddress = 'http://127.0.0.1:1234/v1';
    first.translationModel = 'saved-model';
    first.microphoneDenoise = false;
    first.microphoneAutoGain = false;
    first.systemDenoise = true;
    first.systemAutoGain = true;
    await first.setGenerateSummary(false);
    final reopened = create();
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.error, isNull);
    expect(reopened.generateSummary, false);
    expect(reopened.llmProvider, LlmProvider.openAICompatible);
    expect(reopened.translationAddress, first.translationAddress);
    expect(reopened.translationModel, 'saved-model');
    expect(reopened.microphoneDevice, 'mic-42');
    expect(reopened.microphoneDenoise, false);
    expect(reopened.microphoneAutoGain, false);
    expect(reopened.systemDenoise, true);
    expect(reopened.systemAutoGain, true);
  });

  test('model detection rejects partial and wrong-format files', () async {
    final root = Directory('build/test-data');
    await root.create(recursive: true);
    final directory = await root.createTemp('models-');
    addTearDown(() => directory.delete(recursive: true));
    final catalog = ModelCatalog(directory);
    final tiny = ModelCatalog.models.firstWhere((item) => item.id == 'tiny');
    expect((await catalog.scan())['tiny'], ModelAvailability.missing);
    final file = File(catalog.path(tiny));
    await file.writeAsBytes([0x6c, 0x6d, 0x67, 0x67]);
    expect((await catalog.scan())['tiny'], ModelAvailability.incomplete);
    final handle = await file.open(mode: FileMode.append);
    await handle.truncate(tiny.bytes);
    await handle.close();
    expect((await catalog.scan())['tiny'], ModelAvailability.available);
    final invalid = await file.open(mode: FileMode.append);
    await invalid.setPosition(0);
    await invalid.writeFrom([0, 0, 0, 0]);
    await invalid.close();
    expect((await catalog.scan())['tiny'], ModelAvailability.incomplete);
    await file.delete();
    expect((await catalog.scan())['tiny'], ModelAvailability.missing);
  });

  test(
    'summary is independent of translation and raw text is saved first',
    () async {
      final controller = fakeController()..generateSummary = true;
      addTearDown(controller.dispose);
      final translator = controller.translator as FakeTranslator;
      translator.summaryResponse = Completer<RecordSummary>();
      controller.llmProvider = LlmProvider.openAICompatible;
      await controller.start(
        microphone: true,
        system: false,
        language: 'en',
        summaryLanguage: 'zh',
      );
      expect(translator.prepared, 1);
      expect(translator.provider, LlmProvider.openAICompatible);
      (controller.audio as FakeAudio).finalEvents.add(chunk('microphone', 0));
      final stopping = controller.stop();
      await until(() => controller.generatingSummary);
      final savedBeforeSummary = (await controller.store.loadRecords()).single;
      expect(savedBeforeSummary.status, 'completed');
      expect(savedBeforeSummary.lines.single.text, isNotEmpty);
      expect(savedBeforeSummary.title, isNull);
      expect(savedBeforeSummary.summaryStatus, 'interrupted');
      expect(controller.phase, SessionPhase.stopping);
      expect(translator.calls, isEmpty);
      expect(translator.summaryCalls.single.$2, 'zh');
      translator.summaryResponse!.complete(const RecordSummary('独立标题', '独立摘要'));
      await stopping;
      final restored = controller.records.single;
      expect(restored.displayTitle, '独立标题');
      expect(restored.summary, '独立摘要');
      expect(restored.summaryStatus, 'done');
      expect(restored.llmProvider, 'openAICompatible');
      expect(controller.generatingSummary, false);
    },
  );

  test('failed summary preserves originals and date title', () async {
    final controller = fakeController()..generateSummary = true;
    addTearDown(controller.dispose);
    (controller.translator as FakeTranslator).summaryFailure =
        'Backend stopped';
    await controller.start(
      microphone: false,
      system: true,
      language: 'en',
      targetLanguage: 'zh',
    );
    (controller.audio as FakeAudio).finalEvents.add(chunk('system', 0));
    await controller.stop();
    final saved = controller.records.single;
    expect(saved.summaryStatus, 'failed');
    expect(saved.summaryError, contains('Backend stopped'));
    expect(saved.title, isNull);
    expect(
      saved.displayTitle,
      saved.createdAt.toLocal().toString().split('.').first,
    );
    expect(saved.lines.single.text, isNotEmpty);
    expect(saved.lines.single.translationStatus, 'done');
    expect(saved.status, 'completed');
    expect(controller.error, isNull);
  });

  test(
    'summary off never prepares LLM; silence never invents a summary',
    () async {
      for (final enabled in [false, true]) {
        final controller = fakeController()..generateSummary = enabled;
        addTearDown(controller.dispose);
        await controller.start(microphone: true, system: false, language: 'en');
        await controller.stop();
        final translator = controller.translator as FakeTranslator;
        expect(translator.prepared, enabled ? 1 : 0);
        expect(translator.summaryCalls, isEmpty);
        expect(
          controller.records.single.summaryStatus,
          enabled ? 'empty' : 'none',
        );
      }
    },
  );

  test(
    'unavailable LLM blocks summary session before starting audio or Whisper',
    () async {
      final controller = fakeController()..generateSummary = true;
      addTearDown(controller.dispose);
      (controller.translator as FakeTranslator).prepareFailure =
          'llmUnavailable';
      await controller.start(microphone: true, system: false, language: 'en');
      await until(() => !controller.active);
      expect(controller.error, contains('llmUnavailable'));
      expect((controller.audio as FakeAudio).options, isNull);
      expect((controller.engine as FakeEngine).starts, 0);
      expect(controller.records, isEmpty);
    },
  );

  test('legacy records and interrupted summaries remain readable', () {
    final json = {
      'version': 1,
      'id': 'session-42',
      'createdAt': DateTime(2026).toIso8601String(),
      'language': 'en',
      'sources': ['system'],
      'lines': [],
      'status': 'completed',
    };
    final legacy = TranscriptRecord.fromJson(json);
    expect(legacy.summaryStatus, 'none');
    expect(legacy.title, isNull);
    expect(legacy.displayTitle, startsWith('2026'));
    json['summaryStatus'] = 'pending';
    expect(TranscriptRecord.fromJson(json).summaryStatus, 'interrupted');
  });

  test('compatible API handles models, translations, long summaries and malformed output', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final service = LocalLlmService();
    addTearDown(() async {
      service.stop();
      await server.close(force: true);
    });
    final address = 'http://127.0.0.1:${server.port}/v1/';
    final requests = <Map<String, dynamic>>[];
    var output = '译文';
    var finish = 'stop';
    server.listen((request) async {
      Object body;
      if (request.uri.path == '/v1/models') {
        body = {
          'data': [
            {'id': 'local-model'},
          ],
        };
      } else if (request.uri.path == '/v1/chat/completions') {
        requests.add(
          jsonDecode(
            await request.cast<List<int>>().transform(utf8.decoder).join(),
          ) as Map<String, dynamic>,
        );
        body = {
          'choices': [
            {
              'message': {'content': output},
              'finish_reason': finish,
            },
          ],
        };
      } else {
        request.response.statusCode = 404;
        body = {'error': 'Unexpected endpoint'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
    expect(
      await service.models(address, provider: LlmProvider.openAICompatible),
      ['local-model'],
    );
    await service.prepare(
      address,
      'local-model',
      provider: LlmProvider.openAICompatible,
    );
    expect(await service.translate('Original', 'en', 'zh'), '译文');
    expect(requests.single['max_tokens'], 384);
    expect(requests.single.containsKey('options'), false);
    finish = 'length';
    await expectLater(
      service.translate('Original', 'en', 'zh'),
      throwsFormatException,
    );
    finish = 'stop';
    output = '```json\n{"title":"标题","summary":"摘要"}\n```';
    requests.clear();
    final result = await service.summarize(['前' * 6000, '最后的关键决定'], 'zh');
    expect(result.title, '标题');
    expect(requests.length, 3); // Two parts and one final reduction.
    expect(requests[1]['messages'][1]['content'], contains('最后的关键决定'));
    expect(
      requests.last['messages'][0]['content'],
      contains('Simplified Chinese'),
    );
    expect(requests.every((item) => item['max_tokens'] == 768), true);
    for (final malformed in [
      'not json',
      '{"title":"","summary":"摘要"}',
      '{"title":"标题"}',
    ]) {
      output = malformed;
      await expectLater(
        service.summarize(['Text'], 'en'),
        throwsFormatException,
      );
    }
    service.stop();
    await expectLater(service.summarize(['Text'], 'en'), throwsStateError);
  });
}
