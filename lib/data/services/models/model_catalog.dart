import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

enum ModelAvailability { missing, incomplete, available }

class WhisperModel {
  const WhisperModel(this.id, this.label, this.bytes, this.sha256);
  final String id;
  final String label;
  final int bytes;
  final String sha256;
  String get filename => 'ggml-$id.bin';
  Uri get downloadUri => Uri.parse(
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
    '${ModelCatalog.revision}/$filename',
  );
  String get size => bytes >= 1000000000
      ? '${(bytes / 1000000000).toStringAsFixed(2)} GB'
      : '${(bytes / 1000000).round()} MB';
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

  String path(WhisperModel model) => '${directory.path}/${model.filename}';

  WhisperModel? downloadingModel;
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

  Future<bool> download(WhisperModel model) async {
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
    final temporary = File(
      '${path(model)}.$pid.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    RandomAccessFile? output;
    _notify();
    try {
      await directory.create(recursive: true);
      if (_cancelled) return false;
      output = await temporary.open(mode: FileMode.write);
      if (_cancelled) return false;
      final request = await client.getUrl(model.downloadUri);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw const HttpException('Model download failed');
      }
      if (response.contentLength >= 0 &&
          response.contentLength != model.bytes) {
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
              if (receivedBytes > model.bytes) {
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
      if (receivedBytes != model.bytes || digest.toString() != model.sha256) {
        throw const FormatException('modelDownloadInvalid');
      }
      await output.flush();
      await output.close();
      output = null;
      if (_cancelled) return false;
      // Only a complete, verified download replaces a previous model.
      await temporary.rename(path(model));
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
      try {
        await output?.close();
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        downloadError ??= 'modelDownloadStorage';
      }
      _client = null;
      downloadingModel = null;
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
    return result;
  }
}
