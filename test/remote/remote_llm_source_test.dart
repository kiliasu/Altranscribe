import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
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
      expect(live.useRemoteLlm, isTrue);
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
      expect(live.useRemoteLlm, isFalse);
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
      expect(live.useRemoteLlm, isTrue);
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
      live.remoteConnection.info = null;
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
}
