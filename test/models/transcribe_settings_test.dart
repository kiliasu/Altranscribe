import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/features/settings/model_settings_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// Reports the Transcribe model as downloaded, without touching the disk.
class TranscribeCatalog extends ModelCatalog {
  TranscribeCatalog({this.whisper = false})
    : super(Directory('build/test-models'));

  /// Whisper Large v3 Turbo is downloaded too.
  final bool whisper;
  @override
  Future<Map<String, ModelAvailability>> scan() async => availability = {
    for (final model in ModelCatalog.models)
      model.id: whisper && model.id == 'large-v3-turbo'
          ? ModelAvailability.available
          : ModelAvailability.missing,
    for (final model in ModelCatalog.transcribeModels)
      model.id: ModelAvailability.available,
  };
}

void main() {
  testWidgets(
    'the model panel offers Transcribe and needs its program to save',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final folder = Directory.systemTemp.createTempSync('nemo-speech');
      addTearDown(() => folder.deleteSync(recursive: true));
      final program = File('${folder.path}/nemo-speech.exe')
        ..writeAsStringSync('');
      final live = fakeController(catalog: TranscribeCatalog());
      addTearDown(live.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-3')));
      await tester.pumpAndSettle();
      final entry = find.byKey(const ValueKey('settings-modelsEntry'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speech-provider-transcribe')));
      await tester.pumpAndSettle();
      expect(find.textContaining('整段识别录音'), findsOneWidget);
      expect(
        find.byKey(const Key('transcribe-nemotron-transcribe-nvfp4')),
        findsOneWidget,
      );
      expect(find.textContaining('21.35 GB'), findsOneWidget);
      expect(find.textContaining('OpenMDW'), findsOneWidget);
      // Whisper's compute toggle does not apply. The program is the
      // published build, to download, or one's own; nothing is chosen yet,
      // so no path is asked for.
      expect(find.text('GPU'), findsNothing);
      expect(find.text('Transcribe 程序'), findsOneWidget);
      expect(
        find.byKey(const Key('program-nemo-speech-0.3.0-cuda')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('download-nemo-speech-0.3.0-cuda')),
        findsOneWidget,
      );
      expect(find.textContaining('509 MB · 未下载'), findsOneWidget);
      expect(find.text('NeMo-Speech.cpp 0.3.0 · Apache 2.0'), findsOneWidget);
      expect(find.text('nemo-speech.exe'), findsNothing);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelSettingsDialog), findsOneWidget);
      expect(find.textContaining('找不到 nemo-speech.exe'), findsOneWidget);
      expect(live.speechProvider, SpeechProvider.whisper);

      // A program of one's own is given by its path.
      await tester.ensureVisible(find.byKey(const Key('program-custom')));
      await tester.tap(find.byKey(const Key('program-custom')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'nemo-speech.exe'),
        program.path,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelSettingsDialog), findsNothing);
      expect(live.speechProvider, SpeechProvider.transcribe);
      expect(live.transcribeExecutable, program.path);
      expect(live.engineExecutable, program.path);
      expect(live.engine, same(live.transcribeEngine));
      expect(
        live.engineModel.replaceAll('\\', '/'),
        endsWith(
          '/nemotron-transcribe-nvfp4/'
          'NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-AD-NVFP4.gguf',
        ),
      );
      expect(live.sessionModel, 'Nemotron 3.5 Transcribe · NVFP4 (30B-A4B)');
      expect(find.textContaining('Transcribe · NVFP4 · GPU'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the start panel and engines follow every change of the text model',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final folder = Directory.systemTemp.createTempSync('nemo-speech');
      addTearDown(() => folder.deleteSync(recursive: true));
      final program = File('${folder.path}/nemo-speech.exe')
        ..writeAsStringSync('');
      final live = fakeController(catalog: TranscribeCatalog(whisper: true))
        ..translationModel = 'test-model'
        ..transcribeExecutable = program.path
        ..speechProvider = SpeechProvider.transcribe
        ..gpuTotalMemory = (() async => null);
      addTearDown(live.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      String status() => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('llm-status')),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data)
          .join(' ');
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> save() => tap(find.text('保存'));
      final prepare = find.byKey(const Key('llm-prepare'));

      // A local model would share the GPU: live sessions translate after
      // stopping, and the button leads to the one global LLM setting.
      expect(status(), contains('停止转录后翻译'));
      expect(find.text('Ollama · test-model'), findsOneWidget);
      await tap(find.byKey(const Key('set-live-cloud')));
      expect(find.text('翻译选择'), findsOneWidget);
      await tap(find.byKey(const Key('provider-openAI')));
      await tap(find.byKey(const ValueKey('llm-model-test-model')));
      await save();
      expect(live.llmProvider, LlmProvider.openAI);
      // The cloud model is the one in use everywhere and needs no loading.
      expect(status(), contains('云端模型'));
      expect(prepare, findsNothing);
      expect(find.text('OpenAI · test-model'), findsOneWidget);
      await tap(find.text('文件'));
      expect(status(), contains('云端模型'));
      expect(prepare, findsNothing);
      expect(find.text('OpenAI · test-model'), findsOneWidget);

      // Back to the local model, opened from the engines.
      await tap(find.text('LLM'));
      await tap(find.byKey(const Key('provider-ollama')));
      await tap(find.byKey(const ValueKey('llm-model-test-model')));
      await save();
      expect(live.llmProvider, LlmProvider.ollama);
      expect(status(), contains('转录完成后加载 LLM'));
      expect(prepare, findsNothing);
      expect(find.text('Ollama · test-model'), findsOneWidget);
      await tap(find.text('实时'));
      expect(status(), contains('停止转录后翻译'));

      // Transcribe's own settings may run the local model beside it.
      await tap(find.text('转录模型'));
      await tap(find.byKey(const Key('live-llm-local')));
      await save();
      expect(live.liveLocalLlm, isTrue);
      expect(status(), contains('显存可能不足'));
      expect(prepare, findsNothing);

      // Whisper leaves the GPU to the text model: it can be loaded first.
      await tap(find.text('转录模型'));
      await tap(find.byKey(const Key('speech-provider-whisper')));
      await tap(find.byKey(const Key('whisper-large-v3-turbo')));
      await save();
      expect(live.speechProvider, SpeechProvider.whisper);
      expect(status(), contains('LLM 尚未准备'));
      await tap(prepare);
      expect(status(), contains('LLM 已就绪'));

      // Back to Transcribe, which still keeps the model beside it.
      await tap(find.text('转录模型'));
      await tap(find.byKey(const Key('speech-provider-transcribe')));
      await save();
      expect(live.speechProvider, SpeechProvider.transcribe);
      expect(status(), contains('显存可能不足'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
