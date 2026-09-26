import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/features/settings/context_settings_dialog.dart';
import 'package:altranscribe/features/remote/remote_dialogs.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'remote connection fits a narrow window without enabling a host',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final live = fakeController();
      addTearDown(live.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-2')));
      await tester.pumpAndSettle();
      expect(find.text('连接主机'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('connect-manually')));
      await tester.tap(find.byKey(const Key('connect-manually')));
      await tester.pumpAndSettle();
      expect(find.byType(RemoteConnectionDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(live.sharedHost.running, false);
      expect(live.useRemote, false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'context is standalone, captions share the settings card, refinement replaces its icon',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final live = fakeController();
      addTearDown(live.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文件').first);
      await tester.pumpAndSettle();
      final refine = find.byKey(const Key('refine'));
      expect(tester.widget<FilterChip>(refine).showCheckmark, false);
      expect(
        (tester.widget<FilterChip>(refine).avatar! as Icon).icon,
        AltIcons.spellcheck,
      );
      await tester.tap(refine);
      await tester.pumpAndSettle();
      expect(
        (tester.widget<FilterChip>(refine).avatar! as Icon).icon,
        AltIcons.check,
      );
      await tester.tap(find.byKey(const Key('nav-3')));
      await tester.pumpAndSettle();
      final contextEntry = find.byKey(
        const ValueKey('settings-contextSettings'),
      );
      final captionEntry = find.byKey(const Key('caption-settings'));
      Element? materialAncestor(Finder finder) {
        Element? result;
        tester.element(finder).visitAncestorElements((element) {
          if (element.widget is Material) {
            result = element;
            return false;
          }
          return true;
        });
        return result;
      }

      expect(
        materialAncestor(contextEntry),
        same(materialAncestor(captionEntry)),
      );
      expect(find.textContaining('自动化'), findsNothing);
      await tester.ensureVisible(contextEntry);
      await tester.tap(contextEntry);
      await tester.pumpAndSettle();
      expect(find.byType(ContextSettingsDialog), findsOneWidget);
      expect(find.byKey(const Key('llm-address')), findsNothing);
      await tester.tap(find.byKey(const Key('context-auto')));
      await tester.pumpAndSettle();
      tester.widget<Slider>(find.byKey(const Key('context-count'))).onChanged!(
        4,
      );
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(live.translationContext.automatic, false);
      expect(live.translationContext.count, 4);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
