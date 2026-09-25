import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/audio_visualizer.dart';
import 'package:altranscribe/app/theme/app_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import '../support/preview_binding.dart';

class _FileDecoder extends AudioFileDecoder {
  final chunks = StreamController<FileAudioChunk>();
  @override
  Stream<FileAudioChunk> decode(String path, {int chunkSeconds = 20}) =>
      chunks.stream;
  @override
  Future<void> cancel() => chunks.close();
}

void main() {
  PreviewBinding();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final family in ['RobotoFlex', 'MaterialSymbolsRounded']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
    final chinese = FontLoader('NotoSansSC');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      chinese.addFont(rootBundle.load('assets/fonts/NotoSansSC-$weight.ttf'));
    }
    await chinese.load();
  });

  testWidgets(
    'discard confirmation pauses capture, cancel stays paused and history deletion is confirmed',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final controller = fakeController();
      addTearDown(controller.dispose);
      final saved = TranscriptRecord(
        id: 'session-42',
        createdAt: DateTime(2026, 9, 12, 10, 20),
        language: 'en',
        sources: ['microphone'],
        lines: [],
        status: 'completed',
        title: '保留的历史记录',
      );
      await controller.store.save(saved);
      controller.records = [saved];
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      Future<void> tap(String key) async {
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await tap('start');
      final id = controller.record!.id;
      await tap('discard-session');
      expect(controller.phase, SessionPhase.paused);
      expect((controller.audio as FakeAudio).paused, true);
      expect(find.byKey(const Key('confirm-discard')), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.phase, SessionPhase.paused);
      expect(controller.record!.id, id);
      expect((controller.store as MemoryStore).values.containsKey(id), true);
      await tap('pause');
      expect(controller.phase, SessionPhase.listening);
      await tap('discard-session');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.phase, SessionPhase.paused);
      await tap('discard-session');
      await tap('confirm-discard');
      expect(controller.active, false);
      expect((controller.store as MemoryStore).values.containsKey(id), false);
      expect(controller.records.single.id, saved.id);
      await tap('nav-1');
      expect(find.textContaining(saved.dateTimeLabel), findsOneWidget);
      await tap('delete-${saved.id}');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.records.single.id, saved.id);
      await tap('delete-${saved.id}');
      await tap('confirm-delete');
      expect(controller.records, isEmpty);
      expect((controller.store as MemoryStore).values, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'navigation keeps capture while minimized, swaps languages, searches and opens records',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 820);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final controller = fakeController();
      addTearDown(controller.dispose);
      controller.model =
          '${controller.catalog.directory.path}/ggml-large-v3-turbo.bin';
      controller.translationModel = 'gemma3:12b';
      controller.records = [
        TranscriptRecord(
          id: 'session-100',
          createdAt: DateTime(2026, 9, 11, 10, 32, 18),
          language: 'en',
          sources: ['microphone'],
          title: 'GPU 联调与翻译队列讨论',
          summary: '团队讨论了 GPU 转录和翻译队列。',
          summaryStatus: 'done',
          status: 'completed',
          lines: [
            TranscriptLine(
              source: 'microphone',
              startMs: 4000,
              endMs: 11000,
              text: "Okay, let's start with the GPU results from yesterday.",
              translation: '好，我们先从昨天的 GPU 测试结果开始。',
              translationStatus: 'done',
            ),
          ],
        ),
        TranscriptRecord(
          id: 'session-200',
          createdAt: DateTime(2026, 9, 10, 16, 5, 44),
          language: 'en',
          sources: ['system'],
          status: 'completed',
          lines: [],
        ),
      ];
      for (final record in controller.records) {
        await controller.store.save(record);
      }
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: AltranscribeApp(realtime: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.system,
      );
      expect(find.byKey(const Key('quick-language')), findsNothing);
      final summary = tester.widget<FilterChip>(
        find.byKey(const Key('generate-summary')),
      );
      expect(summary.selected, true);
      expect(summary.showCheckmark, false);
      expect((summary.avatar as Icon).icon, AltIcons.check);
      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull, reason: name);
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final bitmap = await boundary.toImage();
          final data = await bitmap.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/preview/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          bitmap.dispose();
        });
      }

      Future<void> tap(Key key) async {
        await tester.tap(find.byKey(key));
        await tester.pumpAndSettle();
      }

      await capture('13-flow-home');
      double panelHeight(String label) => tester
          .getSize(
            find.ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Material &&
                    widget.borderRadius == BorderRadius.circular(20),
              ),
            ),
          )
          .height;
      expect(panelHeight('处理引擎'), panelHeight('语言'));
      expect(tester.getSize(find.byKey(const Key('start'))).height, 96);
      expect(
        tester.getSize(find.byKey(const Key('generate-summary'))).height,
        32,
      );
      final summaryLabel = find.descendant(
        of: find.byKey(const Key('generate-summary')),
        matching: find.text('标题与摘要'),
      );
      expect(
        DefaultTextStyle.of(tester.element(summaryLabel)).style.fontFamily,
        'RobotoFlex',
      );
      final sourceGroup = find.ancestor(
        of: find.byKey(const Key('microphone')),
        matching: find.byType(AltButtonGroup),
      );
      expect(tester.getSize(sourceGroup).height, 56);
      await tap(const Key('swap-languages'));
      await tap(const Key('system-audio'));
      await tap(const Key('start'));
      expect(controller.record!.language, 'zh');
      expect(controller.record!.targetLanguage, 'en');
      (controller.audio as FakeAudio).events.add(chunk('microphone', 0));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      // Fixture levels enter through the same native event path as real meters.
      for (var i = 0; i < 76; i++) {
        (controller.audio as FakeAudio).events.addAll([
          {
            'type': 'level',
            'source': 'microphone',
            'level': i % 19 < 6 ? 0.0 : (i % 7 + 1) * .055,
          },
          {
            'type': 'level',
            'source': 'system',
            'level': i % 23 < 9 ? (i % 5 + 1) * .08 : .002,
          },
        ]);
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pumpAndSettle();
      expect(find.byType(AudioLevelHistory), findsNWidgets(2));
      final microphoneHistory = controller.levelHistory['microphone'];
      final activeRecord = controller.record!.id;
      final sessionShape = tester
          .widget<AltLoading>(find.byType(AltLoading).first)
          .shape;
      await tester.pump(const Duration(seconds: 4));
      expect(
        tester.widget<AltLoading>(find.byType(AltLoading).first).shape,
        sessionShape,
      );
      await capture('14-flow-session');
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      await capture('28-waveform-dark-session');
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(480, 900);
      await tester.pumpAndSettle();
      await capture('27-waveform-480-session');
      tester.view.physicalSize = const Size(1200, 820);
      await tester.pumpAndSettle();
      await tap(const Key('minimize-session'));
      expect(controller.active, true);
      expect(find.byKey(const Key('restore-session')), findsOneWidget);
      expect(
        tester.widget<AltLoading>(find.byType(AltLoading).first).shape,
        sessionShape,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('mini-translation'))).data,
        '测试译文',
      );
      expect(
        tester.getSize(find.byKey(const Key('restore-session'))).width,
        480,
      );
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('start'))).onPressed,
        isNull,
      );
      await capture('15-flow-mini');
      await tap(const ValueKey('nav-1'));
      expect(controller.record!.id, activeRecord);
      await tap(const Key('restore-session'));
      expect(controller.levelHistory['microphone'], same(microphoneHistory));
      expect(find.byKey(const Key('stop')), findsOneWidget);
      await tap(const Key('stop'));
      await tap(const ValueKey('nav-1'));
      await capture('16-flow-library');
      await tester.enterText(find.byKey(const Key('record-search')), 'GPU');
      await tester.pumpAndSettle();
      expect(find.text('GPU 联调与翻译队列讨论'), findsOneWidget);
      expect(find.text('2026-09-10 16:05:44'), findsNothing);
      await tester.tap(find.text('GPU 联调与翻译队列讨论'));
      await tester.pumpAndSettle();
      await capture('17-flow-record');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tap(const ValueKey('nav-3'));
      await capture('18-flow-settings');
      await tap(const Key('palette-baseline'));
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).colorScheme.primary,
        const Color(0xFF6750A4),
      );
      await capture('24-baseline-settings');
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).colorScheme.primary,
        const Color(0xFFD0BCFF),
      );
      await capture('25-baseline-dark-settings');
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
      await tap(const Key('palette-amber'));
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).colorScheme,
        altranscribeTheme(Brightness.light).colorScheme,
      );
      expect(panelHeight('外观'), panelHeight('字幕字号'));
      for (final entry in [
        ('音频选择', '19-audio-dialog'),
        ('模型选择', '20-model-dialog'),
        ('翻译选择', '21-translation-dialog'),
      ]) {
        final label = find.text(entry.$1);
        await tester.ensureVisible(label);
        await tester.tap(label);
        await tester.pumpAndSettle();
        await capture(entry.$2);
        if (entry.$1 == '模型选择') {
          final originalProvider = controller.speechProvider;
          await tap(const Key('speech-provider-remote'));
          expect(
            find.byKey(const Key('remote-connection-summary')),
            findsOneWidget,
          );
          expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
                .onPressed,
            isNull,
          );
          expect(controller.speechProvider, originalProvider);
          await capture('26-whisper-remote-setup');
        }
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
      tester.view.physicalSize = const Size(480, 900);
      await tester.pumpAndSettle();
      await tap(const ValueKey('nav-0'));
      await capture('22-flow-480-home');
      await tap(const Key('start'));
      await tap(const Key('minimize-session'));
      await capture('23-flow-480-mini');
      await tap(const Key('restore-session'));
      await tap(const Key('stop'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'pressing an audio button expands it and releases without overflow',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              // Wide enough for two connected segments in the test font.
              width: 640,
              child: AltButtonGroup(
                stretch: true,
                items: const [
                  AltGroupItem('Microphone', key: Key('first')),
                  AltGroupItem('System audio', key: Key('second')),
                ],
                selected: const {0},
                onPressed: (_) {},
              ),
            ),
          ),
        ),
      );
      final before = tester.getSize(find.byKey(const Key('first'))).width;
      final gesture = await tester.startGesture(
        tester.getTopLeft(find.byKey(const Key('first'))) +
            const Offset(20, 20),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.getSize(find.byKey(const Key('first'))).width,
        greaterThan(before),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('first'))).width,
        closeTo(before, .1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'language swap fades and rotates once even when clicked again during the transition',
    (tester) async {
      final controller = fakeController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      final source = find.byKey(const Key('source-language'));
      final swap = find.byKey(const Key('swap-languages'));
      await tester.ensureVisible(swap);
      await tester.tap(swap);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 225));
      expect(
        tester
            .widget<Opacity>(
              find.descendant(of: source, matching: find.byType(Opacity)),
            )
            .opacity,
        lessThan(.05),
      );
      await tester.tap(swap);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: source, matching: find.text('简体中文')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<AnimatedRotation>(
              find.descendant(
                of: swap,
                matching: find.byType(AnimatedRotation),
              ),
            )
            .turns,
        .5,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'file processing uses the session layout and remains cancellable after minimizing',
    (tester) async {
      final decoder = _FileDecoder();
      final controller = RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: MemoryStore(),
        translator: FakeTranslator(),
        catalog: FakeModelCatalog(),
        fileDecoder: decoder,
      )..initialized = true;
      addTearDown(controller.dispose);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(AltranscribeApp(realtime: controller));
      await tester.pumpAndSettle();
      final processing = controller.startFiles(
        paths: ['meeting.wav'],
        language: 'en',
        targetLanguage: 'zh',
        summaryLanguage: 'zh',
        options: const CleanupOptions(),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      decoder.chunks.add(FileAudioChunk(Uint8List(64000), 0, 2000));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('meeting.wav'), findsOneWidget);
      expect(controller.record!.lines.length, 1);
      expect(find.byKey(const Key('pause')), findsNothing);
      await tester.tap(find.byKey(const Key('minimize-session')));
      await tester.pump();
      expect(controller.active, true);
      expect(find.byKey(const Key('restore-session')), findsOneWidget);
      await tester.tap(find.byKey(const Key('restore-session')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('stop')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await processing;
      expect(controller.active, false);
      expect(
        (controller.store as MemoryStore).values.values.single['lines'],
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
