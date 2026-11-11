import 'dart:async';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/shared/ui/motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';

/// A session's shapes keep turning, so the screen never settles: time is
/// moved by hand.
Future<void> after(WidgetTester tester, int milliseconds) async {
  for (var left = milliseconds; left > 0; left -= 50) {
    await tester.pump(Duration(milliseconds: left < 50 ? left : 50));
  }
}

/// How far the floating thing that holds [finder] has faded in.
double presence(WidgetTester tester, Finder finder) => tester
    .widget<Opacity>(
      find
          .ancestor(
            of: find.ancestor(of: finder, matching: find.byType(IgnorePointer)),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

void main() {
  testWidgets('pages, the session bar and what follows it hand over to each '
      'other instead of cutting', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final live = fakeController()..generateSummary = false;
    addTearDown(live.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
    final stop = find.byKey(const Key('stop'));
    final restore = find.byKey(const Key('restore-session'));
    final back = find.byKey(const Key('minimize-session'));

    // Starting: the idle page fades out under the session's page while the
    // bar rises in. The page that leaves is out of reach.
    await tester.tap(find.byKey(const Key('start')));
    await tester.pump();
    await after(tester, 60);
    expect(find.byKey(const Key('start')), findsOneWidget);
    expect(find.byKey(const Key('start')).hitTestable(), findsNothing);
    expect(stop, findsOneWidget);
    expect(presence(tester, stop), allOf(greaterThan(0), lessThan(1)));
    expect(back, findsOneWidget);
    await after(tester, 600);
    expect(find.byKey(const Key('start')), findsNothing);
    expect(presence(tester, stop), 1);

    (live.engine as FakeEngine).response = Completer<String>()
      ..complete('A sentence to keep.');
    (live.audio as FakeAudio).events.add(chunk('microphone', 0));
    await after(tester, 400);
    expect(find.text('A sentence to keep.'), findsOneWidget);

    // Minimizing: the bar lifts away as the corner panel rises.
    await tester.tap(back);
    await tester.pump();
    await after(tester, 60);
    expect(stop, findsOneWidget);
    expect(presence(tester, stop), lessThan(1));
    expect(restore, findsOneWidget);
    expect(presence(tester, restore), allOf(greaterThan(0), lessThan(1)));

    // Back at once: the same bar returns from where it had got to, and
    // there is never a second one.
    await tester.tap(restore);
    await tester.pump();
    await after(tester, 30);
    expect(stop, findsOneWidget);
    expect(back, findsOneWidget);
    await after(tester, 600);
    expect(restore, findsNothing);
    expect(presence(tester, stop), 1);

    // Stopping: the bar gives way to the saved mark in the same place, and
    // the idle page fades back in.
    await tester.tap(stop);
    await tester.pump();
    for (var i = 0; i < 40 && live.active; i++) {
      await after(tester, 50);
    }
    expect(live.active, isFalse);
    await tester.pump();
    await after(tester, 60);
    final saved = find.byKey(const Key('session-saved'));
    expect(saved, findsOneWidget);
    expect(stop, findsOneWidget);
    expect(presence(tester, stop), lessThan(1));
    expect(
      (tester.getCenter(stop).dy - tester.getCenter(saved).dy).abs(),
      lessThan(40),
    );
    await after(tester, 600);
    expect(stop, findsNothing);
    expect(find.byKey(const Key('start')).hitTestable(), findsOneWidget);
    // The mark stays a few seconds and leaves by itself.
    await after(tester, 4500);
    expect(saved, findsNothing);
    expect(find.byType(AltPresence), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
