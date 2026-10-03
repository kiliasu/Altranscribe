import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/shared/ui/transcript_scroll_controller.dart';
import 'package:altranscribe/shared/ui/transcript_tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('rows sharing a source and start time get their own lasting keys', () {
    final scroll = TranscriptScrollController(following: () => true);
    addTearDown(scroll.dispose);
    List<TranscriptLine> hypothesis(String text) => [
      for (final suffix in ['a', 'b'])
        TranscriptLine(
          source: 'system',
          startMs: 1000,
          endMs: 2000,
          text: '$text $suffix',
        ),
      TranscriptLine(
        source: 'microphone',
        startMs: 1000,
        endMs: 2000,
        text: text,
      ),
    ];
    final keys = scroll.keysFor('session-1', hypothesis('First'));
    expect(keys.toSet(), hasLength(3));
    // The next hypothesis replaces the line objects, not the rows.
    expect(scroll.keysFor('session-1', hypothesis('Second')), keys);
    expect(
      scroll.keysFor('session-2', hypothesis('First')).first,
      isNot(keys.first),
    );
  });

  testWidgets(
    'manual reading stays anchored when earlier translations grow or fail',
    (tester) async {
      final scroll = TranscriptScrollController(following: () => false);
      addTearDown(scroll.dispose);
      final lines = List.generate(
        20,
        (i) => TranscriptLine(
          source: 'file',
          startMs: i * 1000,
          endMs: (i + 1) * 1000,
          text: 'A rather long original sentence for row $i. ' * 3,
          translation: 'A translated sentence for row $i.',
          translationStatus: 'done',
        ),
      );
      Future<void> render() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  for (var i = 0; i < lines.length; i++)
                    TranscriptTile(
                      key: scroll.keyFor(i),
                      line: lines[i],
                      english: true,
                      awaitingTranslation: true,
                      animateTranslation: false,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await render();
      await tester.pumpAndSettle();
      final target =
          tester.getTopLeft(find.byKey(scroll.keyFor(10))).dy + scroll.offset;
      scroll.jumpTo(target + 10);
      await tester.pump();
      final before = tester.getTopLeft(find.byKey(scroll.keyFor(10))).dy;
      scroll.captureAnchor();
      lines[0].translation = 'Very long translation. ' * 100;
      await render();
      expect(
        tester.getTopLeft(find.byKey(scroll.keyFor(10))).dy,
        closeTo(before, .1),
      );
      scroll.captureAnchor();
      lines[1].translation = null;
      lines[1].translationStatus = 'failed';
      await render();
      expect(
        tester.getTopLeft(find.byKey(scroll.keyFor(10))).dy,
        closeTo(before, .1),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
