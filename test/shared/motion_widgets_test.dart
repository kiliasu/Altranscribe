import 'package:altranscribe/shared/ui/audio_visualizer.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/shared/ui/motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: 300, child: child),
    ),
  ),
);

void main() {
  testWidgets('what floats comes in, leaves as it was and can come back', (
    tester,
  ) async {
    var taps = 0;
    Widget build(String? label) => host(
      AltPresence(
        child: label == null
            ? null
            : TextButton(
                key: const Key('floating'),
                onPressed: () => taps++,
                child: Text(label),
              ),
      ),
    );
    await tester.pumpWidget(build(null));
    expect(find.byKey(const Key('floating')), findsNothing);

    await tester.pumpWidget(build('Stop'));
    await tester.pump(const Duration(milliseconds: 50));
    final arriving = tester.widget<Opacity>(
      find.ancestor(
        of: find.byKey(const Key('floating')),
        matching: find.byType(Opacity),
      ),
    );
    expect(arriving.opacity, allOf(greaterThan(0), lessThan(1)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('floating')));
    expect(taps, 1);

    // Leaving, it keeps what it showed and takes no more input.
    await tester.pumpWidget(build(null));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.byKey(const Key('floating')), warnIfMissed: false);
    expect(taps, 1);

    // Wanted again before it has gone, it is the same one coming back.
    await tester.pumpWidget(build('Stop'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byKey(const Key('floating')), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('floating')));
    expect(taps, 2);

    await tester.pumpWidget(build(null));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('floating')), findsNothing);
  });

  testWidgets('what is revealed makes its room and gives it back', (
    tester,
  ) async {
    Widget build(bool shown) => host(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 40, child: Text('above')),
          AltReveal(
            child: shown
                ? const SizedBox(
                    key: Key('notice'),
                    height: 60,
                    child: Text('notice'),
                  )
                : null,
          ),
          const SizedBox(key: Key('below'), height: 40, child: Text('below')),
        ],
      ),
    );
    await tester.pumpWidget(build(false));
    final rest = tester.getTopLeft(find.byKey(const Key('below'))).dy;

    await tester.pumpWidget(build(true));
    await tester.pump(const Duration(milliseconds: 80));
    final opening = tester.getTopLeft(find.byKey(const Key('below'))).dy;
    expect(opening, allOf(greaterThan(rest), lessThan(rest + 60)));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(const Key('below'))).dy, rest + 60);
    // It takes the width a stretching column would give it.
    expect(tester.getSize(find.byKey(const Key('notice'))).width, 300);

    await tester.pumpWidget(build(false));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('notice'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('notice'), findsNothing);
    expect(tester.getTopLeft(find.byKey(const Key('below'))).dy, rest);
  });

  testWidgets('one thing takes the place of another at a changing size', (
    tester,
  ) async {
    Widget build(bool files) => host(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AltSwap(
            child: files
                ? const SizedBox(
                    key: ValueKey('files'),
                    height: 200,
                    child: Text('files'),
                  )
                : const SizedBox(
                    key: ValueKey('sources'),
                    height: 80,
                    child: Text('sources'),
                  ),
          ),
          const SizedBox(key: Key('below'), height: 20),
        ],
      ),
    );
    await tester.pumpWidget(build(false));
    final top = tester.getTopLeft(find.byType(AltSwap)).dy;
    double below() => tester.getTopLeft(find.byKey(const Key('below'))).dy;
    expect(below(), top + 80);

    await tester.pumpWidget(build(true));
    await tester.pump(const Duration(milliseconds: 80));
    // Both are on screen for a moment, and the room is on its way.
    expect(find.text('sources'), findsOneWidget);
    expect(find.text('files'), findsOneWidget);
    expect(below(), allOf(greaterThan(top + 80), lessThan(top + 200)));
    await tester.pumpAndSettle();
    expect(find.text('sources'), findsNothing);
    expect(below(), top + 200);

    await tester.pumpWidget(build(false));
    await tester.pumpAndSettle();
    expect(find.text('files'), findsNothing);
    expect(below(), top + 80);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows of a list come and go, and stay put when told to', (
    tester,
  ) async {
    Widget build(List<String> ids, {bool animate = true}) => host(
      AltFlow(
        animate: animate,
        children: [
          for (final id in ids)
            SizedBox(key: ValueKey(id), height: 50, child: Text(id)),
        ],
      ),
    );
    double height() => tester.getSize(find.byType(AltFlow)).height;
    await tester.pumpWidget(build(['a', 'b']));
    // Nothing moves when the list is first shown.
    expect(height(), 100);

    // A new row takes its place at the top and opens.
    await tester.pumpWidget(build(['new', 'a', 'b']));
    await tester.pump(const Duration(milliseconds: 80));
    expect(height(), allOf(greaterThan(100), lessThan(150)));
    await tester.pumpAndSettle();
    expect(height(), 150);
    expect(
      tester.getTopLeft(find.text('new')).dy,
      lessThan(tester.getTopLeft(find.text('a')).dy),
    );

    // A removed row stays where it was while it closes.
    await tester.pumpWidget(build(['new', 'b']));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('a'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('a')).dy,
      lessThan(tester.getTopLeft(find.text('b')).dy),
    );
    await tester.pumpAndSettle();
    expect(find.text('a'), findsNothing);
    expect(height(), 100);

    // While a search narrows the list, rows only come and go.
    await tester.pumpWidget(build(['b'], animate: false));
    await tester.pump();
    expect(find.text('new'), findsNothing);
    expect(height(), 50);
    await tester.pumpWidget(build(['new', 'b'], animate: false));
    await tester.pump();
    expect(height(), 100);

    // A row removed and put back while it closes is a row again.
    await tester.pumpWidget(build(['b']));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(build(['new', 'b']));
    await tester.pumpAndSettle();
    expect(find.text('new'), findsOneWidget);
    expect(height(), 100);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a page fades out as the next fades in, and keeps its state', (
    tester,
  ) async {
    Widget build(String page, {bool lingers = true}) => host(
      SizedBox(
        height: 200,
        child: AltPageSwitcher(
          page: page,
          lingers: lingers,
          child: TextField(key: ValueKey('field-$page')),
        ),
      ),
    );
    await tester.pumpWidget(build('one'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-one')), 'kept');

    await tester.pumpWidget(build('two'));
    await tester.pump(const Duration(milliseconds: 60));
    // The old page is still there, as it was, and out of reach.
    expect(find.text('kept'), findsOneWidget);
    expect(find.byKey(const ValueKey('field-two')), findsOneWidget);
    final leaving = find.byKey(const ValueKey<String>('one'));
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .descendant(of: leaving, matching: find.byType(IgnorePointer))
                .first,
          )
          .ignoring,
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(find.text('kept'), findsNothing);

    // A page that must not linger is gone at once.
    await tester.pumpWidget(build('two', lingers: false));
    await tester.pumpWidget(build('three'));
    await tester.pump();
    expect(find.byKey(const ValueKey('field-two')), findsNothing);
    await tester.pumpAndSettle();

    // With reduced motion the new page is simply there.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(build('three'));
    await tester.pumpWidget(build('four'));
    await tester.pump();
    expect(find.byKey(const ValueKey('field-three')), findsNothing);
    final arrived = find.byKey(const ValueKey<String>('four'));
    expect(
      tester
          .widget<Opacity>(
            find.descendant(of: arrived, matching: find.byType(Opacity)).first,
          )
          .opacity,
      1,
    );
  });

  testWidgets('a dialog rises in and lifts away', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAltDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Title'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final rest = tester.getCenter(find.text('Title'));
    await tester.pumpAndSettle();
    final settled = tester.getCenter(find.text('Title'));
    // It came up from a little below.
    expect(rest.dy, greaterThan(settled.dy));
    expect(rest.dy - settled.dy, lessThan(15));

    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getCenter(find.text('Title')).dy, lessThan(settled.dy));
    await tester.pumpAndSettle();
    expect(find.text('Title'), findsNothing);
  });

  testWidgets('slow decoration steps thirty times a second, only while it '
      'is in view', (tester) async {
    Widget build({bool inView = true, List<double> samples = const [.2]}) =>
        host(
          TickerMode(
            enabled: inView,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AltLoading(),
                const RecordingWave(running: true, historyWidth: 300),
                AudioLevelHistory(
                  samples: samples,
                  running: true,
                  label: 'Level',
                  color: Colors.pink,
                ),
              ],
            ),
          ),
        );
    expect(AltPace.running, 0);
    await tester.pumpWidget(build());
    // The shape and the wave move for as long as they are shown; the level
    // rests until a sample arrives.
    expect(AltPace.running, 2);
    var frames = 0;
    for (var i = 0; i < 100; i++) {
      // Time passes without a frame; one is drawn only when asked for.
      await tester.binding.delayed(const Duration(milliseconds: 10));
      if (tester.binding.hasScheduledFrame) {
        frames++;
        await tester.pump();
      }
    }
    // A second of them asks for about thirty frames, not one per vsync.
    expect(frames, inInclusiveRange(28, 32));

    // A new sample scrolls in over its interval, then the level rests.
    await tester.pumpWidget(build(samples: const [.2, .4]));
    expect(AltPace.running, 3);
    await tester.pump(const Duration(milliseconds: 150));
    expect(AltPace.running, 3);
    await tester.pump(const Duration(milliseconds: 120));
    expect(AltPace.running, 2);

    // Out of view, nothing steps, even as samples keep arriving.
    await tester.pumpWidget(build(inView: false));
    expect(AltPace.running, 0);
    await tester.pumpWidget(build(inView: false, samples: const [.2, .4, .6]));
    await tester.pump(const Duration(milliseconds: 100));
    expect(AltPace.running, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);

    // Back in view, the shape and the wave go on from where they were.
    await tester.pumpWidget(build(samples: const [.2, .4, .6]));
    expect(AltPace.running, 2);
    await tester.pumpWidget(const SizedBox());
    expect(AltPace.running, 0);
  });

  test('the slow clock counts its steps and holds while stopped', () async {
    final others = AltPace.running;
    final pace = AltPace();
    var steps = 0;
    pace.addListener(() => steps++);
    expect(pace.elapsed, Duration.zero);
    pace.run(true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    pace.run(false);
    final held = pace.elapsed;
    expect(steps, greaterThanOrEqualTo(2));
    expect(held, AltPace.step * steps);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(pace.elapsed, held);
    pace.run(true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(pace.elapsed, greaterThan(held));
    pace.dispose();
    expect(AltPace.running, others);
  });
}
