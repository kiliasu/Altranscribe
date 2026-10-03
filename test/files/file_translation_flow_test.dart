import 'dart:async';
import 'dart:typed_data';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_terms.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/shared/ui/transcript_tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'file_transcription_test.dart' show FileDecoderFake, until;

class FragmentEngine extends FakeEngine {
  final fragments = ['Geoffrey wanted to.', 'explain the result.'];
  @override
  Future<String> transcribe(Uint8List wave, String language) async =>
      fragments.removeAt(0);
}

class NameCleaner extends FakeTranslator {
  @override
  Future<CleanupResult> cleanUp(
    List<String> texts,
    CleanupOptions options, {
    String language = 'auto',
  }) async => CleanupResult.validate(texts, options, [
    {'category': 'name', 'from': '杰弗里', 'to': '杰佛瑞', 'confidence': 'high'},
  ]);
}

class QueuedTranslator extends FakeTranslator {
  @override
  Future<String> translate(
    String text,
    String source,
    String target, {
    List<TranslationContext> context = const [],
    String rules = defaultTranslationRules,
    List<TranslationTerm> terms = const [],
  }) {
    response = Completer<String>();
    return super.translate(
      text,
      source,
      target,
      context: context,
      rules: rules,
      terms: terms,
    );
  }
}

void main() {
  test('file preparation merges before naming, persists originals and protects fixed translations', () async {
    const fixed = TranslationTerm(
      source: 'Geoffrey',
      translation: '杰弗里',
      type: 'person',
    );
    final translator = NameCleaner()
      ..preparation = const TextPreparation(terms: [fixed], joins: [1])
      ..response = Completer<String>();
    final store = MemoryStore();
    final controller =
        RealtimeController(
            audio: FakeAudio(),
            engine: FragmentEngine(),
            store: store,
            translator: translator,
            fileDecoder: FileDecoderFake(),
          )
          ..initialized = true
          ..generateSummary = false
          ..translationRules = 'No emoji.';
    addTearDown(controller.dispose);
    final run = controller.startFiles(
      paths: ['talk.wav'],
      language: 'en',
      targetLanguage: 'zh',
      summaryLanguage: 'zh',
      options: const CleanupOptions(
        mergeSentences: true,
        names: true,
        spellings: ['杰佛瑞'],
      ),
    );
    await until(() => translator.calls.isNotEmpty);
    controller.translationRules = 'Changed for the next task.';
    translator.response!.complete('杰弗里想解释结果。');
    await run;
    final record = (await store.loadRecords()).single;
    expect(translator.preparationCalls.first, hasLength(2));
    expect(translator.preparationCalls.last, [
      'Geoffrey wanted to explain the result.',
    ]);
    expect(record.lines, hasLength(1));
    expect(record.lines.single.originalSegments, hasLength(2));
    expect(record.lines.single.endMs, 4000);
    expect(record.translationTerms.single.translation, '杰弗里');
    expect(record.lines.single.displayTranslation, '杰弗里想解释结果。');
    expect(record.lines.single.translationEdits, isEmpty);
    expect(translator.rules.single, 'No emoji.');
    expect(record.translationRules, 'No emoji.');
  });

  testWidgets(
    'file screen reserves all queued translations and keeps the tail still as each arrives',
    (tester) async {
      final translator = QueuedTranslator();
      final engine = FakeEngine()
        ..response = (Completer<String>()
          ..complete(
            List.generate(
              12,
              (i) => 'This is original sentence number $i.',
            ).join(' '),
          ));
      final controller =
          RealtimeController(
              audio: FakeAudio(),
              engine: engine,
              store: MemoryStore(),
              translator: translator,
              fileDecoder: FileDecoderFake(),
            )
            ..initialized = true
            ..generateSummary = false;
      addTearDown(controller.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      final task = controller.startFiles(
        paths: ['talk.wav'],
        language: 'en',
        targetLanguage: 'zh',
        summaryLanguage: 'zh',
        options: const CleanupOptions(),
      );
      for (var i = 0; i < 10 && translator.calls.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.record!.lines, hasLength(24));
      expect(
        find.byKey(const Key('translation-placeholder')),
        findsNWidgets(24),
      );
      final before = tester.getTopLeft(find.byType(TranscriptTile).last).dy;
      for (var i = 0; i < 3; i++) {
        translator.response!.complete(i.isEven ? '短译文。' : '一段较长的译文。' * 30);
        for (var frame = 0; frame < 16; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.getTopLeft(find.byType(TranscriptTile).last).dy,
            closeTo(before, .1),
          );
        }
      }
      final stopping = controller.stop();
      translator.response!.complete('Cancelled');
      await stopping;
      await task;
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
