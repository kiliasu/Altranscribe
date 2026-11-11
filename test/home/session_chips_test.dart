import 'dart:async';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../files/file_progress_test.dart' show SlowTranslator;
import '../files/file_transcription_test.dart' show FileDecoderFake;
import '../support/fakes.dart';

void main() {
  testWidgets(
    'a file session names the text model it uses and counts its translated lines',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final translator = SlowTranslator();
      final engine = FakeEngine()
        ..response = (Completer<String>()..complete('One sentence here.'));
      final live =
          RealtimeController(
              audio: FakeAudio(),
              engine: engine,
              store: MemoryStore(),
              translator: translator,
              fileDecoder: FileDecoderFake(),
            )
            ..initialized = true
            ..generateSummary = false
            ..llmProvider = LlmProvider.openAI
            ..translationModel = 'gpt-test';
      addTearDown(live.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      final task = live.startFiles(
        paths: ['talk.wav'],
        language: 'en',
        targetLanguage: 'zh',
        summaryLanguage: 'zh',
        options: const CleanupOptions(),
      );
      for (var i = 0; i < 20 && translator.started.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 300));
      // The file panel names the chosen provider and model, not the
      // service's default, and counts the translated lines.
      expect(
        find.textContaining('翻译为简体中文 · OpenAI · gpt-test'),
        findsOneWidget,
      );
      expect(find.textContaining('Ollama'), findsNothing);
      expect(find.textContaining('已翻译 0 / 2 句'), findsOneWidget);
      expect(live.fileTranslationSlots, 8);
      translator.waiting.first.complete('一句话。');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('已翻译 1 / 2 句'), findsOneWidget);
      // The bar glides to its new length.
      await tester.pump(const Duration(milliseconds: 500));
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('file-progress')),
      );
      expect(progress.value, .5);
      translator.answerAll();
      await task;
      await tester.pump(const Duration(milliseconds: 300));
      expect(live.record?.status, 'completed');
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
