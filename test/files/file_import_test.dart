import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';

class SelectorFake extends FileSelectorPlatform {
  List<XFile> files = [];
  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => files;
}

void main() {
  testWidgets(
    'file picker and drops share a queue; duplicates and unsupported files are rejected',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final files = (await tester.runAsync(() async {
        final folder = await Directory('build').createTemp('file-import-test-');
        final first = await File('${folder.path}/one.wav').writeAsBytes([1, 2]);
        final second = await File('${folder.path}/中文录音.MP3')
            .writeAsBytes([3, 4]);
        return (folder, first, second);
      }))!;
      final (folder, first, second) = files;
      addTearDown(() => tester.runAsync(() => folder.delete(recursive: true)));
      final selector = SelectorFake()..files = [XFile(first.path)];
      final originalSelector = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = selector;
      addTearDown(() => FileSelectorPlatform.instance = originalSelector);
      final controller = fakeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(find.byKey(const Key('translate'))).value,
        true,
      );
      await tester.tap(find.text('文件').first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(find.byKey(const Key('translate'))).value,
        true,
      );
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('start'))).onPressed,
        isNull,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('choose-files')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('one.wav'), findsOneWidget);
      final target = tester.widget<DropTarget>(
        find.byKey(const Key('file-drop-target')),
      );
      await tester.runAsync(() async {
        target.onDragDone!(
          DropDoneDetails(
            files: [
              DropItemFile(first.path),
              DropItemFile(second.path),
              DropItemFile('${folder.path}/missing.txt'),
            ],
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('one.wav'), findsOneWidget);
      expect(find.text('中文录音.MP3'), findsOneWidget);
      expect(find.textContaining('missing.txt'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('start'))).onPressed,
        isNotNull,
      );
      // Scrolling then returning used to make ExpansionTile read a double as bool.
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('转录').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('remove-file-0')));
      await tester.tap(find.byKey(const Key('remove-file-0')));
      await tester.pumpAndSettle();
      expect(find.text('one.wav'), findsNothing);
      final options = find.widgetWithText(ExpansionTile, '处理选项');
      await tester.ensureVisible(options);
      await tester.tap(options);
      await tester.pumpAndSettle();
      expect(find.text('区分讲者'), findsNothing);
      expect(find.text('人名统一'), findsOneWidget);
      expect(find.text('专业术语统一'), findsOneWidget);
      expect(find.text('错误词汇修正（仅高置信度）'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        expect(
          tester
              .widget<CheckboxListTile>(find.byKey(ValueKey('file-option-$i')))
              .value,
          false,
        );
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
