import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';

/// Counts how often the file picker is asked for.
class CountingSelector extends FileSelectorPlatform {
  int opened = 0;
  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    opened++;
    return [];
  }
}

/// Ctrl with [key], and Shift when asked for.
Future<void> press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

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

  testWidgets(
    'the keyboard moves between pages, sizes text and runs a session',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final live = fakeController();
      addTearDown(live.dispose);
      // One transcript, so the library has something to search.
      live.records = [
        TranscriptRecord(
          id: 'session-1',
          createdAt: DateTime(2026, 9, 12, 10, 20),
          language: 'en',
          sources: ['microphone'],
          lines: [],
          status: 'completed',
          title: 'Kept',
        ),
      ];
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();

      // The pages by number, before anything has been clicked.
      await press(tester, LogicalKeyboardKey.digit2);
      expect(find.byKey(const Key('record-search')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.digit4);
      expect(find.byKey(const Key('reduce-motion')), findsOneWidget);

      // Search goes to the library with the cursor in its field.
      await press(tester, LogicalKeyboardKey.keyF);
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('record-search')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.focusNode.hasFocus, isTrue);
      // The keys still work from inside a text field.
      await press(tester, LogicalKeyboardKey.digit1);
      expect(find.byKey(const Key('start')), findsOneWidget);

      // Text size, as a browser zooms.
      expect(live.interface['textSize'], 22);
      await press(tester, LogicalKeyboardKey.equal);
      expect(live.interface['textSize'], 24);
      await press(tester, LogicalKeyboardKey.equal, shift: true);
      expect(live.interface['textSize'], 26);
      await press(tester, LogicalKeyboardKey.minus);
      expect(live.interface['textSize'], 24);
      await press(tester, LogicalKeyboardKey.digit0);
      expect(live.interface['textSize'], 22);

      // A dialog over the page keeps the keys to itself.
      await tester.tap(find.text('音频选择'));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.digit2);
      expect(find.byKey(const Key('record-search')), findsNothing);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      // The session: start, pause and resume, stop and save.
      await press(tester, LogicalKeyboardKey.keyR, shift: true);
      expect(live.phase, SessionPhase.listening);
      // The button's tooltip names the key that does the same.
      expect(find.byTooltip('暂停 (Ctrl+Shift+P)'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyP, shift: true);
      expect(live.phase, SessionPhase.paused);
      await press(tester, LogicalKeyboardKey.keyP, shift: true);
      expect(live.phase, SessionPhase.listening);
      // Starting again while one runs does nothing.
      final id = live.record!.id;
      await press(tester, LogicalKeyboardKey.keyR, shift: true);
      expect(live.record!.id, id);
      await press(tester, LogicalKeyboardKey.keyS, shift: true);
      expect(live.active, isFalse);

      // Opening files goes to the file queue and brings up the picker.
      final selector = CountingSelector();
      final original = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = selector;
      addTearDown(() => FileSelectorPlatform.instance = original);
      await press(tester, LogicalKeyboardKey.digit3);
      await press(tester, LogicalKeyboardKey.keyO);
      expect(find.byKey(const Key('file-drop-target')), findsOneWidget);
      expect(live.interface['fileMode'], isTrue);
      expect(selector.opened, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
