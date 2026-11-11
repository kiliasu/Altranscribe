import 'dart:async';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/shared/ui/streaming_text.dart';
import 'package:altranscribe/shared/ui/transcript_tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';

void main() {
  // Live sessions keep a dot pulsing; with reduced motion they settle.
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

  test('a changed suffix never starts inside a surrogate pair', () {
    expect(StreamingText.commonPrefix('Hello', 'Hello there'), 5);
    expect(StreamingText.commonPrefix('Hello there', 'Hello, there'), 5);
    expect(StreamingText.commonPrefix('', 'New'), 0);
    // Two emoji share their first code unit; the second must not split one.
    expect(StreamingText.commonPrefix('Hi 😀', 'Hi 😃'), 3);
  });

  test('the session clock holds while the session is paused', () async {
    final live = fakeController();
    addTearDown(live.dispose);
    await live.start(microphone: true, system: false, language: 'en');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await live.togglePause();
    final paused = live.listened;
    expect(paused, greaterThan(Duration.zero));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(live.listened, paused);
    await live.togglePause();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(live.listened, greaterThan(paused));
    await live.stop();
  });

  testWidgets(
    'earlier lines recede while the newest one streams, and a saved session '
    'is acknowledged where its bar was',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final live = fakeController()..generateSummary = false;
      addTearDown(live.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        (live.engine as FakeEngine).response = Completer<String>()
          ..complete('Sentence number $i.');
        (live.audio as FakeAudio).events.add(chunk('microphone', i * 2000));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pumpAndSettle();
      }
      final tiles = tester
          .widgetList<TranscriptTile>(find.byType(TranscriptTile))
          .toList();
      expect(tiles, hasLength(3));
      expect(tiles.last.streaming, isTrue);
      expect(tiles.last.emphasis, 1);
      expect(tiles.first.streaming, isFalse);
      expect(tiles.first.emphasis, lessThan(1));

      await tester.tap(find.byKey(const Key('stop')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-saved')), findsOneWidget);
      await tester.tap(find.byKey(const Key('open-saved')));
      await tester.pumpAndSettle();
      // The saved transcript opens, and the acknowledgement makes way.
      expect(find.text('Sentence number 2.'), findsWidgets);
      expect(find.byKey(const Key('session-saved')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
