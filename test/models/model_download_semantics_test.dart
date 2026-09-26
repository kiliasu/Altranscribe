import 'dart:ui' as ui;

import 'package:altranscribe/app/app.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'model_download_ui_test.dart' show DownloadCatalog;

// Mirrors the native accessibility tree across incremental updates, as the
// Windows bridge does, and records nodes that are sent while detached from
// the root: those are what "will not be in the tree" errors report.
class _SemanticsBinding extends AutomatedTestWidgetsFlutterBinding {
  final children = <int, List<int>>{};
  final orphans = <String>[];
  String stage = 'application';

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() => _BuilderSpy(this);

  void accept(Map<int, ({List<int> children, String label})> updates) {
    for (final entry in updates.entries) {
      children[entry.key] = entry.value.children;
    }
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in children[id] ?? <int>[]) {
        visit(child);
      }
    }

    visit(0);
    for (final entry in updates.entries) {
      if (!reachable.contains(entry.key)) {
        orphans.add('$stage: node ${entry.key} "${entry.value.label}"');
      }
    }
    children.removeWhere((id, _) => !reachable.contains(id));
  }
}

class _BuilderSpy extends Fake implements ui.SemanticsUpdateBuilder {
  _BuilderSpy(this.binding);
  final _SemanticsBinding binding;
  final delegate = ui.SemanticsUpdateBuilder();
  final updates = <int, ({List<int> children, String label})>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final values = invocation.namedArguments;
      updates[values[#id] as int] = (
        children: List<int>.from(values[#childrenInTraversalOrder] as Iterable),
        label: values[#label] as String,
      );
      return null;
    }
    return super.noSuchMethod(invocation);
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => delegate.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );

  @override
  ui.SemanticsUpdate build() {
    binding.accept(updates);
    return delegate.build();
  }
}

void main() {
  final binding = _SemanticsBinding();
  testWidgets(
    'a download in progress keeps its cancel button attached to the tree',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final catalog = DownloadCatalog();
      final controller = fakeController(catalog: catalog);
      addTearDown(controller.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-3')));
        await tester.pumpAndSettle();
        final entry = find.byKey(const ValueKey('settings-modelsEntry'));
        await tester.ensureVisible(entry);
        await tester.tap(entry);
        await tester.pumpAndSettle();

        // The mouse clicks "download", and the cancel button then appears
        // right under it, so its tooltip opens while progress keeps arriving.
        binding.stage = 'download';
        final download = find.byKey(const Key('download-tiny'));
        await tester.ensureVisible(download);
        await tester.pumpAndSettle();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: tester.getCenter(download));
        addTearDown(mouse.removePointer);
        await tester.pump();
        await mouse.down(tester.getCenter(download));
        await mouse.up();
        await tester.pump();
        expect(find.byKey(const Key('cancel-model-download')), findsOneWidget);
        binding.stage = 'hover cancel';
        await mouse.moveBy(const Offset(1, 0));
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(Tooltip), findsWidgets);
        binding.stage = 'progress';
        for (var i = 0; i < 6; i++) {
          catalog.receivedBytes += 1000000;
          catalog.notifyListeners();
          await tester.pump(const Duration(milliseconds: 100));
        }
        binding.stage = 'leave';
        await mouse.moveTo(Offset.zero);
        await tester.pump(const Duration(seconds: 1));
        catalog.pending!.complete(false);
        await tester.pumpAndSettle();
        expect(binding.orphans, isEmpty, reason: binding.orphans.join('\n'));
      } finally {
        semantics.dispose();
      }
    },
    semanticsEnabled: false,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
