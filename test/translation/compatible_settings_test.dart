import 'dart:io';

import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/features/settings/translation_settings_dialog.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'online_llm_test.dart' show NamedCredentials;

class UnlistedTranslator extends FakeTranslator {
  UnlistedTranslator(this.credentials);
  final NamedCredentials credentials;
  String? usedKey;
  @override
  Future<List<String>> models(
    String address, {
    LlmProvider provider = LlmProvider.ollama,
  }) async =>
      throw LlmHttpException(401, 'Listing requires separate permission');
  @override
  Future<void> prepare(
    String address,
    String model, {
    LlmProvider provider = LlmProvider.ollama,
  }) async {
    usedKey = await credentials.readNamed(
      LocalLlmService.compatibleCredentialName(address),
    );
    await super.prepare(address, model, provider: provider);
  }
}

void main() {
  testWidgets('manual model saves and checks the current endpoint key', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final credentials = NamedCredentials();
    final translator = UnlistedTranslator(credentials);
    final live =
        RealtimeController(
            audio: FakeAudio(),
            engine: FakeEngine(),
            store: MemoryStore(),
            translator: translator,
            recordSummarizer: FakeTranslator(),
            catalog: FakeModelCatalog(),
            credentials: credentials,
          )
          ..initialized = true
          ..llmProvider = LlmProvider.openAICompatible
          ..translationAddress = 'https://first.example/v1';
    addTearDown(live.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  TranslationSettingsDialog(controller: live, english: true),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('The API key is invalid or expired.'), findsOneWidget);
    final name = LocalLlmService.compatibleCredentialName(
      live.translationAddress,
    );
    final keyInput = find.byKey(Key('api-key-$name'));
    await tester.enterText(keyInput, 'current-test-key');
    await tester.enterText(
      find.byKey(const Key('llm-model-input')),
      'manual-model',
    );
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(find.byType(TranslationSettingsDialog), findsNothing);
    expect(live.translationModel, 'manual-model');
    expect(credentials.values[name], 'current-test-key');

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(keyInput, 'explicit-test-key');
    await tester.ensureVisible(find.text('Save key'));
    await tester.tap(find.text('Save key'));
    await tester.pumpAndSettle();
    expect(credentials.values[name], 'explicit-test-key');
    expect(
      find.text('The key is being saved. Try again shortly.'),
      findsNothing,
    );
    await tester.enterText(keyInput, 'replacement-test-key');
    final check = find.byKey(const Key('llm-check-connection'));
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pumpAndSettle();
    expect(translator.usedKey, 'replacement-test-key');
    expect(translator.calls.single, ('Hello.', 'en', 'zh'));
    expect(
      find.text('The model responded to the test request.'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const Key('llm-address')));
    await tester.enterText(
      find.byKey(const Key('llm-address')),
      'https://second.example/v1',
    );
    await tester.pumpAndSettle();
    expect(find.text('The model responded to the test request.'), findsNothing);
    final second = LocalLlmService.compatibleCredentialName(
      'https://second.example/v1',
    );
    expect(credentials.values[second], isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(Key('api-key-$second')))
          .controller!
          .text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'legacy key migration is endpoint-scoped and preserves an existing key',
    () async {
      final root = Directory('build/test-data');
      await root.create(recursive: true);
      final directory = await root.createTemp('compatible-migration-');
      addTearDown(() => directory.delete(recursive: true));
      final store = RecordStore(directory);
      await store.initialize();
      await store.saveSettings({
        'llmProvider': 'openAICompatible',
        'translationAddress': 'https://saved.example/v1',
      });
      final name = LocalLlmService.compatibleCredentialName(
        'https://saved.example/v1',
      );
      final credentials = NamedCredentials()
        ..values[compatibleKeyName] = 'legacy-key';
      final live = RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: store,
        translator: FakeTranslator(),
        recordSummarizer: FakeTranslator(),
        catalog: FakeModelCatalog(),
        credentials: credentials,
      );
      addTearDown(live.dispose);
      await live.initialize();
      expect(live.error, isNull);
      expect(credentials.values[name], 'legacy-key');
      expect(credentials.values[compatibleKeyName], isEmpty);
      credentials.values[name] = 'new-key';
      credentials.values[compatibleKeyName] = 'obsolete-key';
      await live.initialize();
      expect(live.error, isNull);
      expect(credentials.values[name], 'new-key');
      expect(credentials.values[compatibleKeyName], isEmpty);
      expect(
        await credentials.readNamed(
          LocalLlmService.compatibleCredentialName('https://other.example/v1'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'a newly saved address cannot inherit an unbound legacy key on restart',
    () async {
      final root = Directory('build/test-data');
      await root.create(recursive: true);
      final directory = await root.createTemp('compatible-scoped-');
      addTearDown(() => directory.delete(recursive: true));
      final store = RecordStore(directory);
      final credentials = NamedCredentials()
        ..values[compatibleKeyName] = 'old-unbound-key';
      RealtimeController create() => RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: store,
        translator: FakeTranslator(),
        recordSummarizer: FakeTranslator(),
        catalog: FakeModelCatalog(),
        credentials: credentials,
      );
      final first = create();
      addTearDown(first.dispose);
      await first.initialize();
      first.llmProvider = LlmProvider.openAICompatible;
      first.translationAddress = 'http://127.0.0.1:1234/v1';
      await first.saveSettings();
      final reopened = create();
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.error, isNull);
      expect(
        await credentials.readNamed(
          LocalLlmService.compatibleCredentialName(first.translationAddress),
        ),
        isEmpty,
      );
      expect(await credentials.readNamed(compatibleKeyName), 'old-unbound-key');
    },
  );
}
