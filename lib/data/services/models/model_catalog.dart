import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:altranscribe/data/services/logging/app_log.dart';
import 'package:altranscribe/data/services/models/zip_archive.dart';

enum ModelAvailability { missing, incomplete, available }

/// A downloadable speech model, shown with its size and download state.
abstract class SpeechModel {
  const SpeechModel();
  String get id;
  String get label;
  int get bytes;
  String get size => bytes >= 1000000000
      ? '${(bytes / 1000000000).toStringAsFixed(2)} GB'
      : '${(bytes / 1000000).round()} MB';
}

class WhisperModel extends SpeechModel {
  const WhisperModel(this.id, this.label, this.bytes, this.sha256);
  @override
  final String id;
  @override
  final String label;
  @override
  final int bytes;
  final String sha256;
  String get filename => 'ggml-$id.bin';
  Uri get downloadUri => Uri.parse(
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
    '${ModelCatalog.revision}/$filename',
  );
}

class ModelFile {
  const ModelFile(this.name, this.bytes, this.sha256);
  final String name;
  final int bytes;
  final String sha256;
}

/// A model that is a folder of files, fetched file by file from a pinned
/// revision of a Hugging Face repository.
abstract class FolderModel extends SpeechModel {
  const FolderModel({
    required this.repo,
    required this.revision,
    required this.files,
    required this.licenseName,
    required this.licenseUrl,
    required this.modelCard,
  });
  final String repo;
  final String revision;
  final List<ModelFile> files;
  final String licenseName;
  final String licenseUrl;
  final String modelCard;
  @override
  int get bytes => files.fold(0, (sum, file) => sum + file.bytes);
  String get sourceUrl => 'https://huggingface.co/$repo';
  Uri downloadUri(ModelFile file) =>
      Uri.parse('https://huggingface.co/$repo/resolve/$revision/${file.name}');
}

/// A sherpa-onnx export of a Nemotron streaming transducer: encoder,
/// decoder, joiner and tokens.
class NemotronModel extends FolderModel {
  const NemotronModel(
    this.id,
    this.label,
    this.shortLabel, {
    required super.repo,
    required super.revision,
    required super.files,
    required this.multilingual,
    required super.licenseName,
    required super.licenseUrl,
    required super.modelCard,
  });
  @override
  final String id;
  @override
  final String label;
  final String shortLabel;
  final bool multilingual;
  static const fileNames = [
    'encoder.int8.onnx',
    'decoder.int8.onnx',
    'joiner.int8.onnx',
    'tokens.txt',
  ];
}

/// Nemotron 3.5 Transcribe as GGUF files for NeMo-Speech.cpp: the language
/// model decoder the server loads, and the speech encoder it names.
class TranscribeModel extends FolderModel {
  const TranscribeModel(
    this.id,
    this.label, {
    required super.repo,
    required super.revision,
    required super.files,
    required super.licenseName,
    required super.licenseUrl,
    required super.modelCard,
  });
  @override
  final String id;
  @override
  final String label;

  /// The file passed to the server; the others sit beside it.
  String get decoder => files.first.name;
}

/// The engine a program serves.
enum ProgramEngine { whisper, transcribe }

/// A program an engine runs, as its project publishes it for Windows: one
/// zip from a release, unpacked into a folder of its own. It is not a
/// model, but it is downloaded, checked, shown and removed the way one is.
class ProgramPackage extends SpeechModel {
  const ProgramPackage(
    this.id, {
    required this.name,
    required this.version,
    required this.variant,
    required this.engine,
    required this.url,
    required this.bytes,
    required this.sha256,
    required this.executable,
    required this.licenseName,
    required this.sourceUrl,
  });
  @override
  final String id;

  /// The project and the release the build is from.
  final String name;
  final String version;

  /// What the build runs on, which tells the builds of one release apart.
  final String variant;
  @override
  String get label => '$name $version · $variant';
  @override
  final int bytes;
  final ProgramEngine engine;
  final String url;
  final String sha256;

  /// The file to run, wherever in the archive it lies.
  final String executable;
  final String licenseName;
  final String sourceUrl;
}

class ModelCatalog extends ChangeNotifier {
  ModelCatalog(
    this.directory, {
    Directory? programDirectory,
    List<ProgramPackage>? packages,
    this.stallTimeout = const Duration(seconds: 30),
    this.retryDelay = const Duration(seconds: 2),
  }) : programDirectory =
           programDirectory ?? Directory('${directory.parent.path}/programs'),
       packages = packages ?? (Platform.isWindows ? programs : const []);
  final Directory directory;

  /// Where downloaded programs are unpacked, each in a folder named by its
  /// id; beside the models unless told otherwise.
  final Directory programDirectory;

  /// The programs this catalog offers: the published Windows builds, and
  /// none where they do not run.
  final List<ProgramPackage> packages;

  /// The programs offered for an engine.
  List<ProgramPackage> programsFor(ProgramEngine engine) =>
      packages.where((package) => package.engine == engine).toList();

  /// No data for this long counts as a dropped connection.
  final Duration stallTimeout;

  /// The wait before the first reconnect; later ones wait longer.
  final Duration retryDelay;

  /// Reconnects per file before a download fails; its partial file stays, so
  /// downloading again continues from there.
  static const retries = 3;
  static const sourceUrl =
      'https://github.com/ggml-org/whisper.cpp/tree/master/models';
  static const revision = '5359861c739e955e79d9a303bcbc70fb988958b1';
  // Official GitHub download script points to this Hugging Face repository.
  // Sizes and SHA-256 values come from the pinned revision's LFS metadata.
  static const models = [
    WhisperModel(
      'large-v3-turbo',
      'Large v3 Turbo',
      1624555275,
      '1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69',
    ),
    WhisperModel(
      'tiny',
      'Tiny',
      77691713,
      'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21',
    ),
    WhisperModel(
      'base',
      'Base',
      147951465,
      '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe',
    ),
    WhisperModel(
      'small',
      'Small',
      487601967,
      '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b',
    ),
    WhisperModel(
      'medium',
      'Medium',
      1533763059,
      '6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208',
    ),
    WhisperModel(
      'large-v3',
      'Large v3',
      3095033483,
      '64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2',
    ),
  ];

  // The int8 exports sherpa-onnx publishes for its "asr-models" release,
  // mirrored file by file on Hugging Face; hashes were taken from the
  // release archives and match the mirror's LFS metadata.
  static const nemotronModels = [
    NemotronModel(
      'nemotron-en-0.6b',
      'Nemotron Streaming · English (0.6B)',
      'English',
      repo: 'csukuangfj2/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25',
      revision: '52056fdc070914a48dcd68b31b44d6a6f5b85902',
      files: [
        ModelFile(
          'encoder.int8.onnx',
          652916849,
          '7d932213491ad355c6e5576705dc3494731a52af87d7a1b954559340147909d8',
        ),
        ModelFile(
          'decoder.int8.onnx',
          7257753,
          '0be9702c2f427a2b6bb241d298e0d3836a558de1f5b9fd3018f1cce6e2b3fa98',
        ),
        ModelFile(
          'joiner.int8.onnx',
          1735862,
          'a35eac38a22ebceb04d230ed7afe0d68f446ba6914a036b97f14fece95967e23',
        ),
        ModelFile(
          'tokens.txt',
          8952,
          'dc0b4584ab2e4ddbf888425c076c61b736e7356a015250db7d307e6f1a8188ff',
        ),
      ],
      multilingual: false,
      licenseName: 'NVIDIA Open Model License',
      licenseUrl: 'https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/',
      modelCard:
          'https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b',
    ),
    NemotronModel(
      'nemotron-3.5-0.6b',
      'Nemotron 3.5 Streaming · Multilingual (0.6B)',
      'Multilingual',
      repo: 'csukuangfj2/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11',
      revision: 'ab43d895f5985b1bbab8b6eac8607fcdc05343f3',
      files: [
        ModelFile(
          'encoder.int8.onnx',
          657601403,
          '012e9321373af99021415e0b0eb3ec827b4be3153be6f30d9b448fe65e896e68',
        ),
        ModelFile(
          'decoder.int8.onnx',
          14978075,
          '19f9c98fc6d0a2c33a65a43b36fdb2e914c26c0aa9764be3aebc502a1e982fb0',
        ),
        ModelFile(
          'joiner.int8.onnx',
          9504438,
          '4101c7c679a0bc30483794b27a059e34e79232aa2068d78d51231a22c8b0d7ce',
        ),
        ModelFile(
          'tokens.txt',
          131440,
          '729cc103155bafa785f9cd45746cd41cabe97eab7182fc04d594129587958f8a',
        ),
      ],
      multilingual: true,
      licenseName: 'OpenMDW 1.1',
      licenseUrl: 'https://openmdw.ai/license/1-1/',
      modelCard:
          'https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b',
    ),
  ];

  static NemotronModel? nemotron(String id) =>
      nemotronModels.where((model) => model.id == id).firstOrNull;

  // AtomicChat's conversion with NVIDIA's own converter: experts in NVFP4
  // for Blackwell GPUs. NVIDIA publishes no GGUF; its NVFP4 checkpoint runs
  // only in vLLM. Sizes and SHA-256 values are the pinned revision's LFS
  // metadata.
  static const transcribeModels = [
    TranscribeModel(
      'nemotron-transcribe-nvfp4',
      'Nemotron 3.5 Transcribe · NVFP4 (30B-A4B)',
      repo: 'AtomicChat/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-GGUF',
      revision: 'dbd06c5cad7a2f33c8e06be2fb3ef814dbd9aa59',
      files: [
        ModelFile(
          'NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-AD-NVFP4.gguf',
          19678656416,
          'ff1ae7655e66efe1d161a83e71c24853cea0614261b041b961089a23c7dcf2d3',
        ),
        ModelFile(
          'NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-Encoder-F16.gguf',
          1670410080,
          '4221029c8a565c4a80c507ffa760c716e595acf663f9f4273ce69910050e7ba2',
        ),
      ],
      licenseName: 'OpenMDW 1.1',
      licenseUrl: 'https://openmdw.ai/license/1-1/',
      modelCard: 'https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B',
    ),
  ];

  static TranscribeModel? transcribe(String id) =>
      transcribeModels.where((model) => model.id == id).firstOrNull;

  // The builds the app is tested against, from each project's own release
  // page. Sizes and SHA-256 values are those GitHub reports for the files;
  // whisper.cpp publishes the binaries of 1.9.4 under its build tag b5130.
  static const programs = [
    ProgramPackage(
      'whisper-cpp-1.9.4-cuda',
      name: 'whisper.cpp',
      version: '1.9.4',
      variant: 'NVIDIA GPU',
      engine: ProgramEngine.whisper,
      url: 'https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-cublas-12.4.0-bin-x64.zip',
      bytes: 674539285,
      sha256:
          'af520ddd034d985b55dfeea3e465ed93653ba2aee1a55e865033edc548c272a7',
      executable: 'whisper-server.exe',
      licenseName: 'MIT',
      sourceUrl: 'https://github.com/ggml-org/whisper.cpp/releases/tag/b5130',
    ),
    ProgramPackage(
      'whisper-cpp-1.9.4-cpu',
      name: 'whisper.cpp',
      version: '1.9.4',
      variant: 'CPU',
      engine: ProgramEngine.whisper,
      url: 'https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-bin-x64.zip',
      bytes: 8573270,
      sha256:
          'f9ec6c52a2e949b62ab51fa21d0d497958f9e41c3010c157c4e42932d5316f3c',
      executable: 'whisper-server.exe',
      licenseName: 'MIT',
      sourceUrl: 'https://github.com/ggml-org/whisper.cpp/releases/tag/b5130',
    ),
    ProgramPackage(
      'nemo-speech-0.3.0-cuda',
      name: 'NeMo-Speech.cpp',
      version: '0.3.0',
      variant: 'NVIDIA GPU',
      engine: ProgramEngine.transcribe,
      url: 'https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v0.3.0/nemo-speech-0.3.0-windows-x86_64-cuda.zip',
      bytes: 508625181,
      sha256:
          'd0d32ae1bf6ee0534767a47b2aa0e9e2ff6fe39643465c0baae9301d04f6ed42',
      executable: 'nemo-speech.exe',
      licenseName: 'Apache 2.0',
      sourceUrl:
          'https://github.com/NVIDIA/NeMo-Speech.cpp/releases/tag/v0.3.0',
    ),
  ];

  /// The folder a program is unpacked into.
  String programFolder(ProgramPackage package) =>
      '${programDirectory.path}/${package.id}';

  /// The archive of a program while it is downloaded and unpacked.
  File _archive(ProgramPackage package) =>
      File('${programDirectory.path}/${package.id}.zip');

  /// Where an unpacked program is kept until all of it is there.
  Directory _staging(ProgramPackage package) =>
      Directory('${programFolder(package)}.unpacking');

  /// Where a program's folder is moved before it is deleted.
  Directory _removing(ProgramPackage package) =>
      Directory('${programFolder(package)}.removing');

  /// The offered program whose installed executable is [path], if any;
  /// separators and letter case do not tell two Windows paths apart.
  ProgramPackage? programAt(String path) {
    String plain(String value) => value.replaceAll('/', r'\').toLowerCase();
    return packages
        .where((package) => programPath(package) != null)
        .where((package) => plain(programPath(package)!) == plain(path))
        .firstOrNull;
  }

  /// Written last into a program's folder: the path of its executable
  /// inside it. A folder without it was not unpacked to the end.
  static const _installed = 'installed.txt';

  /// The executable of each installed program, by package id, as the last
  /// [scan] found them.
  Map<String, String> programPaths = const {};

  /// The executable of [package] if it is installed.
  String? programPath(ProgramPackage package) => programPaths[package.id];

  /// The installed program an engine can run, the one for an NVIDIA GPU
  /// before the one for the CPU.
  String? installedProgram(ProgramEngine engine) =>
      programsFor(engine).map(programPath).nonNulls.firstOrNull;

  /// How far unpacking a program has come, from 0 to 1, while the stage is
  /// [DownloadStage.installing].
  double installProgress = 0;

  String path(WhisperModel model) => '${directory.path}/${model.filename}';

  /// The folder a Nemotron or Transcribe model's files live in.
  String folder(FolderModel model) => '${directory.path}/${model.id}';

  /// The decoder file the Transcribe server loads.
  String decoderPath(TranscribeModel model) =>
      '${folder(model)}/${model.decoder}';

  /// What the last [scan] found, by model id. Downloads and removals scan
  /// again, so listeners see a model appear or go.
  Map<String, ModelAvailability> availability = const {};

  SpeechModel? downloadingModel;

  /// What the download in progress, or the last one, was for: the model or
  /// program [downloadError] is about.
  SpeechModel? lastDownload;
  int receivedBytes = 0;
  DownloadStage downloadStage = DownloadStage.connecting;
  String? downloadError;
  HttpClient? _client;
  bool _cancelled = false;
  Completer<void> _cancel = Completer<void>();
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void cancelDownload() {
    _cancelled = true;
    if (!_cancel.isCompleted) _cancel.complete();
    _client?.close(force: true);
  }

  Future<bool> download(SpeechModel model) async {
    if (downloadingModel != null || _disposed) {
      throw StateError('modelDownloadBusy');
    }
    downloadingModel = model;
    lastDownload = model;
    receivedBytes = 0;
    downloadStage = DownloadStage.connecting;
    downloadError = null;
    _cancelled = false;
    _cancel = Completer<void>();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    _client = client;
    final clock = Stopwatch()..start();
    AppLog.instance.info('models', 'Download of ${model.id} started');
    _notify();
    try {
      if (model is ProgramPackage) {
        await programDirectory.create(recursive: true);
        final archive = _archive(model);
        // An archive that was already downloaded and checked is unpacked
        // again without fetching it a second time.
        final fetched =
            await archive.exists() ||
            await _fetch(
              client,
              Uri.parse(model.url),
              archive,
              model.bytes,
              model.sha256,
            );
        return _finished(model, fetched && await _install(model), clock);
      }
      await directory.create(recursive: true);
      if (model is WhisperModel) {
        return _finished(
          model,
          await _fetch(
            client,
            model.downloadUri,
            File(path(model)),
            model.bytes,
            model.sha256,
          ),
          clock,
        );
      }
      final folderModel = model as FolderModel;
      final target = Directory(folder(folderModel));
      await target.create(recursive: true);
      // Files already present and complete are kept, so a retry only fetches
      // what is missing.
      for (final file in folderModel.files) {
        final destination = File('${target.path}/${file.name}');
        if (await destination.exists() &&
            await destination.length() == file.bytes) {
          receivedBytes += file.bytes;
          _notify();
          continue;
        }
        if (!await _fetch(
          client,
          folderModel.downloadUri(file),
          destination,
          file.bytes,
          file.sha256,
        )) {
          return _finished(model, false, clock);
        }
      }
      return _finished(model, true, clock);
    } on FileSystemException catch (error) {
      _failed(model, 'modelDownloadStorage', error);
      return false;
    } on FormatException catch (error) {
      _failed(model, 'modelDownloadInvalid', error);
      return false;
    } catch (error) {
      _failed(model, 'modelDownloadFailed', error);
      return false;
    } finally {
      client.close(force: true);
      _client = null;
      downloadingModel = null;
      try {
        await scan();
      } on FileSystemException {
        // The next scan reports the folder as it is.
      }
      _notify();
    }
  }

  /// Unpacks a program's archive beside its final folder, notes where its
  /// executable is and moves the folder into place, so a folder that is
  /// there is always whole. The archive goes once that is done. False
  /// means cancelled.
  Future<bool> _install(ProgramPackage package) async {
    final archive = _archive(package);
    final staging = _staging(package);
    final folder = Directory(programFolder(package));
    downloadStage = DownloadStage.installing;
    installProgress = 0;
    _notify();
    if (await staging.exists()) await staging.delete(recursive: true);
    final port = ReceivePort();
    // True once all of it is unpacked, false when it stopped as asked.
    final done = Completer<bool>();
    final orders = Completer<SendPort>();
    await Isolate.spawn(_unpack, [
      archive.path,
      staging.path,
      port.sendPort,
    ], onExit: port.sendPort);
    var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    final messages = port.listen((message) {
      if (message is List && message.length == 2) {
        final total = message[1] as int;
        installProgress = total == 0 ? 1 : (message[0] as int) / total;
        // Progress arrives with every megabyte; listeners hear of it as
        // often as of a download's.
        final now = DateTime.now();
        if (installProgress == 1 ||
            now.difference(lastUpdate).inMilliseconds >= 100) {
          lastUpdate = now;
          _notify();
        }
      } else if (message is SendPort) {
        orders.complete(message);
      } else if (!done.isCompleted) {
        // A bool says how it ended; a text is what went wrong, and a full
        // or locked disk is not a bad archive. Null is the isolate gone
        // without a word.
        if (message is bool) {
          done.complete(message);
        } else if (message is String && message.startsWith(_storage)) {
          done.completeError(
            FileSystemException(message.substring(_storage.length)),
          );
        } else {
          done.completeError(FormatException('${message ?? 'no result'}'));
        }
      }
    });
    try {
      // Cancelling asks the unpacking to stop. It does within a megabyte
      // and closes its files first, so all of it can be deleted.
      unawaited(
        _cancel.future.then((_) async => (await orders.future).send(true)),
      );
      final unpacked = await done.future;
      if (_cancelled || !unpacked) {
        await _discard(package);
        return false;
      }
      String? executable;
      await for (final entry in staging.list(recursive: true)) {
        if (entry is File &&
            entry.uri.pathSegments.last.toLowerCase() ==
                package.executable.toLowerCase()) {
          executable = entry.path
              .substring(staging.path.length + 1)
              .replaceAll(r'\', '/');
          break;
        }
      }
      if (executable == null) {
        throw const FormatException('modelDownloadInvalid');
      }
      await File('${staging.path}/$_installed')
          .writeAsString(executable, flush: true);
      if (await folder.exists()) await folder.delete(recursive: true);
      // A scanner may still hold a file it has just seen written.
      for (var attempt = 0; ; attempt++) {
        try {
          await staging.rename(folder.path);
          break;
        } on FileSystemException {
          if (attempt >= 5) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      await archive.delete();
      return true;
    } on FormatException {
      // An archive that cannot be unpacked is fetched afresh next time.
      await _discard(package);
      rethrow;
    } finally {
      await messages.cancel();
      port.close();
    }
  }

  /// Runs in an isolate of its own: unpacking a gigabyte is a few seconds
  /// of work that the interface should not wait for. Sends a port to tell
  /// it to stop through, then the bytes written and their total as it
  /// goes, then true for done, false for stopped, or what went wrong.
  static Future<void> _unpack(List<Object> arguments) async {
    final port = arguments[2] as SendPort;
    final orders = ReceivePort();
    var stopped = false;
    orders.listen((_) => stopped = true);
    port.send(orders.sendPort);
    try {
      await ZipArchive.extract(
        arguments[0] as String,
        arguments[1] as String,
        progress: (written, total) => port.send([written, total]),
        // An order that has arrived is heard once the work pauses.
        stop: () => Future<bool>.delayed(Duration.zero, () => stopped),
      );
      port.send(true);
    } on ZipStopped {
      port.send(false);
    } on FileSystemException catch (error) {
      port.send('$_storage$error');
    } catch (error) {
      port.send('$error');
    } finally {
      orders.close();
    }
  }

  static const _storage = 'storage: ';

  /// Removes what an interrupted or failed installation, or a removal, left
  /// behind. A file that is still held is left for the next attempt to
  /// replace.
  Future<void> _discard(ProgramPackage package) async {
    for (final leftover in <FileSystemEntity>[
      _staging(package),
      _removing(package),
      _archive(package),
      File('${_archive(package).path}.part'),
    ]) {
      for (var attempt = 0; attempt < 5; attempt++) {
        try {
          if (await leftover.exists()) await leftover.delete(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }
  }

  bool _finished(SpeechModel model, bool success, Stopwatch clock) {
    AppLog.instance.info(
      'models',
      success
          ? 'Download of ${model.id} finished in ${clock.elapsed.inSeconds} s'
          : 'Download of ${model.id} cancelled',
    );
    return success;
  }

  void _failed(SpeechModel model, String reason, Object error) {
    if (_cancelled) {
      AppLog.instance.info('models', 'Download of ${model.id} cancelled');
      return;
    }
    downloadError = reason;
    AppLog.instance.warn(
      'models',
      'Download of ${model.id} failed at $receivedBytes bytes: '
          '${_describe(error)}',
    );
  }

  /// An error without the signed query of a download address.
  static String _describe(Object error) =>
      '${error.runtimeType}: $error'.replaceAll(RegExp('[?][^ ,]*'), '');

  /// Streams one file to `<name>.part` and renames it once its size and
  /// SHA-256 match. A dropped or stalled connection, or a server that is
  /// briefly unavailable, resumes from the bytes already written, up to
  /// [retries] times; a partial file left by an earlier download resumes the
  /// same way. Only cancelling or a corrupt file deletes the partial file.
  /// False means cancelled.
  Future<bool> _fetch(
    HttpClient client,
    Uri uri,
    File target,
    int bytes,
    String sha256Hex,
  ) async {
    final partial = File('${target.path}.part');
    final digest = _DigestSink();
    var hasher = sha256.startChunkedConversion(digest);
    final before = receivedBytes;
    RandomAccessFile? output;
    var corrupt = false;
    try {
      if (_cancelled) return false;
      output = await partial.open(mode: FileMode.append);
      var written = await output.length();
      Future<void> restart() async {
        final file = output!;
        await file.truncate(0);
        await file.setPosition(0);
        hasher = sha256.startChunkedConversion(digest);
        written = 0;
        receivedBytes = before;
      }

      if (written > bytes) await restart();
      // Bytes from an interrupted download count once they are hashed again.
      await output.setPosition(0);
      for (var offset = 0; offset < written;) {
        final chunk = await output.read(min(1 << 20, written - offset));
        if (chunk.isEmpty) throw const FormatException('modelDownloadInvalid');
        hasher.add(chunk);
        offset += chunk.length;
      }
      await output.setPosition(written);
      receivedBytes = before + written;
      if (written > 0) {
        AppLog.instance.info(
          'models',
          'Resuming ${target.uri.pathSegments.last} at $written bytes',
        );
      }
      _notify();
      for (var attempt = 0; written < bytes; attempt++) {
        if (_cancelled) return false;
        try {
          final request = await client.getUrl(uri);
          if (written > 0) {
            request.headers.set(HttpHeaders.rangeHeader, 'bytes=$written-');
          }
          final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
          final status = response.statusCode;
          if (written > 0 && status == HttpStatus.partialContent) {
            final range = response.headers.value(
              HttpHeaders.contentRangeHeader,
            );
            if (range == null || !range.startsWith('bytes $written-')) {
              throw const FormatException('modelDownloadInvalid');
            }
          } else if (status == HttpStatus.ok) {
            // The server sent the whole file again instead of the rest.
            if (written > 0) await restart();
          } else {
            await response.listen(null).cancel();
            if (written > 0 &&
                status == HttpStatus.requestedRangeNotSatisfiable) {
              // The partial file does not fit the file on the server.
              await restart();
              continue;
            }
            throw _Refused(
              status,
              temporary: _temporary.contains(status),
              retryAfter: _retryAfter(response),
            );
          }
          if (response.contentLength >= 0 &&
              response.contentLength != bytes - written) {
            throw const FormatException('modelDownloadInvalid');
          }
          downloadStage = DownloadStage.receiving;
          _notify();
          var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
          await for (final chunk in response.timeout(stallTimeout)) {
            if (_cancelled) return false;
            if (written + chunk.length > bytes) {
              throw const FormatException('modelDownloadInvalid');
            }
            await output.writeFrom(chunk);
            hasher.add(chunk);
            written += chunk.length;
            receivedBytes = before + written;
            final now = DateTime.now();
            if (now.difference(lastUpdate).inMilliseconds >= 100) {
              lastUpdate = now;
              _notify();
            }
          }
          // A response that ends early without an error is a wrong file, not
          // a dropped connection.
          if (written != bytes) {
            throw const FormatException('modelDownloadInvalid');
          }
        } on FormatException {
          rethrow;
        } on FileSystemException {
          rethrow;
        } on _Refused catch (refusal) {
          if (_cancelled) return false;
          if (!refusal.temporary || attempt >= retries) rethrow;
          await _retryLater(
            target,
            written,
            refusal,
            attempt,
            refusal.retryAfter,
          );
        } on Exception catch (error) {
          if (_cancelled) return false;
          if (attempt >= retries) rethrow;
          await _retryLater(target, written, error, attempt);
        }
      }
      hasher.close();
      if (digest.value?.toString() != sha256Hex) {
        throw const FormatException('modelDownloadInvalid');
      }
      await output.flush();
      await output.close();
      output = null;
      if (_cancelled) return false;
      // Only a complete, verified download replaces a previous file.
      await partial.rename(target.path);
      return true;
    } on FormatException {
      corrupt = true;
      rethrow;
    } finally {
      try {
        await output?.close();
        // What arrived intact is kept for the next try, unless the user
        // cancelled or the file turned out wrong.
        if (await partial.exists() &&
            (_cancelled || corrupt || await partial.length() == 0)) {
          await partial.delete();
        }
      } on FileSystemException {
        downloadError ??= 'modelDownloadStorage';
      }
    }
  }

  /// Statuses a server sends when it is busy or briefly unavailable.
  static const _temporary = {408, 425, 429, 500, 502, 503, 504};

  /// A Retry-After given in seconds, at most a minute.
  static Duration? _retryAfter(HttpClientResponse response) {
    final seconds = int.tryParse(
      response.headers.value(HttpHeaders.retryAfterHeader)?.trim() ?? '',
    );
    return seconds == null ? null : Duration(seconds: seconds.clamp(0, 60));
  }

  Future<void> _retryLater(
    File target,
    int written,
    Object reason,
    int attempt, [
    Duration? requested,
  ]) async {
    AppLog.instance.warn(
      'models',
      '${target.uri.pathSegments.last} interrupted at $written bytes '
          '(${_describe(reason)}); retrying',
    );
    downloadStage = DownloadStage.retrying;
    _notify();
    final delay = retryDelay * (attempt + 1);
    await Future.any([
      Future<void>.delayed(
        requested != null && requested > delay ? requested : delay,
      ),
      _cancel.future,
    ]);
  }

  /// Deletes a model's files, including any partial download.
  Future<void> remove(SpeechModel model) async {
    if (downloadingModel == model) throw StateError('modelDownloadBusy');
    try {
      if (model is ProgramPackage) {
        final target = Directory(programFolder(model));
        if (await target.exists()) {
          // Windows lets the folder of a running program be renamed and
          // most of its files deleted, which would leave it running on half
          // of them. A program or library that is loaded cannot be opened
          // for writing, so that is asked first, of each.
          await for (final entry in target.list(recursive: true)) {
            final name = entry.path.toLowerCase();
            if (entry is File &&
                (name.endsWith('.exe') || name.endsWith('.dll'))) {
              await (await entry.open(mode: FileMode.append)).close();
            }
          }
          // The folder is gone at once; what it held is deleted after.
          final aside = _removing(model);
          if (await aside.exists()) await aside.delete(recursive: true);
          await target.rename(aside.path);
        }
        await _discard(model);
      } else if (model is FolderModel) {
        final target = Directory(folder(model));
        if (await target.exists()) await target.delete(recursive: true);
      } else if (model is WhisperModel && await directory.exists()) {
        await for (final entry in directory.list()) {
          final name = entry.uri.pathSegments.last;
          if (entry is File &&
              (name == model.filename ||
                  name.startsWith('${model.filename}.') &&
                      name.endsWith('.part'))) {
            await entry.delete();
          }
        }
      }
      AppLog.instance.info('models', 'Removed ${model.id}');
    } on FileSystemException catch (error) {
      AppLog.instance.warn(
        'models',
        'Removing ${model.id} failed: ${_describe(error)}',
      );
      throw StateError('modelRemoveFailed');
    } finally {
      try {
        await scan();
      } on FileSystemException {
        // The next scan reports the folder as it is.
      }
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancelDownload();
    super.dispose();
  }

  Future<Map<String, ModelAvailability>> scan() async {
    final result = <String, ModelAvailability>{};
    for (final model in models) {
      final file = File(path(model));
      if (!await file.exists()) {
        result[model.id] = await File('${file.path}.part').exists()
            ? ModelAvailability.incomplete
            : ModelAvailability.missing;
        continue;
      }
      result[model.id] = ModelAvailability.incomplete;
      if (await file.length() != model.bytes) continue;
      final handle = await file.open();
      try {
        final header = await handle.read(4);
        if (header.length == 4 &&
            ByteData.sublistView(header).getUint32(0, Endian.little) ==
                0x67676d6c) {
          result[model.id] = ModelAvailability.available;
        }
      } finally {
        await handle.close();
      }
    }
    for (final model in <FolderModel>[...nemotronModels, ...transcribeModels]) {
      var present = 0;
      var complete = 0;
      for (final entry in model.files) {
        final file = File('${folder(model)}/${entry.name}');
        if (await file.exists()) {
          present++;
          if (await file.length() == entry.bytes) complete++;
        } else if (await File('${file.path}.part').exists()) {
          present++;
        }
      }
      result[model.id] = complete == model.files.length
          ? ModelAvailability.available
          : present == 0
          ? ModelAvailability.missing
          : ModelAvailability.incomplete;
    }
    final paths = <String, String>{};
    for (final package in packages) {
      final folder = programFolder(package);
      final note = File('$folder/$_installed');
      if (await note.exists()) {
        final executable = File(
          '$folder/${(await note.readAsString()).trim()}',
        );
        if (await executable.exists()) {
          // Written the way Windows writes a path, as one typed in would be.
          paths[package.id] = Platform.isWindows
              ? executable.absolute.path.replaceAll('/', r'\')
              : executable.absolute.path;
          result[package.id] = ModelAvailability.available;
          continue;
        }
      }
      final archive = _archive(package);
      result[package.id] =
          await Directory(folder).exists() ||
              await _staging(package).exists() ||
              await archive.exists() ||
              await File('${archive.path}.part').exists()
          ? ModelAvailability.incomplete
          : ModelAvailability.missing;
    }
    programPaths = paths;
    availability = result;
    return result;
  }
}

/// Where a download is: waiting for its first bytes, receiving, waiting to
/// reconnect after the connection dropped or stalled, or, for a program,
/// being unpacked.
enum DownloadStage { connecting, receiving, retrying, installing }

/// A request the server answered with an error status. A temporary refusal
/// is tried again; any other ends the download.
class _Refused implements Exception {
  const _Refused(this.status, {required this.temporary, this.retryAfter});
  final int status;
  final bool temporary;
  final Duration? retryAfter;
  @override
  String toString() => 'HTTP $status';
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
