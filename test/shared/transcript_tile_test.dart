import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/shared/ui/transcript_tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

TranscriptLine sample({
  String status = 'done',
  String translationStatus = 'none',
  String? translation,
}) => TranscriptLine(
  source: 'system',
  startMs: 0,
  endMs: 2000,
  text: 'Today we will look at how solar panels turn sunlight.',
  transcriptionStatus: status,
  translationStatus: translationStatus,
  translation: translation,
);

Widget host(TranscriptLine line, {bool awaiting = false}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: SizedBox(
        width: 390,
        child: TranscriptTile(
          key: const Key('tile'),
          line: line,
          english: false,
          awaitingTranslation: awaiting,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'the translation space is held from the first word and filled in place',
    (tester) async {
      double height() => tester.getSize(find.byKey(const Key('tile'))).height;
      String status() => tester
          .widget<Text>(find.byKey(const Key('transcript-status')))
          .textSpan!
          .toPlainText();

      await tester.pumpWidget(host(sample(status: 'partial'), awaiting: true));
      await tester.pumpAndSettle();
      final recognizing = height();
      expect(status(), endsWith('识别中'));
      expect(find.byKey(const Key('translation-placeholder')), findsOneWidget);
      // The passing state lives in the header, not in a line of its own.
      expect(find.textContaining('尚未最终确认'), findsNothing);

      await tester.pumpWidget(host(sample(translationStatus: 'pending')));
      await tester.pumpAndSettle();
      expect(height(), recognizing, reason: 'finalizing must not resize');
      expect(status(), endsWith('翻译中'));
      expect(find.byKey(const Key('translation-placeholder')), findsOneWidget);
      expect(
        find.bySemanticsLabel('正在翻译…'),
        findsOneWidget,
        reason: 'screen readers still hear that a translation is coming',
      );

      // A translation of about the source's length takes the placeholder's
      // room exactly; the change is a crossfade in the same place.
      await tester.pumpWidget(
        host(
          sample(
            translationStatus: 'done',
            translation: 'Today we will look at how solar panels use sunlight.',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('translation-placeholder')), findsOneWidget);
      expect(find.byKey(const ValueKey('translation')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translation-placeholder')), findsNothing);
      expect(height(), recognizing);
      expect(status(), isNot(contains('翻译中')));
    },
  );

  testWidgets('lines that are not translated keep the plain layout', (
    tester,
  ) async {
    await tester.pumpWidget(host(sample()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('translation-placeholder')), findsNothing);
    expect(find.byKey(const ValueKey('translation')), findsNothing);
    // A saved partial line still explains itself in full.
    await tester.pumpWidget(host(sample(status: 'interrupted')));
    await tester.pumpAndSettle();
    expect(find.textContaining('未确认文本'), findsOneWidget);
  });
}
