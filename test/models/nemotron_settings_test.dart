import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/features/settings/model_settings_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// Reports the English Nemotron model as downloaded and the multilingual one
/// as missing, without touching the disk.
class NemotronCatalog extends ModelCatalog {
  NemotronCatalog() : super(Directory('build/test-models'));
  @override
  Future<Map<String, ModelAvailability>> scan() async => {
    for (final model in ModelCatalog.models)
      model.id: ModelAvailability.missing,
    'nemotron-en-0.6b': ModelAvailability.available,
    'nemotron-3.5-0.6b': ModelAvailability.missing,
  };
}

void main() {
  testWidgets(
    'the model panel offers Nemotron with its two models and saves the choice',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final live = fakeController(catalog: NemotronCatalog());
      addTearDown(live.dispose);
      expect(live.speechProvider, SpeechProvider.whisper);
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-3')));
      await tester.pumpAndSettle();
      final entry = find.byKey(const ValueKey('settings-modelsEntry'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(ModelSettingsDialog), findsOneWidget);

      await tester.tap(find.byKey(const Key('speech-provider-nemotron')));
      await tester.pumpAndSettle();
      expect(find.textContaining('在本机 CPU 上流式识别'), findsOneWidget);
      expect(
        find.byKey(const Key('nemotron-nemotron-en-0.6b')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('nemotron-nemotron-3.5-0.6b')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('download-nemotron-3.5-0.6b')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('download-nemotron-en-0.6b')), findsNothing);
      expect(find.textContaining('NVIDIA Open Model License'), findsOneWidget);
      expect(find.textContaining('OpenMDW'), findsOneWidget);
      // Whisper's compute toggle and program field do not apply here.
      expect(find.text('GPU'), findsNothing);
      expect(find.text('whisper-server.exe'), findsNothing);

      // The English model is the default and already downloaded, so saving
      // switches the engine.
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelSettingsDialog), findsNothing);
      expect(live.speechProvider, SpeechProvider.nemotron);
      expect(live.nemotronModel, 'nemotron-en-0.6b');
      expect(live.cloudSpeech, isFalse);
      expect(live.nemotronSpeech, isTrue);
      expect(
        live.engineModel.replaceAll('\\', '/'),
        endsWith('/nemotron-en-0.6b'),
      );
      expect(live.engine, same(live.nemotronEngine));
      expect(live.sessionModel, 'Nemotron Streaming · English (0.6B)');
      expect(find.textContaining('Nemotron · English · CPU'), findsOneWidget);

      // A model that is not on disk cannot be chosen.
      await tester.tap(entry);
      await tester.pumpAndSettle();
      final multilingual = tester.widget<RadioListTile<String>>(
        find.byKey(const Key('nemotron-nemotron-3.5-0.6b')),
      );
      expect(multilingual.enabled, isFalse);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  test('the speech provider tells local engines from cloud ones', () {
    expect(SpeechProvider.nemotron.isCloud, isFalse);
    expect(SpeechProvider.whisper.isCloud, isFalse);
    expect(SpeechProvider.openAI.isCloud, isTrue);
    expect(SpeechProvider.gemini.isCloud, isTrue);
    expect(SpeechProvider.nemotron.label, 'Nemotron · Local');
    expect(SpeechProvider.values.map((p) => p.name), contains('nemotron'));
  });
}
