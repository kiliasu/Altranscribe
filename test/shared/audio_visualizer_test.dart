import 'dart:ui' as ui;

import 'package:altranscribe/shared/ui/audio_visualizer.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'recording wave moves, freezes on pause and respects reduced motion',
    (tester) async {
      final boundaryKey = GlobalKey();
      Future<void> show({
        required bool running,
        bool reduceMotion = false,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: Scaffold(
                body: RepaintBoundary(
                  key: boundaryKey,
                  child: SizedBox(
                    width: 320,
                    child: RecordingWave(running: running, historyWidth: 320),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      Future<List<int>> pixels() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        return tester
            .runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final result = bytes!.buffer.asUint8List().toList();
              image.dispose();
              return result;
            })
            .then((value) => value!);
      }

      await show(running: true);
      final initial = await pixels();
      await tester.pump(const Duration(milliseconds: 300));
      expect(await pixels(), isNot(equals(initial)));
      await show(running: false);
      await tester.pumpAndSettle();
      final paused = await pixels();
      await tester.pump(const Duration(seconds: 1));
      expect(await pixels(), equals(paused));
      await show(running: true);
      await tester.pump(const Duration(milliseconds: 300));
      expect(await pixels(), isNot(equals(paused)));
      await show(running: true, reduceMotion: true);
      await tester.pumpAndSettle();
      final reduced = await pixels();
      await tester.pump(const Duration(seconds: 1));
      expect(await pixels(), equals(reduced));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
