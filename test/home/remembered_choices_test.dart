import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';

/// Keeps settings in memory, and gives them back at once as a file would.
class RememberingStore extends MemoryStore {
  RememberingStore([Map<String, Object?> saved = const {}])
    : saved = {...saved};
  Map<String, Object?> saved;
  int writes = 0;
  @override
  Map<String, dynamic> loadSettingsSync() =>
      jsonDecode(jsonEncode(saved)) as Map<String, dynamic>;
  @override
  Future<void> saveSettings(Map<String, Object?> value) async {
    writes++;
    saved = jsonDecode(jsonEncode(value)) as Map<String, Object?>;
  }
}

RealtimeController controller(RecordStore store) => RealtimeController(
  audio: FakeAudio(),
  engine: FakeEngine(),
  store: store,
  translator: FakeTranslator(),
  recordSummarizer: FakeTranslator(),
  catalog: FakeModelCatalog(),
)..initialized = true;

void main() {
  // English labels are measured with the real fonts, as on screen.
  setUpAll(() async {
    for (final family in ['Roboto', 'NotoSansSC']) {
      final loader = FontLoader(family);
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
      }
      await loader.load();
    }
    for (final family in ['RobotoFlex', 'MaterialSymbolsRounded']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
  });

  setUp(() {
    TestWidgetsFlutterBinding
        .instance
        .platformDispatcher
        .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
  });
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearAccessibilityFeaturesTestValue();
  });

  testWidgets('the app opens the way it was left and keeps each new choice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = RememberingStore({
      'interface': {
        'english': true,
        'theme': 'dark',
        'palette': 'baseline',
        'microphone': false,
        'systemAudio': true,
        'translate': false,
        'source': 'ja',
        'target': 'en',
        'textSize': 28,
      },
    });
    final live = controller(store);
    addTearDown(live.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
    // The first frame already speaks English in the dark baseline theme.
    expect(find.text('Transcribe'), findsWidgets);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );
    expect(
      tester.widget<Switch>(find.byKey(const Key('translate'))).value,
      isFalse,
    );
    expect(find.text('日本語'), findsOneWidget);
    expect(store.writes, 0);

    // Turning translation on and adding the microphone are written at once.
    await tester.tap(find.byKey(const Key('translate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('microphone')));
    await tester.pumpAndSettle();
    final saved = store.saved['interface']! as Map;
    expect(saved['translate'], isTrue);
    expect(saved['microphone'], isTrue);
    expect(saved['systemAudio'], isTrue);
    expect(saved['source'], 'ja');
    expect(saved['english'], isTrue);
    final writes = store.writes;
    expect(writes, greaterThan(0));

    // A rebuild that changes nothing writes nothing.
    live.notifyListeners();
    await tester.pumpAndSettle();
    expect(store.writes, writes);

    // The language and the look are kept as well.
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('interface-zh')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect((store.saved['interface']! as Map)['english'], isFalse);
    expect((store.saved['interface']! as Map)['theme'], 'light');

    // The next launch reads them back before its first frame.
    await tester.pumpWidget(const SizedBox());
    final next = controller(RememberingStore(store.saved));
    addTearDown(next.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: next));
    await tester.pump();
    expect(find.text('转录'), findsWidgets);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.light,
    );
    expect(
      tester.widget<Switch>(find.byKey(const Key('translate'))).value,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('a first run follows the system language only when asked to', (
    tester,
  ) async {
    tester.platformDispatcher.localeTestValue = const Locale('en', 'US');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    final live = controller(RememberingStore());
    addTearDown(live.dispose);
    await tester.pumpWidget(
      AltranscribeApp(realtime: live, followSystemLanguage: true),
    );
    await tester.pump();
    expect(find.text('Transcribe'), findsWidgets);
    await tester.pumpWidget(const SizedBox());

    tester.platformDispatcher.localeTestValue = const Locale('zh', 'CN');
    final chinese = controller(RememberingStore());
    addTearDown(chinese.dispose);
    await tester.pumpWidget(
      AltranscribeApp(realtime: chinese, followSystemLanguage: true),
    );
    await tester.pump();
    expect(find.text('转录'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  test('saved choices are read at once from the settings file', () async {
    final directory = Directory.systemTemp.createTempSync('altranscribe-ui');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = RecordStore(directory);
    expect(store.loadSettingsSync(), isEmpty);
    await store.saveSettings({
      'interface': {'english': true},
      'model': 'kept',
    });
    expect(store.loadSettingsSync()['interface'], {'english': true});
    // A damaged file counts as nothing saved rather than failing the launch.
    File('${directory.path}/settings.json').writeAsStringSync('{broken');
    expect(store.loadSettingsSync(), isEmpty);

    // The controller writes its interface choices with the other settings.
    await store.saveSettings({
      'interface': {'theme': 'dark'},
    });
    final live = controller(store);
    addTearDown(live.dispose);
    expect(live.interface, {'theme': 'dark'});
    live.remember('theme', 'light');
    live.remember('fileOptions', [true, false, false, false]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final saved = await store.loadSettings();
    expect(saved['interface'], {
      'theme': 'light',
      'fileOptions': [true, false, false, false],
    });
    expect(saved.containsKey('speechProvider'), isTrue);
  });
}
