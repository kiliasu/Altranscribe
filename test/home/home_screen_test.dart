import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/app/theme/app_theme.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';

import '../support/fakes.dart';
import '../support/preview_binding.dart';

void main() {
  PreviewBinding();

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

  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
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

  testWidgets('Android permission errors have a readable localized explanation', (
    tester,
  ) async {
    final controller = fakeController()
      ..error =
          'PlatformException(androidMicrophonePermission, Audio permission denied, null, null)';
    addTearDown(controller.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: controller));
    await tester.pumpAndSettle();
    expect(find.textContaining('请在系统应用权限中允许'), findsOneWidget);
    expect(find.textContaining('PlatformException'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sources, locale, session and sharing remain independent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = fakeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: controller));
    await tester.pumpAndSettle();

    bool source(String key) => tester
        .widget<AltButtonGroup>(
          find.ancestor(
            of: find.byKey(Key(key)),
            matching: find.byType(AltButtonGroup),
          ),
        )
        .selected
        .contains(key == 'microphone' ? 0 : 1);
    Future<void> tap(String key) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    expect(source('microphone'), isTrue);
    expect(source('system-audio'), isFalse);
    await tap('microphone');
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('start'))).onPressed,
      isNull,
    );
    await tap('system-audio');
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('start'))).onPressed,
      isNotNull,
    );
    await tap('microphone');
    expect(source('microphone') && source('system-audio'), isTrue);

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tap('interface-en');
    expect(find.text('English'), findsWidgets);
    expect(find.byKey(const Key('quick-language')), findsNothing);
    await tester.tap(find.text('Transcribe').last);
    await tester.pumpAndSettle();
    expect(source('microphone') && source('system-audio'), isTrue);
    expect(
      tester.widget<Switch>(find.byKey(const Key('translate'))).value,
      isTrue,
    );
    await tester.ensureVisible(find.byKey(const Key('generate-summary')));
    expect(controller.generateSummary, isTrue);
    await tap('start');
    expect(
      find.text('Waiting for transcription. Speak or play speech.'),
      findsOneWidget,
    );
    (controller.audio as FakeAudio).events.add(chunk('system', 0));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('测试译文'), findsOneWidget);
    expect(controller.record!.language, 'en');
    expect(controller.record!.targetLanguage, 'zh');
    await tap('pause');
    expect(find.text('Paused'), findsOneWidget);

    await tester.tap(find.text('Devices').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Switch>(find.byKey(const Key('sharing'))).value,
      false,
    );
    expect(controller.sharedHost.running, false);
    await tester.tap(find.text('Transcribe').last);
    await tester.pumpAndSettle();
    expect(find.text('Paused'), findsOneWidget);
    await tap('stop');
    await tester.tap(find.text('Library').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('1 segments · Saved'), findsOneWidget);
    expect(
      find.textContaining(controller.record!.dateTimeLabel),
      findsOneWidget,
    );
    expect(find.text('测试标题'), findsOneWidget);
    await tester.tap(find.text('测试标题'));
    await tester.pumpAndSettle();
    expect(find.text('测试摘要'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'the home screen renders Chinese, English, dark and narrow layouts',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundaryKey = GlobalKey();
      final controller = fakeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: AltranscribeApp(realtime: controller),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull, reason: name);
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/preview/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        debugPrint('Captured $name');
      }

      Future<void> page(String label) async {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await capture('01-transcribe-zh');
      await tester.tap(find.byKey(const Key('start')));
      await tester.pumpAndSettle();
      await capture('02-session-empty');
      await tester.tap(find.byKey(const Key('stop')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文件'));
      await tester.pumpAndSettle();
      await capture('03-files');
      await page('记录');
      await capture('04-library');
      await page('设备');
      await capture('05-devices');
      await page('设置');
      await capture('06-settings');

      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('interface-en')));
      await tester.pumpAndSettle();
      await capture('07-settings-en-dark');
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.dark,
      );

      final slider = find.byKey(const Key('caption-size'));
      await tester.tap(slider);
      await tester.pumpAndSettle();
      final before = tester.widget<Slider>(slider).value;
      final focus = tester
          .widget<FocusableActionDetector>(
            find
                .descendant(
                  of: slider,
                  matching: find.byType(FocusableActionDetector),
                )
                .first,
          )
          .focusNode!;
      for (int i = 0; i < 24 && !focus.hasFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(
        focus.hasFocus,
        isTrue,
        reason: 'Slider must be reachable using Tab',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, greaterThan(before));

      await page('Transcribe');
      await tester.tap(find.text('Live'));
      await tester.pumpAndSettle();
      await capture('08-transcribe-en-dark');
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      await capture('09-narrow-en-dark');
      await tester.tap(find.byKey(const Key('start')));
      await tester.pumpAndSettle();
      await capture('10-narrow-session');
      await tester.tap(find.byKey(const Key('stop')));
      await tester.pumpAndSettle();
      await page('Settings');
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('interface-zh')));
      await tester.pumpAndSettle();
      await page('转录');
      await capture('11-narrow-zh');
      await tester.ensureVisible(find.byKey(const Key('source-language')));
      await tester.tap(find.byKey(const Key('source-language')));
      await tester.pumpAndSettle();
      expect(find.text('日本語'), findsWidgets);
      await capture('12-language-menu');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('three separate settings panels work at a narrow window width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = fakeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    Future<void> open(String title) async {
      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }

    await open('音频选择');
    expect(find.text('GPU'), findsNothing);
    expect(find.byKey(const Key('llm-address')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('系统默认设备'),
      ),
      findsNWidgets(2),
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await open('模型选择');
    expect(find.byKey(const Key('llm-address')), findsNothing);
    expect(
      tester
          .widget<RadioListTile<String>>(find.byKey(const Key('whisper-tiny')))
          .enabled,
      isFalse,
    );
    await tester.ensureVisible(find.byKey(const Key('whisper-large-v3')));
    await tester.tap(find.byKey(const Key('whisper-large-v3')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('GPU'));
    await tester.tap(find.text('GPU'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.computeMode, ComputeMode.gpu);
    expect(controller.model, endsWith('/ggml-large-v3.bin'));
    await open('翻译选择');
    expect(find.text('GPU'), findsNothing);
    await tester.tap(find.byKey(const Key('provider-openAICompatible')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('llm-model-test-model')));
    await tester.tap(find.byKey(const Key('llm-model-test-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.translationModel, 'test-model');
    expect(controller.llmProvider, LlmProvider.openAICompatible);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'live captions follow new text, support manual scrolling and follow late translations',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = fakeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(find.byKey(const Key('translate'))).value,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('start')));
      await tester.pumpAndSettle();
      final follow = find.byKey(const Key('follow-latest'));
      expect(tester.widget<Checkbox>(follow).value, true);
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is SingleChildScrollView && widget.controller != null,
            ),
          )
          .controller!;
      Future<void> addLine(int number) async {
        (controller.engine as FakeEngine).response = Completer<String>()
          ..complete('Transcript sentence $number. ' * 4);
        (controller.audio as FakeAudio).events.add(
          chunk('microphone', number * 2000),
        );
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pumpAndSettle();
      }

      for (var i = 0; i < 10; i++) {
        await addLine(i);
      }
      expect(scroll.position.maxScrollExtent, greaterThan(500));
      expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
      await tester.tap(follow);
      await tester.pumpAndSettle();
      scroll.jumpTo(120);
      await tester.pumpAndSettle();
      await addLine(10);
      expect(scroll.offset, closeTo(120, 1));
      await tester.tap(follow);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
      // A level update alone must not pull the user back down.
      scroll.jumpTo(200);
      (controller.audio as FakeAudio).events.add({
        'type': 'level',
        'source': 'microphone',
        'level': 0.2,
      });
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(200, 1));
      final translator = controller.translator as FakeTranslator;
      translator.response = Completer<String>();
      await addLine(11);
      expect(find.textContaining('翻译中'), findsWidgets);
      expect(find.byKey(const Key('translation-placeholder')), findsWidgets);
      expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
      final beforeTranslation = scroll.position.maxScrollExtent;
      translator.response!.complete('迟到的中文译文。' * 100);
      await tester.pumpAndSettle();
      expect(find.textContaining('翻译中'), findsNothing);
      expect(find.byKey(const Key('translation-placeholder')), findsNothing);
      expect(scroll.position.maxScrollExtent, greaterThan(beforeTranslation));
      expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
      // The checkbox stays accessible at the bottom; manual mode survives navigation.
      await tester.tap(follow);
      await tester.pumpAndSettle();
      scroll.jumpTo(180);
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('转录').last);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(follow).value, false);
      expect(scroll.offset, closeTo(180, 1));
      await tester.tap(find.byKey(const Key('stop')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start')));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(follow).value, true);
      await tester.tap(find.byKey(const Key('stop')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'record buttons backfill, update open details and rename at narrow width',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = fakeController();
      addTearDown(controller.dispose);
      final record = TranscriptRecord(
        id: 'session-42',
        createdAt: DateTime(2026),
        language: 'en',
        sources: ['system'],
        lines: [
          TranscriptLine(
            source: 'system',
            startMs: 0,
            endMs: 2000,
            text: 'Meeting notes',
          ),
        ],
        status: 'completed',
      );
      controller.records = [record];
      final llm = controller.recordSummarizer as FakeTranslator;
      llm.summaryResponse = Completer<RecordSummary>();
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('summarize-session-42')));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('summarize-session-42')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text(record.displayTitle));
      await tester.pump(const Duration(milliseconds: 300));
      llm.summaryResponse!.complete(const RecordSummary('会议标题', '简洁的会议摘要'));
      await tester.pumpAndSettle();
      expect(find.text('简洁的会议摘要'), findsOneWidget);
      expect(find.byKey(const Key('summarize-session-42')), findsNothing);
      await tester.tap(find.text('重命名标题'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('record-title-input')), ' ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入标题。'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('record-title-input')),
        '我的新标题',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('我的新标题'), findsWidgets);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(controller.records.single.title, '我的新标题');
      expect((await controller.store.loadRecords()).single.summary, '简洁的会议摘要');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  test('Expressive light and dark text roles meet normal text contrast', () {
    for (final brightness in Brightness.values) {
      final c = altranscribeTheme(brightness).colorScheme;
      for (final pair in [
        (c.onSurface, c.surface),
        (c.onSurfaceVariant, c.surfaceContainerLow),
        (c.onPrimary, c.primary),
        (c.onSecondaryContainer, c.secondaryContainer),
        (c.onTertiaryContainer, c.tertiaryContainer),
      ]) {
        final a = pair.$1.computeLuminance();
        final b = pair.$2.computeLuminance();
        final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(ratio, greaterThanOrEqualTo(4.5));
      }
    }
  });
}
