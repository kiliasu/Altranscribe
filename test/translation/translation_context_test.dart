import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';
import '../transcription/realtime_test.dart' show until;
import '../files/file_transcription_test.dart' show FileDecoderFake;

import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/models/caption_preferences.dart';

void main() {
  test(
    'caption and translation-context preferences survive controller restart',
    () async {
      final root = Directory('build/test-data');
      await root.create(recursive: true);
      final directory = await root.createTemp('caption-settings-');
      addTearDown(() => directory.delete(recursive: true));
      RealtimeController controller() => RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: RecordStore(directory),
        translator: FakeTranslator(),
        catalog: FakeModelCatalog(),
      );
      final first = controller();
      final second = controller();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      first.translationContext = const TranslationContextPolicy(
        automatic: false,
        count: 3,
      );
      first.translationRules = 'Keep technical speech neutral. No emoji.';
      await first.setCaptionPreferences(
        const CaptionPreferences(
          sentences: 5,
          original: false,
          translation: true,
          opacity: .6,
          fontSize: 32,
          font: 'NotoSansSC',
        ),
      );
      await second.initialize();
      expect(
        second.captionPreferences.toJson(),
        first.captionPreferences.toJson(),
      );
      expect(
        second.translationContext.toJson(),
        first.translationContext.toJson(),
      );
      expect(second.captionsVisible, false);
      expect(second.translationRules, first.translationRules);
    },
  );
  test('context uses prior completed same-source entries with manual and automatic bounds', () {
    TranscriptLine line(int start, String source, String text) =>
        TranscriptLine(
          source: source,
          startMs: start,
          endMs: start + 1000,
          text: text,
          translation: '译文$text',
          translationStatus: 'done',
        );
    final old = line(0, 'system', 'old');
    final mic = line(120000, 'microphone', 'other microphone');
    final prior = line(122000, 'system', 'prior');
    final partial = line(124000, 'system', 'unfinished')
      ..transcriptionStatus = 'partial';
    final current = line(126000, 'system', 'current');
    final future = line(128000, 'system', 'future');
    final record = TranscriptRecord(
      id: 'session-1',
      createdAt: DateTime(2026),
      language: 'en',
      sources: ['microphone', 'system'],
      lines: [old, mic, prior, partial, current, future],
    );
    expect(
      const TranslationContextPolicy()
          .select(record, current)
          .map((c) => c.text),
      ['prior'],
    );
    expect(
      const TranslationContextPolicy(
        automatic: false,
        count: 20,
      ).select(record, current).map((c) => c.text),
      ['old', 'prior'],
    );
    expect(
      const TranslationContextPolicy(
        automatic: false,
        count: 1,
      ).select(record, current).map((c) => c.text),
      ['prior'],
    );
    expect(
      const TranslationContextPolicy(
        automatic: false,
        count: 0,
      ).select(record, current),
      isEmpty,
    );
    final bounded = TranslationContextPolicy.bound([
      TranslationContext('字' * 3000, '文' * 3000),
    ]);
    expect(
      bounded.single.text.runes.length +
          bounded.single.translation!.runes.length,
      2400,
    );
  });

  test(
    'realtime supplies context without crossing sources or sessions',
    () async {
      final live = fakeController()..generateSummary = false;
      addTearDown(live.dispose);
      final translator = live.translator as FakeTranslator;
      final audio = live.audio as FakeAudio;
      await live.start(
        microphone: true,
        system: true,
        language: 'en',
        targetLanguage: 'zh',
      );
      for (final entry in [
        ('system', 0),
        ('microphone', 2000),
        ('system', 4000),
      ]) {
        audio.events.add(chunk(entry.$1, entry.$2));
        final count = translator.calls.length + 1;
        await until(
          () => translator.calls.length == count && !live.translating,
        );
      }
      expect(translator.contexts[0], isEmpty);
      expect(translator.contexts[1], isEmpty);
      expect(translator.contexts[2].single.translation, '测试译文');
      await live.stop();
      await live.start(
        microphone: false,
        system: true,
        language: 'en',
        targetLanguage: 'zh',
      );
      audio.finalEvents.add(chunk('system', 0));
      await live.stop();
      expect(translator.contexts.last, isEmpty);
    },
  );

  test('file translation reads preceding revised text and never later file entries', () async {
    final translator = FakeTranslator();
    final live = RealtimeController(
      audio: FakeAudio(),
      engine: FakeEngine(),
      store: MemoryStore(),
      translator: translator,
      fileDecoder: FileDecoderFake(),
    )..initialized = true;
    addTearDown(live.dispose);
    live.generateSummary = false;
    await live.startFiles(
      paths: ['test.wav'],
      language: 'en',
      summaryLanguage: 'zh',
      targetLanguage: 'zh',
      options: const CleanupOptions(),
    );
    await until(() => !live.active);
    expect(translator.contexts.length, 2);
    expect(translator.contexts.first, isEmpty);
    expect(translator.contexts.last.single.text, translator.calls.first.$1);
  });

  for (final provider in [LlmProvider.ollama, LlmProvider.openAICompatible]) {
    test(
      '$provider sends bounded context as data and translates current text only',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final service = LocalLlmService();
        addTearDown(() async {
          service.stop();
          await server.close(force: true);
        });
        final requests = <Map>[];
        server.listen((request) async {
          Object body;
          if (request.uri.path.endsWith('tags')) {
            body = {
              'models': [
                {'name': 'test'},
              ],
            };
          } else if (request.uri.path.endsWith('models')) {
            body = {
              'data': [
                {'id': 'test'},
              ],
            };
          } else if (request.uri.path.endsWith('ps')) {
            body = {'models': []};
          } else {
            requests.add(
              jsonDecode(
                await request.cast<List<int>>().transform(utf8.decoder).join(),
              ) as Map,
            );
            body = provider == LlmProvider.ollama
                ? {
                    'message': {'content': '它已经完成。'},
                    'done': true,
                    'done_reason': 'stop',
                  }
                : {
                    'choices': [
                      {
                        'message': {'content': '它已经完成。'},
                        'finish_reason': 'stop',
                      },
                    ],
                  };
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(body));
          await request.response.close();
        });
        await service.prepare(
          'http://127.0.0.1:${server.port}',
          'test',
          provider: provider,
        );
        await service.translate(
          'It is complete.',
          'en',
          'zh',
          context: const [
            TranslationContext('The GPU job started.', 'GPU 任务开始。'),
          ],
        );
        final messages = requests.single['messages'] as List;
        expect(
          messages.first['content'],
          contains('Translate only current_text'),
        );
        final data = jsonDecode(messages[1]['content'] as String) as Map;
        expect(data['current_text'], 'It is complete.');
        expect(data['context'][0]['original'], 'The GPU job started.');
      },
    );
  }

  test('an earlier line naming the same person or term is sent as context', () {
    TranscriptLine line(int second, String text, [String? translation]) =>
        TranscriptLine(
          source: 'microphone',
          startMs: second * 1000,
          endMs: second * 1000 + 2000,
          text: text,
          translation: translation,
          translationStatus: translation == null ? 'none' : 'done',
        );
    final hinata = line(0, 'Hinata will lead the review.', '日向会主持这次评审。');
    // The other source and unfinished text are never referenced.
    final otherSource = TranscriptLine(
      source: 'system',
      startMs: 20000,
      endMs: 22000,
      text: 'Hinata is on the call.',
      translation: '比娜塔在通话中。',
      translationStatus: 'done',
    );
    final unfinished = line(30, 'Hinata wants GPU numbers', '日向想要 GPU 数据')
      ..transcriptionStatus = 'partial';
    final gpu = line(5, 'The build uses GPU inference.', '构建使用 GPU 推理。');
    final untranslated = line(10, 'Hinata joined late.');
    final current = line(240, 'Hinata said the GPU build is ready.');
    final record = TranscriptRecord(
      id: 'session-1',
      createdAt: DateTime(2026),
      language: 'en',
      sources: ['microphone'],
      lines: [
        hinata,
        gpu,
        untranslated,
        otherSource,
        unfinished,
        for (var i = 0; i < 7; i++)
          line(200 + i * 5, 'Item $i moved to Friday.', '第 $i 项移到了周五。'),
        current,
      ],
    );
    final context = const TranslationContextPolicy().select(record, current);
    // Two references come first, then the six most recent lines.
    expect(context.map((item) => item.text).take(2), [hinata.text, gpu.text]);
    expect(context.first.translation, '日向会主持这次评审。');
    expect(context, hasLength(8));
    // A name that opens the sentence counts; common openers do not.
    expect(
      TranslationContextPolicy.nameTokens('Hinata said the build is ready.'),
      {'Hinata'},
    );
    expect(
      TranslationContextPolicy.nameTokens(
        "The review moved. We asked Geoffrey and NASA. Let's go.",
      ),
      {'Geoffrey', 'NASA'},
    );
    expect(TranslationContextPolicy.nameTokens('我们明天和 Hinata 一起用 whisper。'), {
      'Hinata',
      'whisper',
    });
    expect(TranslationContextPolicy.nameTokens('ヒナタさんは来ます。'), {'ヒナタ'});
    expect(
      TranslationContextPolicy.mentions('Geoffreys arrived', 'Geoffrey'),
      false,
    );
    expect(
      const TranslationContextPolicy(
        automatic: false,
        count: 0,
      ).select(record, current),
      isEmpty,
    );
  });
}
