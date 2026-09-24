import 'package:altranscribe/data/models/transcript_record.dart';
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/features/settings/caption_settings_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Android real UI settings and record operations', (tester) async {
    await MobilePlatform.initialize();
    final audio = PlatformAudioService();
    final live = RealtimeController(
      audio: audio,
      engine: WhisperService(audio),
      store: RecordStore(
        Directory(
          '${Directory(MobilePlatform.dataDirectory!).parent.path}/ui-smoke',
        ),
      ),
    );
    addTearDown(live.dispose);
    await live.store.initialize();
    await live.store.saveSettings({});
    await live.initialize();
    // An explicitly labelled display fixture; real inference is tested separately.
    final record = TranscriptRecord(
      id: 'session-90914001',
      createdAt: DateTime(2026, 9, 14, 10, 20),
      language: 'en',
      targetLanguage: 'zh',
      sources: ['file'],
      title: '界面测试样例',
      status: 'completed',
      lines: [
        TranscriptLine(
          source: 'file',
          startMs: 0,
          endMs: 3000,
          text: 'A display fixture.',
          translation: '界面测试文本。',
          translationStatus: 'done',
        ),
      ],
    );
    await live.store.save(record);
    live.records = await live.store.loadRecords();
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
    Future<void> tap(Finder finder) async {
      print('ANDROID_UI_TAP $finder');
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Finder key(String value) => find.byKey(Key(value));
    for (final index in [1, 2, 3, 0, 3]) {
      await tap(key('nav-$index'));
    }
    expect(
      find.byType(MaterialApp).evaluate().single.widget is MaterialApp,
      true,
    );
    await tap(key('interface-en'));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).locale!.languageCode,
      'en',
    );
    await tap(key('palette-baseline'));
    await tap(find.text('Light'));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
    await tap(find.text('Dark'));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    await tap(find.text('System'));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
    await tap(key('palette-amber'));
    await tap(key('interface-zh'));
    for (final item in [
      'audioSettings',
      'modelsEntry',
      'translationSettings',
      'contextSettings',
    ]) {
      await tap(key('settings-$item'));
      expect(find.byType(AlertDialog), findsOneWidget);
      if (item == 'audioSettings') {
        expect(key('microphone-denoise'), findsOneWidget);
        expect(key('system-denoise'), findsOneWidget);
      } else if (item == 'modelsEntry') {
        expect(key('speech-provider-remote'), findsOneWidget);
        expect(key('speech-provider-openAI'), findsOneWidget);
        expect(key('whisper-large-v3'), findsNothing);
      } else if (item == 'translationSettings') {
        expect(key('provider-ollama'), findsNothing);
        expect(key('provider-openAI'), findsOneWidget);
      } else {
        await tap(key('context-auto'));
        expect(key('context-count'), findsOneWidget);
      }
      await tap(find.text('取消'));
    }
    await tap(key('caption-settings'));
    expect(find.byType(CaptionSettingsDialog), findsOneWidget);
    await tap(key('caption-original'));
    await tap(find.text('保存'));
    expect(live.captionPreferences.original, false);
    expect(
      (await live.store.loadSettings())['captions'],
      containsPair('original', false),
    );
    await tap(key('nav-1'));
    await tap(key('rename-${record.id}'));
    await tester.enterText(key('record-title-input'), '安卓重命名验证');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tap(find.text('保存'));
    expect((await live.store.loadRecords()).single.title, '安卓重命名验证');
    await tester.enterText(key('record-search'), '不存在的记录');
    await tester.pumpAndSettle();
    expect(find.text('安卓重命名验证'), findsNothing);
    await tester.enterText(key('record-search'), '安卓重命名验证');
    await tester.pumpAndSettle();
    expect(find.text('安卓重命名验证'), findsNWidgets(2));
    await tap(find.text('安卓重命名验证').last);
    expect(find.text('A display fixture.'), findsOneWidget);
    expect(find.text('界面测试文本。'), findsOneWidget);
    await tester.longPress(find.text('A display fixture.'));
    await tester.pumpAndSettle();
    final labels = MaterialLocalizations.of(
      tester.element(find.byType(AlertDialog)),
    );
    await tap(find.text(labels.copyButtonLabel));
    expect((await Clipboard.getData('text/plain'))!.text, isNotEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tap(key('nav-1'));
    await tap(key('delete-${record.id}'));
    await tap(key('confirm-delete'));
    expect(
      await File('${live.store.directory.path}/${record.id}.json').exists(),
      false,
    );
    expect(await live.store.loadRecords(), isEmpty);
    await tester.pumpWidget(const SizedBox());
    print('ANDROID_UI_ALL_PASSED');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
