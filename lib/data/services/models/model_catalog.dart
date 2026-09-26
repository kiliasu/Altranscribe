import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

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

/// A sherpa-onnx export of a Nemotron streaming transducer: a folder of
/// encoder, decoder, joiner and tokens, fetched file by file from a pinned
/// revision of its mirror.
class NemotronModel extends SpeechModel {
  const NemotronModel(
    this.id,
    this.label,
    this.shortLabel, {
    required this.repo,
    required this.revision,
    required this.files,
    required this.multilingual,
    required this.licenseName,
    required this.licenseUrl,
    required this.modelCard,
  });
  @override
  final String id;
  @override
  final String label;
  final String shortLabel;
  final String repo;
  final String revision;
  final List<ModelFile> files;
  final bool multilingual;
  final String licenseName;
  final String licenseUrl;
  final String modelCard;
  static const fileNames = [
    'encoder.int8.onnx',
    'decoder.int8.onnx',
    'joiner.int8.onnx',
    'tokens.txt',
  ];
  @override
  int get bytes => files.fold(0, (sum, file) => sum + file.bytes);
  String get sourceUrl => 'https://huggingface.co/$repo';
  Uri downloadUri(ModelFile file) =>
      Uri.parse('https://huggingface.co/$repo/resolve/$revision/${file.name}');
}

class ModelCatalog extends ChangeNotifier {
  ModelCatalog(this.directory);
  final Directory directory;
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

  String path(WhisperModel model) => '${directory.path}/${model.filename}';

  /// The folder a Nemotron model's files live in.
  String folder(NemotronModel model) => '${directory.path}/${model.id}';

  SpeechModel? downloadingModel;
  int receivedBytes = 0;
  String? downloadError;
  HttpClient? _client;
  bool _cancelled = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void cancelDownload() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<bool> download(SpeechModel model) async {
    if (downloadingModel != null || _disposed) {
      throw StateError('modelDownloadBusy');
    }
    downloadingModel = model;
    receivedBytes = 0;
    downloadError = null;
    _cancelled = false;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    _client = client;
    _notify();
    try {
      await directory.create(recursive: true);
      if (model is WhisperModel) {
        return await _fetch(
          client,
          model.downloadUri,
          File(path(model)),
          model.bytes,
          model.sha256,
        );
      }
      final nemotron = model as NemotronModel;
      final target = Directory(folder(nemotron));
      await target.create(recursive: true);
      // Files already present and complete are kept, so a retry only fetches
      // what is missing.
      for (final file in nemotron.files) {
        final destination = File('${target.path}/${file.name}');
        if (await destination.exists() &&
            await destination.length() == file.bytes) {
          receivedBytes += file.bytes;
          _notify();
          continue;
        }
        if (!await _fetch(
          client,
          nemotron.downloadUri(file),
          destination,
          file.bytes,
          file.sha256,
        )) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      if (!_cancelled) downloadError = 'modelDownloadStorage';
      return false;
    } on FormatException {
      if (!_cancelled) downloadError = 'modelDownloadInvalid';
      return false;
    } catch (_) {
      if (!_cancelled) downloadError = 'modelDownloadFailed';
      return false;
    } finally {
      client.close(force: true);
      _client = null;
      downloadingModel = null;
      _notify();
    }
  }

  /// Streams one file to a temporary name, verifying size and SHA-256 before
  /// it replaces anything; false means the download was cancelled.
  Future<bool> _fetch(
    HttpClient client,
    Uri uri,
    File target,
    int bytes,
    String sha256Hex,
  ) async {
    final temporary = File(
      '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    RandomAccessFile? output;
    final before = receivedBytes;
    try {
      if (_cancelled) return false;
      output = await temporary.open(mode: FileMode.write);
      if (_cancelled) return false;
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw const HttpException('Model download failed');
      }
      if (response.contentLength >= 0 && response.contentLength != bytes) {
        throw const FormatException('modelDownloadInvalid');
      }
      var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
      final digest = await sha256
          .bind(
            response.timeout(const Duration(seconds: 60)).asyncMap((
              chunk,
            ) async {
              if (_cancelled) throw const HttpException('Cancelled');
              receivedBytes += chunk.length;
              if (receivedBytes - before > bytes) {
                throw const FormatException('modelDownloadInvalid');
              }
              await output!.writeFrom(chunk);
              final now = DateTime.now();
              if (now.difference(lastUpdate).inMilliseconds >= 100) {
                lastUpdate = now;
                _notify();
              }
              return chunk;
            }),
          )
          .single;
      if (_cancelled) return false;
      if (receivedBytes - before != bytes || digest.toString() != sha256Hex) {
        throw const FormatException('modelDownloadInvalid');
      }
      await output.flush();
      await output.close();
      output = null;
      if (_cancelled) return false;
      // Only a complete, verified download replaces a previous file.
      await temporary.rename(target.path);
      return true;
    } finally {
      try {
        await output?.close();
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        downloadError ??= 'modelDownloadStorage';
      }
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
        result[model.id] = ModelAvailability.missing;
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
    for (final model in nemotronModels) {
      var present = 0;
      var complete = 0;
      for (final entry in model.files) {
        final file = File('${folder(model)}/${entry.name}');
        if (!await file.exists()) continue;
        present++;
        if (await file.length() == entry.bytes) complete++;
      }
      result[model.id] = complete == model.files.length
          ? ModelAvailability.available
          : present == 0
          ? ModelAvailability.missing
          : ModelAvailability.incomplete;
    }
    return result;
  }
}
