import 'dart:async';
import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/features/settings/model_settings_dialog.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../remote/host_probe_test.dart' show SettingsStore;
import '../support/fakes.dart';

/// Installs programs without the network: a download waits to be let
/// through, then puts a file where the program would be unpacked. Whisper
/// Large v3 Turbo and the Transcribe model count as downloaded.
class ProgramCatalog extends ModelCatalog {
  ProgramCatalog(this.root)
    : super(Directory('${root.path}/models'), packages: ModelCatalog.programs);
  final Directory root;
  Completer<bool>? pending;

  File file(ProgramPackage package) =>
      File('${programFolder(package)}/Release/${package.executable}');

  ProgramPackage package(String id) =>
      packages.firstWhere((package) => package.id == id);

  /// Puts a program on disk as an earlier download would have left it.
  void install(String id) => file(package(id)).createSync(recursive: true);

  /// What is on disk is what is installed, whichever catalog looks.
  bool installed(ProgramPackage package) => file(package).existsSync();

  @override
  Future<Map<String, ModelAvailability>> scan() async {
    programPaths = {
      for (final package in packages)
        if (installed(package)) package.id: file(package).path,
    };
    return availability = {
      for (final model in ModelCatalog.models)
        model.id: model.id == 'large-v3-turbo'
            ? ModelAvailability.available
            : ModelAvailability.missing,
      for (final model in ModelCatalog.transcribeModels)
        model.id: ModelAvailability.available,
      for (final package in packages)
        package.id: installed(package)
            ? ModelAvailability.available
            : ModelAvailability.missing,
    };
  }

  void report(DownloadStage stage, {double unpacked = 0}) {
    downloadStage = stage;
    installProgress = unpacked;
    notifyListeners();
  }

  @override
  Future<bool> download(SpeechModel model) async {
    downloadingModel = model;
    lastDownload = model;
    downloadError = null;
    downloadStage = DownloadStage.receiving;
    receivedBytes = model.bytes ~/ 2;
    pending = Completer<bool>();
    notifyListeners();
    final success = await pending!.future;
    if (success) install(model.id);
    downloadingModel = null;
    await scan();
    notifyListeners();
    return success;
  }

  @override
  void cancelDownload() {
    if (pending?.isCompleted == false) pending!.complete(false);
  }

  @override
  Future<void> remove(SpeechModel model) async {
    final folder = Directory(programFolder(model as ProgramPackage));
    if (folder.existsSync()) folder.deleteSync(recursive: true);
    await scan();
    notifyListeners();
  }
}

/// Answers with the settings it was given, and keeps what is saved.
class GivenStore extends SettingsStore {
  GivenStore(this.given);
  final Map<String, dynamic> given;
  @override
  Future<Map<String, dynamic>> loadSettings() async => given;
}

void main() {
  const cuda = 'whisper-cpp-1.9.4-cuda';
  const cpu = 'whisper-cpp-1.9.4-cpu';
  const nemo = 'nemo-speech-0.3.0-cuda';
  late Directory root;
  late ProgramCatalog catalog;
  setUp(() {
    root = Directory.systemTemp.createTempSync('program-settings-');
    catalog = ProgramCatalog(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A controller whose Whisper engine is the real one, never started: it
  /// is the kind that needs a program.
  RealtimeController controller({SettingsStore? store, bool own = false}) {
    final audio = FakeAudio();
    final live = RealtimeController(
      audio: audio,
      engine: WhisperService(audio),
      store: store ?? SettingsStore(),
      translator: FakeTranslator(),
      recordSummarizer: FakeTranslator(),
      // Each controller disposes of its catalog; they all look at one disk.
      catalog: own ? ProgramCatalog(root) : catalog,
    )..gpuTotalMemory = (() async => null);
    addTearDown(live.dispose);
    return live;
  }

  Future<void> show(WidgetTester tester, RealtimeController live) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  String status(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(const Key('speech-status')),
          matching: find.byType(Text),
        ),
      )
      .map((text) => text.data)
      .join(' ');

  RadioListTile<String> tile(WidgetTester tester, String id) =>
      tester.widget(find.byKey(Key('program-$id')));

  String? chosen(WidgetTester tester) => tester
      .widget<RadioGroup<String>>(
        find.ancestor(
          of: find.byKey(const Key('program-custom')),
          matching: find.byType(RadioGroup<String>),
        ),
      )
      .groupValue;

  testWidgets(
    'the Whisper program is downloaded, put to use and removed in the panel',
    (tester) async {
      final live = controller()..initialized = true;
      await show(tester, live);

      // With no model chosen, the model is what the start page asks for.
      expect(status(tester), contains('尚未选择转录模型'));
      await tap(tester, find.byKey(const Key('choose-model')));
      expect(find.byType(ModelSettingsDialog), findsOneWidget);

      // The published builds are listed like models: size, state, license
      // and what they need. Nothing is on disk, so none can be chosen.
      expect(find.text('Whisper 程序'), findsOneWidget);
      expect(find.text('NVIDIA GPU'), findsOneWidget);
      expect(find.text('675 MB · 未下载'), findsOneWidget);
      expect(find.text('9 MB · 未下载'), findsOneWidget);
      expect(find.text('whisper.cpp 1.9.4 · MIT'), findsNWidgets(2));
      // The build for the CPU is told from the compute choice by its tile.
      expect(
        find.descendant(
          of: find.byKey(const Key('program-$cpu')),
          matching: find.text('CPU'),
        ),
        findsOneWidget,
      );
      expect(tile(tester, cuda).enabled, isFalse);
      expect(tile(tester, cpu).enabled, isFalse);
      expect(chosen(tester), isNull);
      expect(find.byKey(const Key('program-path')), findsNothing);
      // The other engine's program is not offered here.
      expect(find.byKey(const Key('program-$nemo')), findsNothing);

      // A model alone can be saved; the start page then asks for the
      // program and leads back.
      await tap(tester, find.byKey(const Key('whisper-large-v3-turbo')));
      await tap(tester, find.text('保存'));
      expect(find.byType(ModelSettingsDialog), findsNothing);
      expect(live.executable, isEmpty);
      expect(live.programMissing, isTrue);
      await tap(tester, find.byKey(const Key('nav-0')));
      expect(status(tester), contains('尚未安装 Whisper 程序'));
      expect(find.byKey(const Key('choose-model')), findsNothing);
      await tap(tester, find.byKey(const Key('choose-program')));
      expect(find.byType(ModelSettingsDialog), findsOneWidget);

      // Downloading shows where it is, under the list it belongs to.
      await tap(tester, find.byKey(const Key('download-$cpu')));
      expect(catalog.downloadingModel?.id, cpu);
      expect(find.text('9 MB · 下载中'), findsOneWidget);
      expect(find.byKey(const Key('model-download-progress')), findsOneWidget);
      expect(find.byKey(const Key('cancel-model-download')), findsOneWidget);
      expect(find.textContaining('关闭面板后仍会继续下载'), findsOneWidget);
      // One download at a time: the other build waits.
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('download-$cuda')))
            .onPressed,
        isNull,
      );

      // Once it has arrived it is unpacked, and the bar follows that.
      catalog.report(DownloadStage.installing, unpacked: .25);
      await tester.pump();
      expect(find.text('正在解压…'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('model-download-progress')),
            )
            .value,
        .25,
      );

      // Installed, it is chosen here and in use at once: nothing else was.
      catalog.pending!.complete(true);
      await tester.pumpAndSettle();
      final program = catalog.file(catalog.package(cpu)).path;
      expect(find.byKey(const Key('download-$cpu')), findsNothing);
      expect(find.text('9 MB · 已下载'), findsOneWidget);
      expect(tile(tester, cpu).enabled, isTrue);
      expect(chosen(tester), cpu);
      expect(live.executable, program);
      expect(live.programMissing, isFalse);
      await tap(tester, find.text('取消'));
      expect(status(tester), isNot(contains('尚未安装')));
      expect(find.byKey(const Key('choose-program')), findsNothing);

      // Removing it asks first, names it as a program and leaves the
      // engine without one.
      await tap(tester, find.text('转录模型'));
      expect(chosen(tester), cpu);
      await tap(tester, find.byKey(const Key('remove-$cpu')));
      expect(find.text('移除程序'), findsWidgets);
      expect(
        find.textContaining('whisper.cpp 1.9.4 · CPU\n9 MB'),
        findsOneWidget,
      );
      expect(find.textContaining('程序文件会从这台设备上删除'), findsOneWidget);
      await tap(tester, find.byKey(const Key('confirm-remove-model')));
      expect(File(program).existsSync(), isFalse);
      expect(live.executable, isEmpty);
      expect(chosen(tester), isNull);
      expect(find.byKey(const Key('download-$cpu')), findsOneWidget);
      await tap(tester, find.text('取消'));
      expect(status(tester), contains('尚未安装 Whisper 程序'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a download that ends after the panel was closed and reopened is kept',
    (tester) async {
      final live = controller()..initialized = true;
      await show(tester, live);
      await tap(tester, find.byKey(const Key('choose-model')));
      await tap(tester, find.byKey(const Key('download-$cuda')));

      // The panel is closed; the download goes on and the start page
      // names what is arriving.
      await tap(tester, find.text('取消'));
      expect(find.byKey(const Key('home-model-download')), findsOneWidget);
      expect(
        find.textContaining('下载中 · whisper.cpp 1.9.4 · NVIDIA GPU · 49%'),
        findsOneWidget,
      );
      catalog.report(DownloadStage.installing, unpacked: .5);
      await tester.pump();
      expect(
        find.textContaining('whisper.cpp 1.9.4 · NVIDIA GPU · 正在解压…'),
        findsOneWidget,
      );

      // Opened again, the panel shows the same download; nothing is chosen.
      await tap(tester, find.byKey(const Key('choose-model')));
      expect(find.byKey(const Key('model-download-progress')), findsOneWidget);
      expect(find.text('正在解压…'), findsOneWidget);
      expect(chosen(tester), isNull);

      // It ends while this second panel is open: the program is in use
      // and is the choice here, though another panel started it.
      catalog.pending!.complete(true);
      await tester.pumpAndSettle();
      final program = catalog.file(catalog.package(cuda)).path;
      expect(live.executable, program);
      expect(chosen(tester), cuda);
      expect(find.byKey(const Key('home-model-download')), findsNothing);

      // Saving a model keeps it.
      await tap(tester, find.byKey(const Key('whisper-large-v3-turbo')));
      await tap(tester, find.text('保存'));
      expect(find.byType(ModelSettingsDialog), findsNothing);
      expect(live.executable, program);
      expect(live.programMissing, isFalse);
      expect(status(tester), isNot(contains('尚未')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a program of one\'s own is chosen by a path that leads to a file',
    (tester) async {
      final own = File('${root.path}/own/whisper-server.exe')
        ..createSync(recursive: true);
      catalog.install(cuda);
      await catalog.scan();
      final live = controller()
        ..initialized = true
        ..model = catalog.path(ModelCatalog.models.first)
        ..executable = catalog.programPath(catalog.package(cuda))!;
      await show(tester, live);
      await tap(tester, find.text('转录模型'));

      // The download in use is the one chosen; no path is asked for.
      expect(chosen(tester), cuda);
      expect(tile(tester, cuda).enabled, isTrue);
      expect(find.byKey(const Key('program-path')), findsNothing);

      // Choosing one's own asks for its path, empty at first.
      await tap(tester, find.byKey(const Key('program-custom')));
      final path = find.byKey(const Key('program-path'));
      expect(path, findsOneWidget);
      expect(find.text('whisper-server.exe'), findsOneWidget);
      expect(tester.widget<TextField>(path).controller!.text, isEmpty);

      // A path that leads nowhere is not saved.
      await tester.enterText(path, '${root.path}/nowhere/whisper-server.exe');
      await tap(tester, find.text('保存'));
      expect(find.byType(ModelSettingsDialog), findsOneWidget);
      expect(find.textContaining('找不到 whisper-server.exe'), findsOneWidget);
      expect(live.executable, catalog.programPath(catalog.package(cuda)));

      // One that does is, with whatever stood around it trimmed.
      await tester.enterText(path, '  ${own.path} ');
      await tap(tester, find.text('保存'));
      expect(find.byType(ModelSettingsDialog), findsNothing);
      expect(live.executable, own.path);
      expect(live.programMissing, isFalse);

      // It is what the panel shows the next time, and going back to the
      // download hides the path without forgetting it.
      await tap(tester, find.text('转录模型'));
      expect(chosen(tester), 'custom');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('program-path')))
            .controller!
            .text,
        own.path,
      );
      await tap(tester, find.byKey(const Key('program-$cuda')));
      expect(find.byKey(const Key('program-path')), findsNothing);
      await tap(tester, find.byKey(const Key('program-custom')));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('program-path')))
            .controller!
            .text,
        own.path,
      );
      await tap(tester, find.byKey(const Key('program-$cuda')));
      await tap(tester, find.text('保存'));
      expect(live.executable, catalog.programPath(catalog.package(cuda)));

      // Removing a download that is not in use leaves the setting alone.
      live.executable = own.path;
      await live.saveSettings();
      await tap(tester, find.text('转录模型'));
      expect(chosen(tester), 'custom');
      await tap(tester, find.byKey(const Key('remove-$cuda')));
      await tap(tester, find.byKey(const Key('confirm-remove-model')));
      expect(live.executable, own.path);
      expect(chosen(tester), 'custom');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the Transcribe program is downloaded and saved with the engine',
    (tester) async {
      final live = controller()..initialized = true;
      await show(tester, live);
      await tap(tester, find.byKey(const Key('choose-model')));
      await tap(tester, find.byKey(const Key('speech-provider-transcribe')));
      expect(find.text('Transcribe 程序'), findsOneWidget);
      expect(find.text('NVIDIA GPU'), findsOneWidget);
      expect(find.text('NeMo-Speech.cpp 0.3.0 · Apache 2.0'), findsOneWidget);
      // Whisper's builds are not offered to this engine.
      expect(find.byKey(const Key('program-$cuda')), findsNothing);
      expect(chosen(tester), isNull);

      // A download that fails says so under the programs, not the models.
      await tap(tester, find.byKey(const Key('download-$nemo')));
      catalog.downloadError = 'modelDownloadInvalid';
      catalog.pending!.complete(false);
      await tester.pumpAndSettle();
      final failure = find.byKey(const Key('model-download-error'));
      expect(failure, findsOneWidget);
      expect(
        find.descendant(of: failure, matching: find.text('文件校验失败，请重新下载。')),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(failure).dy,
        greaterThan(tester.getTopLeft(find.text('Transcribe 程序')).dy),
      );
      expect(live.transcribeExecutable, isEmpty);

      // The next try goes through; the program is chosen and in use.
      await tap(tester, find.byKey(const Key('download-$nemo')));
      expect(find.byKey(const Key('model-download-error')), findsNothing);
      catalog.pending!.complete(true);
      await tester.pumpAndSettle();
      final program = catalog.file(catalog.package(nemo)).path;
      expect(chosen(tester), nemo);
      expect(live.transcribeExecutable, program);
      // The engine itself changes only when the panel is saved.
      expect(live.speechProvider, SpeechProvider.whisper);
      await tap(tester, find.text('保存'));
      expect(find.byType(ModelSettingsDialog), findsNothing);
      expect(live.speechProvider, SpeechProvider.transcribe);
      expect(live.engineExecutable, program);
      expect(live.programMissing, isFalse);
      await tap(tester, find.byKey(const Key('nav-0')));
      expect(status(tester), isNot(contains('尚未安装')));

      // Should the program go missing, the start page names the engine's.
      await live.removeModel(catalog.package(nemo));
      await tester.pumpAndSettle();
      expect(live.transcribeExecutable, isEmpty);
      expect(status(tester), contains('尚未安装 Transcribe 程序'));
      expect(find.byKey(const Key('choose-program')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  test('a downloaded program serves an engine that has none on disk', () async {
    catalog
      ..install(cuda)
      ..install(cpu)
      ..install(nemo);
    final gpuBuild = catalog.file(catalog.package(cuda)).path;
    final nemoBuild = catalog.file(catalog.package(nemo)).path;

    // Nothing was ever set: the build for an NVIDIA GPU comes first.
    final fresh = controller(own: true);
    await fresh.initialize();
    expect(fresh.error, isNull);
    expect(fresh.executable, gpuBuild);
    expect(fresh.transcribeExecutable, nemoBuild);
    expect(fresh.programMissing, isFalse);

    // A path that no longer leads anywhere gives way, too.
    final moved = controller(
      own: true,
      store: GivenStore({
        'executable': '${root.path}/gone/whisper-server.exe',
        'transcribeExecutable': '${root.path}/gone/nemo-speech.exe',
      }),
    );
    await moved.initialize();
    expect(moved.executable, gpuBuild);
    expect(moved.transcribeExecutable, nemoBuild);

    // One that does is kept, whatever has been downloaded.
    final own = File('${root.path}/own/whisper-server.exe')
      ..createSync(recursive: true);
    final kept = controller(
      own: true,
      store: GivenStore({'executable': own.path}),
    );
    await kept.initialize();
    expect(kept.executable, own.path);
    expect(kept.programMissing, isFalse);

    // With nothing downloaded, a missing program is reported as missing,
    // and only for an engine that runs one.
    final store = GivenStore({
      'executable': '${root.path}/gone/whisper-server.exe',
    });
    Directory('${root.path}/programs').deleteSync(recursive: true);
    final without = controller(own: true, store: store);
    await without.initialize();
    expect(without.executable, '${root.path}/gone/whisper-server.exe');
    expect(without.programMissing, isTrue);
    without.speechProvider = SpeechProvider.nemotron;
    await without.saveSettings();
    expect(without.programMissing, isFalse);
    without.speechProvider = SpeechProvider.openAI;
    await without.saveSettings();
    expect(without.programMissing, isFalse);
    without.speechProvider = SpeechProvider.transcribe;
    await without.saveSettings();
    expect(without.programMissing, isTrue);

    // Removing the build in use hands the engine the other one.
    catalog
      ..install(cuda)
      ..install(cpu);
    final both = controller();
    await both.initialize();
    expect(both.executable, gpuBuild);
    await both.removeModel(catalog.package(cuda));
    expect(both.executable, catalog.file(catalog.package(cpu)).path);
    expect((both.store as SettingsStore).saved['executable'], both.executable);
  });
}
