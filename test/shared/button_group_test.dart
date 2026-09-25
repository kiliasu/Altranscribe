import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

Widget group(double width) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: AltButtonGroup(
          key: const Key('group'),
          height: 32,
          stretch: true,
          items: const [
            AltGroupItem('OpenAI compatible', key: Key('first')),
            AltGroupItem('OpenAI', key: Key('second')),
            AltGroupItem('Google Gemini', key: Key('third')),
            AltGroupItem('Anthropic Claude', key: Key('fourth')),
          ],
          selected: const {0},
          onPressed: (_) {},
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('crowded segments wrap into pills without cutting labels off', (
    tester,
  ) async {
    // Wider than the default test surface, so the single-row case has room.
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(group(320));
    final wrapped = tester.getSize(find.byKey(const Key('group')));
    expect(wrapped.height, greaterThan(32));
    for (final key in ['first', 'second', 'third', 'fourth']) {
      final button = find.byKey(Key(key));
      final label = find.descendant(of: button, matching: find.byType(Text));
      // A pill is as wide as its label, so nothing needs an ellipsis.
      expect(
        tester.getSize(button).width,
        greaterThanOrEqualTo(tester.getSize(label).width + 24),
      );
      expect(tester.getSize(button).height, 32);
    }
    expect(tester.takeException(), isNull);

    // The test font is a square font, so labels are wider than in the app.
    await tester.pumpWidget(group(1200));
    expect(tester.getSize(find.byKey(const Key('group'))).height, 32);
    expect(tester.getSize(find.byKey(const Key('group'))).width, 1200);
  });

  testWidgets('translation providers stay readable on a phone-sized window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final live = fakeController();
    addTearDown(live.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-3')));
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('settings-translationSettings'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final group = find.ancestor(
      of: find.byKey(const Key('provider-openAI')),
      matching: find.byType(AltButtonGroup),
    );
    expect(tester.getSize(group).height, greaterThan(32));
    for (final label in ['OpenAI compatible', 'Google Gemini']) {
      final text = tester.widget<Text>(find.text(label));
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: DefaultTextStyle.of(tester.element(find.text(label))).style,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(
        tester.getSize(find.text(label)).width,
        greaterThanOrEqualTo(painter.width - 1),
      );
      painter.dispose();
      expect(text.overflow, TextOverflow.ellipsis);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
