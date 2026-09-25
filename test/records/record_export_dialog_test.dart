import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/features/records/record_export.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TranscriptRecord record({String? inputFile}) => TranscriptRecord(
    id: 'r1',
    createdAt: DateTime(2026, 9, 24, 12, 14, 3),
    language: 'en',
    sources: [inputFile == null ? 'microphone' : 'file'],
    inputFile: inputFile,
    lines: [
      TranscriptLine(source: 'file', startMs: 0, endMs: 1000, text: 'Hello'),
    ],
  );

  Future<void> open(WidgetTester tester, TranscriptRecord item) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showExportDialog(context, item, true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('media options appear only for HTML exports of file records', (
    tester,
  ) async {
    await open(tester, record(inputFile: r'C:\audio\talk.wav'));
    expect(find.byKey(const ValueKey('export-text')), findsOneWidget);
    expect(find.byKey(const ValueKey('export-media-none')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('export-html')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('export-media-none')), findsOneWidget);
    expect(find.byKey(const ValueKey('export-media-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('export-media-embed')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('export-markdown')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('export-media-none')), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('export-confirm')), findsNothing);
  });

  testWidgets('live recordings never offer a player', (tester) async {
    await open(tester, record());
    await tester.tap(find.byKey(const ValueKey('export-html')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('export-media-none')), findsNothing);
    expect(find.byKey(const ValueKey('export-media-embed')), findsNothing);
  });
}
