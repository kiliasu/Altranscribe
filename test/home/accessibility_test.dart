import 'dart:async';
import 'dart:ui' as ui;

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/features/settings/context_settings_dialog.dart';
import 'package:altranscribe/features/settings/caption_settings_dialog.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';

// Mirror the native tree across incremental updates. A parent need not be sent
// again when just its child's value changes; removed nodes need no update.
class _SemanticsBinding extends AutomatedTestWidgetsFlutterBinding {
  final children = <int, List<int>>{};
  final orphans = <String>[];
  String stage = 'application';
  int batches = 0;

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() => _BuilderSpy(this);

  void accept(Map<int, ({List<int> children, String label})> updates) {
    batches++;
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
    // Native serialization drops detached subtrees. Do not retain their old
    // edges or report nodes omitted from a later batch as new orphans.
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
    'dialog sliders keep incremental semantics attached to the root',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = fakeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      expect(binding.semanticsEnabled, isFalse);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpAndSettle();

        Future<void> openDialog(Widget dialog, String stage) async {
          binding.stage = stage;
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(Scaffold).first),
              builder: (_) => dialog,
            ),
          );
          await tester.pumpAndSettle();
        }

        Future<void> adjust(String key) async {
          binding.stage = key;
          final slider = find.byKey(Key(key));
          await tester.ensureVisible(slider);
          final before = tester.widget<Slider>(slider).value;
          if (key == 'caption-sentences') {
            final controls = <SemanticsNode>[];
            void visit(SemanticsNode node) {
              if (node.getSemanticsData().flagsCollection.isSlider) {
                controls.add(node);
              }
              node.visitChildren((child) {
                visit(child);
                return true;
              });
            }

            visit(tester.getSemantics(slider));
            expect(controls, hasLength(1));
            final data = controls.single.getSemanticsData();
            expect(data.hasAction(ui.SemanticsAction.increase), isTrue);
            expect(data.hasAction(ui.SemanticsAction.decrease), isTrue);
          }
          final gesture = await tester.startGesture(tester.getCenter(slider));
          await tester.pump(const Duration(milliseconds: 50));
          await gesture.moveBy(const Offset(70, 0));
          await tester.pump(const Duration(milliseconds: 100));
          await gesture.up();
          await tester.pumpAndSettle();
          if (key == 'caption-sentences') {
            expect(tester.widget<Slider>(slider).value, isNot(before));
          }
        }

        await openDialog(
          CaptionSettingsDialog(controller: controller, english: true),
          'open captions',
        );
        for (final key in [
          'caption-sentences',
          'caption-opacity',
          'caption-font-size',
        ]) {
          await adjust(key);
        }
        binding.stage = 'close captions';
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        await openDialog(
          ContextSettingsDialog(controller: controller, english: true),
          'open context',
        );
        binding.stage = 'enable manual context';
        await tester.tap(find.byKey(const Key('context-auto')));
        await tester.pumpAndSettle();
        await adjust('context-count');
        binding.stage = 'close context';
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(binding.batches, greaterThan(5));
        expect(binding.orphans, isEmpty, reason: binding.orphans.join('\n'));
      } finally {
        semantics.dispose();
      }
    },
    semanticsEnabled: false,
  );
}
