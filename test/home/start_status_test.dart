import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/features/settings/model_settings_dialog.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/notice.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';

void main() {
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

  IconData statusIcon(WidgetTester tester) => tester
      .widget<Icon>(
        find
            .descendant(
              of: find.byKey(const Key('speech-status')),
              matching: find.byType(Icon),
            )
            .first,
      )
      .icon!;

  testWidgets('the line under Start says what stands in the way, and how to '
      'settle it', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final live = fakeController();
    addTearDown(live.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();

    // A first run has no speech model: a problem, with the way to one.
    expect(find.text('尚未选择转录模型'), findsOneWidget);
    expect(statusIcon(tester), AltIcons.error);
    await tester.tap(find.byKey(const Key('choose-model')));
    await tester.pumpAndSettle();
    expect(find.byType(ModelSettingsDialog), findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    // With a model, the line is a plain confirmation of what will run.
    live
      ..model = r'C:\models\ggml-large-v3-turbo.bin'
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('choose-model')), findsNothing);
    expect(statusIcon(tester), AltIcons.checkCircle);

    // No source: a problem again.
    await tester.tap(find.byKey(const Key('microphone')));
    await tester.pumpAndSettle();
    expect(statusIcon(tester), AltIcons.error);
    expect(find.text('至少开启一个音频来源。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('microphone')));
    await tester.pumpAndSettle();

    // Files: nothing queued is a remark, not a tick; then the count.
    await tester.tap(find.text('文件').first);
    await tester.pumpAndSettle();
    expect(find.text('先添加文件'), findsOneWidget);
    expect(statusIcon(tester), AltIcons.info);
    MobilePlatform.importedFiles.value = ['talk.wav', 'notes.mp3'];
    await tester.pumpAndSettle();
    expect(find.text('2 个文件待处理 · 按队列逐个处理'), findsOneWidget);
    expect(statusIcon(tester), AltIcons.checkCircle);
    await tester.tap(find.text('实时').first);
    await tester.pumpAndSettle();

    // A failure and a warning show as notices in the panel that holds
    // Start, where the eye is, and go when they are settled.
    final panel = find
        .ancestor(
          of: find.byKey(const Key('start')),
          matching: find.byType(Material),
        )
        .first;
    live
      ..error = 'The speech model could not be loaded.'
      ..warning = 'System audio is unavailable.'
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: panel, matching: find.byType(AltNotice)),
      findsNWidgets(2),
    );
    expect(
      tester.widget<AltNotice>(find.byKey(const Key('home-error'))).tone,
      NoticeTone.error,
    );
    expect(
      tester.widget<AltNotice>(find.byKey(const Key('home-warning'))).tone,
      NoticeTone.warning,
    );
    live
      ..error = null
      ..warning = null
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(AltNotice), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('translation and summary are chips of one kind', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final live = fakeController();
    addTearDown(live.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
    FilterChip chip() =>
        tester.widget<FilterChip>(find.byKey(const Key('translate-chip')));
    expect(chip().selected, isTrue);
    expect(find.text('English → 简体中文'), findsOneWidget);
    // Off, it names what it would do; the switch beside the languages
    // follows it.
    await tester.tap(find.byKey(const Key('translate-chip')));
    await tester.pumpAndSettle();
    expect(chip().selected, isFalse);
    expect(
      find.descendant(
        of: find.byKey(const Key('translate-chip')),
        matching: find.text('翻译'),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<Switch>(find.byKey(const Key('translate'))).value,
      isFalse,
    );
    // The file-only chip comes last, so the others keep their places.
    final before = tester.getTopLeft(find.byKey(const Key('translate-chip')));
    await tester.tap(find.text('文件').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('refine')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('refine'))).dx,
      greaterThan(before.dx),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
