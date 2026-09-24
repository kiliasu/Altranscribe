import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:altranscribe/features/captions/caption_app.dart';
import 'package:altranscribe/features/captions/caption_host.dart';
import 'package:altranscribe/data/models/caption_preferences.dart';
import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/features/settings/caption_settings_dialog.dart';
import 'package:altranscribe/app/theme/app_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import '../support/preview_binding.dart';

final sample = {
  'english': false,
  'phase': 'listening',
  'hasTranslation': true,
  'preferences': const CaptionPreferences().toJson(),
  'rows': [
    {
      'original': 'We can keep the captions visible while working.',
      'translation': '工作时，也能随时看到字幕。',
      'status': 'done',
      'source': 'system',
    },
    {
      'original': 'The next sentence appears here.',
      'translation': '下一句话会显示在这里。',
      'status': 'done',
      'source': 'system',
    },
  ],
};

Future<Object?> captionEvent(
  WidgetTester tester,
  String method, [
  String? action,
]) async {
  final response = Completer<Object?>();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    captionChannel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, action)),
    (data) {
      try {
        response.complete(const StandardMethodCodec().decodeEnvelope(data!));
      } catch (e) {
        response.completeError(e);
      }
    },
  );
  await tester.pump();
  return response.future;
}

void main() {
  PreviewBinding();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final font in ['RobotoFlex', 'MaterialSymbolsRounded']) {
      await (FontLoader(
        font,
      )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
    }
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf'))).load();
  });

  test(
    'caption preferences retain a readable language and supported ranges',
    () {
      final prefs = CaptionPreferences.fromJson({
        'original': false,
        'translation': false,
        'fontSize': 90,
        'sentences': 0,
        'opacity': .1,
        'font': 'missing',
      });
      expect(prefs.original, true);
      expect(prefs.fontSize, 48);
      expect(prefs.opacity, .4);
      expect(prefs.sentences, 1);
      expect(prefs.font, 'RobotoFlex');
      expect(prefs.copyWith(fontSize: 20).toJson()['original'], true);
      expect(
        CaptionPreferences.fromJson(prefs.toJson()).toJson(),
        prefs.toJson(),
      );
    },
  );

  test(
    'continuous captions show latest sentences without changing saved text',
    () {
      final line = TranscriptLine(
        source: 'system',
        startMs: 0,
        endMs: 1000,
        text: 'A value is 3.14. Next sentence! Still speaking',
        translation: '数值是3.14。下一句话！仍在说话',
        continuous: true,
      );
      final record = TranscriptRecord(
        id: 'session-1',
        createdAt: DateTime(2026),
        language: 'en',
        sources: ['system'],
        lines: [line],
      );
      expect(captionSentences(line.text), [
        'A value is 3.14.',
        'Next sentence!',
        'Still speaking',
      ]);
      final rows = captionRows(record, 2);
      expect(rows.single['original'], 'Next sentence! Still speaking');
      expect(rows.single['translation'], '下一句话！ 仍在说话');
      expect(line.text, startsWith('A value is 3.14.'));
    },
  );

  testWidgets(
    'session and mini toggles sync, native actions share capture and close on stop',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        captionChannel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          captionChannel,
          null,
        ),
      );
      final controller = fakeController()..generateSummary = false;
      addTearDown(controller.dispose);
      await tester.runAsync(
        () => controller.start(
          microphone: true,
          system: true,
          language: 'en',
          targetLanguage: 'zh',
        ),
      );
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pump();
      await tester.tap(find.byKey(const Key('session-captions')));
      await tester.pump();
      expect(controller.captionsVisible, true);
      expect(calls.last.method, 'show');
      expect(
        (calls.last.arguments as Map).keys,
        isNot(contains('credentials')),
      );
      await tester.tap(find.byKey(const Key('minimize-session')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('mini-captions')));
      await tester.pump();
      expect(controller.captionsVisible, false);
      expect(calls.last.method, 'hide');
      await tester.tap(find.byKey(const Key('mini-captions')));
      await tester.pump();
      expect(await captionEvent(tester, 'action', 'prepareDiscard'), true);
      expect(controller.phase, SessionPhase.paused);
      expect((controller.audio as FakeAudio).paused, true);
      await captionEvent(tester, 'action', 'cancelDiscard');
      expect(controller.phase, SessionPhase.paused);
      expect(controller.discardConfirmationPending, false);
      await captionEvent(tester, 'action', 'larger');
      expect(controller.captionPreferences.fontSize, 26);
      await captionEvent(tester, 'closed');
      expect(controller.captionsVisible, false);
      expect(controller.active, true);
      controller.setCaptionsVisible(true);
      await tester.pump();
      await captionEvent(tester, 'action', 'pause');
      expect(controller.phase, SessionPhase.listening);
      await tester.runAsync(() => captionEvent(tester, 'action', 'stop'));
      await tester.pump();
      expect(controller.captionsVisible, false);
      expect(calls.last.method, 'hide');
      // The window closes after saving; remaining work may still be draining.
      await tester.runAsync(controller.stop);
      await tester.pump();
      expect(controller.phase, SessionPhase.idle);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('window failure resets the toggle with a readable error', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      captionChannel,
      (_) async => throw PlatformException(code: 'captionWindowFailed'),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        captionChannel,
        null,
      ),
    );
    final live = fakeController()..phase = SessionPhase.listening;
    addTearDown(live.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    live.setCaptionsVisible(true);
    await tester.pump();
    await tester.pump();
    expect(live.captionsVisible, false);
    expect(live.error, 'captionWindowFailed');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'floating discard confirms after pause and cancel never resumes',
    (tester) async {
      final actions = <String>[];
      Future<Object?> action(String value) async {
        actions.add(value);
        return true;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: CaptionPanel(data: sample, action: action),
        ),
      );
      await tester.tap(find.byKey(const Key('caption-discard')));
      await tester.pumpAndSettle();
      expect(actions, ['prepareDiscard']);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(actions, ['prepareDiscard', 'cancelDiscard']);
      await tester.tap(find.byKey(const Key('caption-discard')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('caption-confirm-discard')));
      await tester.pumpAndSettle();
      expect(actions.sublist(2), [
        'prepareDiscard',
        'discard',
        'cancelDiscard',
      ]);
    },
  );

  testWidgets('caption settings remain editable while recording', (
    tester,
  ) async {
    final live = fakeController()..phase = SessionPhase.listening;
    addTearDown(live.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CaptionSettingsDialog(controller: live, english: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('caption-font-size')))
          .onChanged,
      isNotNull,
    );
    expect(find.text('转录进行中，请先停止后修改设置。'), findsNothing);
  });

  for (final size in [const Size(720, 360), const Size(420, 240)]) {
    testWidgets('caption layout at $size and large fonts', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      for (final english in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: altranscribeTheme(Brightness.dark),
            home: RepaintBoundary(
              key: boundary,
              child: CaptionPanel(
                data: {
                  ...sample,
                  'english': english,
                  'preferences': const CaptionPreferences(fontSize: 48)
                      .toJson(),
                },
                action: (_) async => true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      if (size.width == 720) {
        await tester.pumpWidget(
          MaterialApp(
            theme: altranscribeTheme(Brightness.dark),
            home: RepaintBoundary(
              key: boundary,
              child: CaptionPanel(data: sample, action: (_) async => true),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/preview/floating-captions.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }

  testWidgets('navigation fades the new page and respects reduced motion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final live = fakeController();
    addTearDown(live.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final transition = find.byKey(const ValueKey('page-transition-1'));
    final fade = find
        .descendant(of: transition, matching: find.byType(Opacity))
        .first;
    expect(
      tester.widget<Opacity>(fade).opacity,
      allOf(greaterThan(0), lessThan(1)),
    );
    await tester.tap(find.byKey(const Key('nav-3')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    await tester.tap(find.byKey(const Key('nav-1')));
    await tester.pump();
    expect(tester.widget<Opacity>(fade).opacity, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
