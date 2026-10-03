import 'dart:async';
import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/features/settings/model_settings_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// Reports the Nemotron models in [present] as downloaded (by default only
/// the English one), without touching the disk.
class NemotronCatalog extends ModelCatalog {
  NemotronCatalog([Set<String>? present])
    : present = present ?? {'nemotron-en-0.6b'},
      super(Directory('build/test-models'));
  final Set<String> present;
  @override
  Future<Map<String, ModelAvailability>> scan() async => availability = {
    for (final model in ModelCatalog.models)
      model.id: ModelAvailability.missing,
    for (final model in ModelCatalog.nemotronModels)
      model.id: present.contains(model.id)
          ? ModelAvailability.available
          : ModelAvailability.missing,
  };
  @override
  Future<void> remove(SpeechModel model) async {
    present.remove(model.id);
    await scan();
    notifyListeners();
  }
}

/// Holds every removal until [release] completes.
class SlowRemovalCatalog extends NemotronCatalog {
  SlowRemovalCatalog() : super({'nemotron-en-0.6b', 'nemotron-3.5-0.6b'});
  final release = Completer<void>();
  @override
  Future<void> remove(SpeechModel model) async {
    await release.future;
    await super.remove(model);
  }
}

void main() {
  test('no session starts while a model is being removed', () async {
    final catalog = SlowRemovalCatalog();
    final live = fakeController(catalog: catalog)
      ..speechProvider = SpeechProvider.nemotron
      ..nemotronModel = 'nemotron-en-0.6b';
    addTearDown(live.dispose);
    final removal = live.removeModel(ModelCatalog.nemotronModels.first);
    expect(live.removingModel, isTrue);
    await live.start(microphone: true, system: false, language: 'en');
    await live.startFiles(
      paths: const ['talk.wav'],
      language: 'en',
      summaryLanguage: 'en',
      options: const CleanupOptions(),
    );
    expect(live.phase, SessionPhase.idle);
    // A second removal waits its turn too.
    await expectLater(
      live.removeModel(ModelCatalog.nemotronModels.last),
      throwsStateError,
    );
    catalog.release.complete();
    await removal;
    expect(live.removingModel, isFalse);
    expect(live.nemotronModel, 'nemotron-3.5-0.6b');
  });

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
      expect(find.textContaining('在本地 CPU 上实时识别'), findsOneWidget);
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

  testWidgets(
    'removing a model asks first, hands over to the other one and shows when none is left',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final catalog = NemotronCatalog({
        'nemotron-en-0.6b',
        'nemotron-3.5-0.6b',
      });
      final live = fakeController(catalog: catalog)
        ..speechProvider = SpeechProvider.nemotron
        ..nemotronModel = 'nemotron-en-0.6b';
      addTearDown(live.dispose);
      await catalog.scan();
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      expect(find.textContaining('未下载'), findsNothing);
      await tester.tap(find.byKey(const Key('nav-3')));
      await tester.pumpAndSettle();
      final entry = find.byKey(const ValueKey('settings-modelsEntry'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();

      // Backing out of the question keeps the files.
      await tester.tap(find.byKey(const Key('remove-nemotron-en-0.6b')));
      await tester.pumpAndSettle();
      expect(find.textContaining('需要时可以重新下载'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(catalog.present, contains('nemotron-en-0.6b'));

      await tester.tap(find.byKey(const Key('remove-nemotron-en-0.6b')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-remove-model')));
      await tester.pumpAndSettle();
      expect(catalog.present, {'nemotron-3.5-0.6b'});
      // The model in use was removed, so the other downloaded one takes over.
      expect(live.nemotronModel, 'nemotron-3.5-0.6b');
      expect(
        find.byKey(const Key('download-nemotron-en-0.6b')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('remove-nemotron-en-0.6b')), findsNothing);
      expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
            .groupValue,
        'nemotron-3.5-0.6b',
      );

      await tester.tap(find.byKey(const Key('remove-nemotron-3.5-0.6b')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-remove-model')));
      await tester.pumpAndSettle();
      expect(catalog.present, isEmpty);
      expect(live.nemotronModel, 'nemotron-3.5-0.6b');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // Without any model the start page says so.
      await tester.tap(find.byKey(const Key('nav-0')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Multilingual · CPU · 未下载'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
