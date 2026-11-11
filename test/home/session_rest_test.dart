import 'dart:async';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/shared/ui/motion.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';

/// The widgets whose tickers would ask for a frame at every vsync.
List<String> runningTickers() {
  final running = <String>[];
  void visit(Element element) {
    if (element is StatefulElement) {
      for (final property
          in element.state.toDiagnosticsNode().getProperties()) {
        final text = property.toString();
        if ((property.name == 'ticker' || property.name == 'tickers') &&
            text.contains('active') &&
            !text.contains('inactive') &&
            !text.contains('muted')) {
          running.add('${element.widget.runtimeType}');
        }
      }
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return running;
}

void main() {
  testWidgets(
    'a live session rests between sentences once its panel has scrolled away',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final live = fakeController()..generateSummary = false;
      addTearDown(live.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pump(const Duration(seconds: 1));
      unawaited(
        live.start(
          microphone: true,
          system: true,
          language: 'en',
          targetLanguage: 'zh',
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // At the top of a new session the panel is in view and its shape turns.
      expect(runningTickers(), contains('AltLoading'));

      Future<void> speak(int i) async {
        (live.engine as FakeEngine).response = Completer<String>()
          ..complete('Transcript sentence $i. ' * 4);
        (live.audio as FakeAudio).events.add(chunk('microphone', i * 2000));
        for (var j = 0; j < 8; j++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      for (var i = 0; i < 14; i++) {
        await speak(i);
      }
      // Every finite animation ends: rising lines, fades, the receding line.
      for (var j = 0; j < 40; j++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The transcript follows its latest line, the panel is far above, and
      // nothing asks for frames any more: the dot steps on a timer, the
      // panel's shapes are muted.
      expect(runningTickers(), isEmpty);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);

      // Input levels move the meter without waking the rest of the screen.
      var notifications = 0;
      live.addListener(() => notifications++);
      final before = tester
          .widget<LevelMeter>(find.byType(LevelMeter))
          .samples
          .length;
      for (var j = 0; j < 6; j++) {
        (live.audio as FakeAudio).events.add({
          'type': 'level',
          'source': j.isEven ? 'microphone' : 'system',
          'level': .1 + j * .05,
        });
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(notifications, 0);
      expect(
        tester.widget<LevelMeter>(find.byType(LevelMeter)).samples.length,
        greaterThan(before),
      );
      expect(runningTickers(), isEmpty);

      await live.stop();
      for (var j = 0; j < 30; j++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
