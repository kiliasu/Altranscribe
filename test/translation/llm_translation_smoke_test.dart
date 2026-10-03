// Optional checks against a real local model. They are skipped unless a model
// is named, and never download one:
// flutter test test/translation/llm_translation_smoke_test.dart --dart-define=LLM_SMOKE_MODEL=<Ollama model>
// Add --dart-define=LLM_SMOKE_URL=<address> for a server other than Ollama's
// default. The text is synthetic.
// ignore_for_file: avoid_print

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _model = String.fromEnvironment('LLM_SMOKE_MODEL');
const _address = String.fromEnvironment(
  'LLM_SMOKE_URL',
  defaultValue: 'http://127.0.0.1:11434',
);
const _skip = _model == '';
const _timeout = Timeout(Duration(minutes: 5));

TranscriptLine _line(int second, String text, [String? translation]) =>
    TranscriptLine(
      source: 'microphone',
      startMs: second * 1000,
      endMs: second * 1000 + 3000,
      text: text,
      translation: translation,
      translationStatus: translation == null ? 'none' : 'done',
    );

void main() {
  late LocalLlmService service;
  setUp(() async {
    service = LocalLlmService();
    await service.prepare(_address, _model);
  });
  tearDown(() => service.stop());

  test(
    'fillers, fragments and repeated sounds are translated, keeping intensity',
    () async {
      for (final (text, source, target) in [
        ('Um, so—', 'en', 'zh'),
        ('uh', 'en', 'zh'),
        ('嗯……那个', 'zh', 'en'),
        ('哦' * 240, 'zh', 'en'),
        ('う ' * 36, 'ja', 'zh'),
      ]) {
        final result = await service.translate(text, source, target);
        print('${String.fromCharCodes(text.runes.take(12))} → $result');
        expect(result.trim(), isNotEmpty, reason: text);
      }
      // A scream stays a scream, alone or before a sentence.
      final scream = RegExp(
        r'^\W*(?:a{2,}h*|ah{2,}|(?:ah\W+){2,})',
        caseSensitive: false,
      );
      for (final text in ['啊啊啊啊啊啊', '啊啊啊啊啊啊，我终于做完了！']) {
        final result = await service.translate(text, 'zh', 'en');
        print('$text → $result');
        expect(scream.hasMatch(result), true, reason: result);
      }
    },
    skip: _skip,
    timeout: _timeout,
  );

  test(
    'a name translated earlier in the session keeps that translation',
    () async {
      final current = _line(200, 'Hinata said the build is ready.');
      final record = TranscriptRecord(
        id: 'smoke',
        createdAt: DateTime(2026),
        language: 'en',
        sources: const ['microphone'],
        targetLanguage: 'zh',
        lines: [
          _line(0, 'Hinata will lead the review.', '日向会主持这次评审。'),
          for (var i = 0; i < 7; i++)
            _line(
              120 + i * 10,
              'We moved item $i to Friday.',
              '我们把第 $i 项移到了周五。',
            ),
          current,
        ],
      );
      // The first line is outside the recent window; it is sent because it
      // names the same person.
      final context = const TranslationContextPolicy().select(record, current);
      expect(context.first.text, 'Hinata will lead the review.');
      final result = await service.translate(
        current.text,
        'en',
        'zh',
        context: context,
      );
      print('Name from context: $result');
      expect(result, contains('日向'));
      expect(result, isNot(contains('周五')));
    },
    skip: _skip,
    timeout: _timeout,
  );

  test(
    'file preparation fixes names and joins only broken sentences',
    () async {
      const texts = [
        'Geoffrey wanted to explain why',
        'Riverside Hall was closed.',
        'Geoffrey will return tomorrow.',
      ];
      final prepared = await service.prepareText(
        texts,
        'en',
        'zh',
        mergeSentences: true,
      );
      print(
        'Preparation: joins=${prepared.joins}, '
        'terms=${prepared.terms.map((term) => term.toJson()).toList()}',
      );
      expect(prepared.joins, contains(1));
      expect(prepared.joins, isNot(contains(2)));
      final name = prepared.terms
          .where((term) => term.source == 'Geoffrey')
          .single
          .translation;
      for (final text in [texts.first, texts.last]) {
        final result = await service.translate(
          text,
          'en',
          'zh',
          terms: prepared.terms,
        );
        print('Fixed name: $result');
        expect(result, contains(name));
      }
    },
    skip: _skip,
    timeout: _timeout,
  );

  test(
    'a long passage is translated in full',
    () async {
      final text = [
        for (var i = 1; i <= 40; i++)
          'Step $i of the release checklist is now complete.',
      ].join(' ');
      expect(text.runes.length, greaterThan(1200));
      final result = await service.translate(text, 'en', 'zh');
      print('Long passage: ${result.runes.length} characters');
      expect(result, contains('40'));
      expect(RegExp(r'[\u3400-\u9fff]').hasMatch(result), true);
    },
    skip: _skip,
    timeout: _timeout,
  );
}
