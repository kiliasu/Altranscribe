import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/features/settings/translation_settings_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  Future<void> openTranslation(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('nav-3')));
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('settings-translationSettings'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(TranslationSettingsDialog), findsOneWidget);
  }

  testWidgets(
    'with a host connected the LLM dialog explains the shared model and lets the user switch to their own service',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final live = fakeController()..useRemote = true;
      live.remoteConnection
        ..address = 'http://192.168.1.20:8178'
        ..name = 'Study PC'
        ..info = {
          'llmProvider': 'ollama',
          'llmModel': 'gemma-test',
          'llmModels': ['gemma-test', 'other-model'],
        };
      addTearDown(live.dispose);
      expect(live.remoteLlm, isTrue);
      expect(live.translator, same(live.remoteTranslator));
      expect(live.sessionLlmModel, 'gemma-test');
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      expect(find.text('Remote · gemma-test'), findsOneWidget);

      await openTranslation(tester);
      expect(find.text('Study PC · ollama'), findsOneWidget);
      expect(find.byKey(const Key('llm-source-host')), findsOneWidget);
      // Every model the host lists can be chosen; its own is marked as default.
      expect(
        find.byKey(const ValueKey('host-model-gemma-test')),
        findsOneWidget,
      );
      expect(find.text('主机默认'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('host-model-other-model')));
      await tester.pumpAndSettle();
      // The host's model is in use, so no provider or key controls and no
      // cloud lookup that would complain about a missing API key.
      expect(find.byKey(const Key('provider-openAI')), findsNothing);
      expect(find.byKey(const Key('llm-address')), findsNothing);
      expect(find.textContaining('API Key'), findsNothing);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(TranslationSettingsDialog), findsNothing);
      expect(live.hostLlm, isTrue);
      expect(live.remoteLlmModel, 'other-model');
      expect(live.sessionLlmModel, 'other-model');
      expect(find.text('Remote · other-model'), findsOneWidget);

      await openTranslation(tester);
      await tester.tap(find.byKey(const Key('llm-source-own')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('provider-openAICompatible')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('provider-openAICompatible')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('llm-model-test-model')));
      await tester.tap(find.byKey(const Key('llm-model-test-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(live.hostLlm, isFalse);
      expect(live.remoteLlm, isFalse);
      expect(live.remoteProcessing, isTrue, reason: 'speech stays on the host');
      expect(live.translator, same(live.localTranslator));
      expect(live.llmProvider, LlmProvider.openAICompatible);
      expect(live.translationModel, 'test-model');
      expect(live.sessionLlmProvider, 'openAICompatible');
      expect(find.text('OpenAI compatible · test-model'), findsOneWidget);

      // Switching back to the host needs no model of its own.
      await openTranslation(tester);
      expect(
        find.byKey(const Key('provider-openAICompatible')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('llm-source-host')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('provider-openAICompatible')), findsNothing);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(live.hostLlm, isTrue);
      expect(live.remoteLlmModel, 'other-model', reason: 'the choice is kept');
      expect(live.translator, same(live.remoteTranslator));

      // Picking the host's own model again means following its default.
      await openTranslation(tester);
      await tester.tap(find.byKey(const ValueKey('host-model-gemma-test')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(live.remoteLlmModel, isEmpty);
      expect(find.text('Remote · gemma-test'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a host without a shared text model says so, and no host means the plain dialog',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final live = fakeController()..useRemote = true;
      live.remoteConnection
        ..address = 'http://192.168.1.20:8178'
        ..name = 'Study PC'
        ..info = {'llmProvider': null, 'llmModel': null};
      addTearDown(live.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      await openTranslation(tester);
      expect(find.textContaining('主机没有共享文字模型'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      live.useRemote = false;
      live.remoteConnection
        ..address = ''
        ..info = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      await openTranslation(tester);
      expect(find.byKey(const Key('llm-source-host')), findsNothing);
      expect(
        find.byKey(const Key('provider-openAICompatible')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('a local engine can use the host\'s text model', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final live = fakeController()
      ..speechProvider = SpeechProvider.nemotron
      ..hostLlm = false;
    live.remoteConnection
      ..address = 'http://192.168.1.20:8178'
      ..name = 'Study PC'
      ..info = {
        'llmProvider': 'ollama',
        'llmModel': 'gemma-test',
        'llmModels': ['gemma-test'],
      };
    addTearDown(live.dispose);
    expect(live.remoteProcessing, isFalse);
    expect(live.remoteLlm, isFalse);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();

    await openTranslation(tester);
    expect(find.byKey(const Key('llm-source-own')), findsOneWidget);
    await tester.tap(find.byKey(const Key('llm-source-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(live.hostLlm, isTrue);
    expect(live.remoteLlm, isTrue);
    expect(live.remoteProcessing, isFalse, reason: 'speech stays here');
    expect(live.engine, same(live.nemotronEngine));
    expect(live.translator, same(live.remoteTranslator));
    expect(live.recordSummarizer, same(live.remoteSummarizer));
    expect(live.sessionLlmProvider, 'remote');
    expect(find.text('Remote · gemma-test'), findsOneWidget);

    // Forgetting the host returns the text work to the own service.
    live.remoteConnection.address = '';
    expect(live.remoteLlm, isFalse);
    expect(live.translator, same(live.localTranslator));
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  test('older settings keep what the text model did before', () async {
    final root = Directory('build/test-data');
    await root.create(recursive: true);
    Future<bool> hostLlmAfter(Map<String, Object?> settings) async {
      final directory = await root.createTemp('llm-source-');
      addTearDown(() => directory.delete(recursive: true));
      final store = RecordStore(directory);
      await store.initialize();
      await store.saveSettings(settings);
      final live = RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: store,
        translator: FakeTranslator(),
        catalog: FakeModelCatalog(),
      );
      addTearDown(live.dispose);
      await live.initialize();
      return live.hostLlm;
    }

    // A host that recognized speech lent its text model, and still does.
    expect(
      await hostLlmAfter({'speechProvider': 'whisper', 'useRemote': true}),
      isTrue,
    );
    expect(
      await hostLlmAfter({
        'speechProvider': 'whisper',
        'useRemote': true,
        'remoteLlm': false,
      }),
      isFalse,
    );
    // Other engines used this device's own service, and still do.
    expect(
      await hostLlmAfter({
        'speechProvider': 'nemotron',
        'useRemote': true,
        'remoteLlm': true,
      }),
      isFalse,
    );
    expect(await hostLlmAfter({'speechProvider': 'openAI'}), isFalse);
    // Once chosen, the source stays whatever the engine.
    expect(
      await hostLlmAfter({'speechProvider': 'nemotron', 'hostLlm': true}),
      isTrue,
    );
  });
}
