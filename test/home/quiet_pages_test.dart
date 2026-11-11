import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/features/records/record_detail_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';

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

  testWidgets('pages show what can be acted on, not what only reassures', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final live = fakeController();
    addTearDown(live.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
    final stored = strings['storedLocally']![0];
    Future<void> open(int page) async {
      await tester.tap(find.byKey(ValueKey('nav-$page')));
      await tester.pumpAndSettle();
    }

    // With nothing saved, the start page has no empty list of recent
    // transcripts, and the library no field to search nothing with.
    expect(find.text(strings['recent']![0]), findsNothing);
    await open(1);
    expect(find.byKey(const Key('record-search')), findsNothing);
    expect(find.text(strings['emptyLibrary']![0]), findsOneWidget);
    expect(find.text(stored), findsNothing);

    live
      ..records = [
        TranscriptRecord(
          id: 'session-1',
          createdAt: DateTime(2026, 9, 12, 10, 20),
          language: 'en',
          sources: ['microphone'],
          status: 'completed',
          title: 'Interview',
          lines: [
            TranscriptLine(
              source: 'microphone',
              startMs: 0,
              endMs: 2000,
              text: 'A line.',
            ),
          ],
        ),
      ]
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-search')), findsOneWidget);
    // Neither the library nor a transcript says where it is stored.
    expect(find.text(stored), findsNothing);
    await tester.tap(find.text('Interview'));
    await tester.pumpAndSettle();
    expect(find.byType(RecordDetailDialog), findsOneWidget);
    expect(find.text(stored), findsNothing);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await open(0);
    expect(find.text(strings['recent']![0]), findsOneWidget);

    // The device's card is its name and its switch.
    await open(2);
    final card = find.ancestor(
      of: find.text(strings['local']![0]),
      matching: find.byType(Column),
    );
    expect(
      find.descendant(of: card.first, matching: find.byType(Text)),
      findsOneWidget,
    );

    // Privacy says its piece when it is asked, in its own dialog.
    await open(3);
    final privacy = find.byKey(const ValueKey('settings-privacy'));
    await tester.ensureVisible(privacy);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(privacy).subtitle, isNull);
    expect(find.textContaining(stored), findsNothing);
    await tester.tap(privacy);
    await tester.pumpAndSettle();
    expect(find.textContaining(stored), findsOneWidget);
    await tester.tap(find.text(strings['done']![0]));
    await tester.pumpAndSettle();
    // The foot of Settings is the app's name and version.
    expect(
      tester.widget<Text>(find.byKey(const Key('app-version'))).data,
      matches(RegExp(r'^Altranscribe \d+\.\d+\.\d+$')),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
