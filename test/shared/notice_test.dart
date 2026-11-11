import 'package:altranscribe/app/theme/app_theme.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/notice.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('a notice has one shape and a tone for what it says', (
    tester,
  ) async {
    final theme = altranscribeTheme(Brightness.light);
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Column(
            children: [
              const AltNotice('Audio goes to the provider.'),
              const AltNotice.warning('System audio is unavailable.'),
              AltNotice.error(
                'The model could not be loaded.',
                selectable: true,
                action: TextButton(
                  onPressed: () => retried++,
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    Color fill(String message) =>
        (tester
                    .widget<DecoratedBox>(
                      find
                          .ancestor(
                            of: find.text(message),
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration)
            .color!;
    final colors = theme.colorScheme;
    expect(fill('Audio goes to the provider.'), colors.surfaceContainerHigh);
    expect(fill('System audio is unavailable.'), colors.tertiaryContainer);
    expect(fill('The model could not be loaded.'), colors.errorContainer);
    expect(find.byIcon(AltIcons.info), findsOneWidget);
    expect(find.byIcon(AltIcons.warning), findsOneWidget);
    expect(find.byIcon(AltIcons.error), findsOneWidget);
    // A service's own words can be selected and copied.
    expect(find.byType(SelectableText), findsOneWidget);
    // The action reads in the notice's ink and works.
    final label = tester.widget<RichText>(
      find.descendant(of: find.text('Retry'), matching: find.byType(RichText)),
    );
    expect(label.text.style!.color, colors.onErrorContainer);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);
    // Problems are announced as they appear; a remark is not.
    final problem = tester.getSemantics(
      find.text('System audio is unavailable.'),
    );
    expect(problem.flagsCollection.isLiveRegion, isTrue);
    expect(tester.takeException(), isNull);
  });
}
