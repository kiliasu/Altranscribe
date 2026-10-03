import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/shared/platform/mobile_platform.dart';

import '../support/fakes.dart';
import '../support/preview_binding.dart';

class DownloadCatalog extends FakeModelCatalog {
  Completer<bool>? pending;
  final downloaded = <String>{};

  @override
  Future<Map<String, ModelAvailability>> scan() async => availability = {
    for (final model in ModelCatalog.models)
      model.id: downloaded.contains(model.id)
          ? ModelAvailability.available
          : ModelAvailability.missing,
  };

  void report(DownloadStage stage, {int? received}) {
    downloadStage = stage;
    if (received != null) receivedBytes = received;
    notifyListeners();
  }

  @override
  Future<bool> download(SpeechModel model) async {
    downloadingModel = model;
    receivedBytes = model.bytes ~/ 2;
    pending = Completer<bool>();
    notifyListeners();
    final success = await pending!.future;
    if (success) downloaded.add(model.id);
    downloadingModel = null;
    notifyListeners();
    return success;
  }

  @override
  void cancelDownload() {
    if (pending?.isCompleted == false) pending!.complete(false);
  }
}

void main() {
  PreviewBinding();
  setUpAll(() async {
    for (final entry in {
      'NotoSansSC': 'assets/fonts/NotoSansSC-Regular.ttf',
      'RobotoFlex': 'assets/fonts/RobotoFlex.ttf',
      'MaterialSymbolsRounded': 'assets/fonts/MaterialSymbolsRounded.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  testWidgets(
    'download stays visible at 390px, finishes and selects the model',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final catalog = DownloadCatalog();
      final controller = fakeController(catalog: catalog);
      addTearDown(controller.dispose);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: AltranscribeApp(realtime: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('模型选择'));
      await tester.tap(find.text('模型选择'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('download-tiny')));
      await tester.tap(find.byKey(const Key('download-tiny')));
      await tester.pumpAndSettle();
      expect(catalog.downloadingModel?.id, 'tiny');
      expect(find.byKey(const Key('model-download-progress')), findsOneWidget);
      expect(find.byKey(const Key('cancel-model-download')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('whisper-tiny')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/preview/13-model-download-narrow.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      catalog.pending!.complete(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('download-tiny')), findsNothing);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(controller.model, endsWith('/ggml-tiny.bin'));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  test('a second download request leaves the running one alone', () async {
    final catalog = DownloadCatalog();
    final controller = fakeController(catalog: catalog);
    addTearDown(controller.dispose);
    final tiny = ModelCatalog.models.firstWhere((model) => model.id == 'tiny');
    final first = controller.downloadModel(tiny, english: false);
    final cancel = MobilePlatform.onDownloadCancel;
    expect(cancel, isNotNull);
    await expectLater(
      controller.downloadModel(tiny, english: false),
      throwsStateError,
    );
    // The refused request changed nothing the running download relies on.
    expect(MobilePlatform.onDownloadCancel, cancel);
    expect(catalog.downloadingModel, tiny);
    catalog.pending!.complete(true);
    expect(await first, isTrue);
    expect(MobilePlatform.onDownloadCancel, isNull);
  });

  testWidgets(
    'a download stays in view on the start page after the panel closes',
    (tester) async {
      final catalog = DownloadCatalog();
      final controller = fakeController(catalog: catalog);
      addTearDown(controller.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('模型选择'));
      await tester.tap(find.text('模型选择'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('download-tiny')));
      await tester.tap(find.byKey(const Key('download-tiny')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转录').last);
      await tester.pumpAndSettle();
      final progress = find.byKey(const Key('home-model-download'));
      await tester.ensureVisible(progress);
      final tiny = ModelCatalog.models.firstWhere(
        (model) => model.id == 'tiny',
      );
      expect(
        find.descendant(
          of: progress,
          matching: find.textContaining(
            'Whisper · Tiny · ${catalog.receivedBytes * 100 ~/ tiny.bytes}%',
          ),
        ),
        findsOneWidget,
      );
      // Waiting for the first bytes or for a reconnect shows that instead.
      catalog.report(DownloadStage.connecting, received: 0);
      await tester.pump();
      expect(find.textContaining('正在连接'), findsOneWidget);
      catalog.report(DownloadStage.retrying);
      await tester.pump();
      expect(find.textContaining('连接中断，正在重试'), findsOneWidget);
      catalog.pending!.complete(true);
      await tester.pumpAndSettle();
      expect(progress, findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'closing and reopening the dialog keeps the download cancellable',
    (tester) async {
      final catalog = DownloadCatalog();
      final controller = fakeController(catalog: catalog);
      addTearDown(controller.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      Future<void> open() async {
        await tester.ensureVisible(find.text('模型选择'));
        await tester.tap(find.text('模型选择'));
        await tester.pumpAndSettle();
      }

      await open();
      await tester.ensureVisible(find.byKey(const Key('download-tiny')));
      await tester.tap(find.byKey(const Key('download-tiny')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(catalog.downloadingModel?.id, 'tiny');
      await open();
      await tester.ensureVisible(
        find.byKey(const Key('cancel-model-download')),
      );
      await tester.tap(find.byKey(const Key('cancel-model-download')));
      await tester.pumpAndSettle();
      expect(catalog.downloadingModel, isNull);
      expect(catalog.downloaded, isEmpty);
      expect(find.byKey(const Key('download-tiny')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
