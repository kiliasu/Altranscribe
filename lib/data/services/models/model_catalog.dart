import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:altranscribe/data/services/logging/app_log.dart';

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
  ModelCatalog(
    this.directory, {
    this.stallTimeout = const Duration(seconds: 30),
    this.retryDelay = const Duration(seconds: 2),
  });
  final Directory directory;

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

  String path(WhisperModel model) => '${directory.path}/${model.filename}';

  /// The folder a Nemotron model's files live in.
  String folder(NemotronModel model) => '${directory.path}/${model.id}';

  /// What the last [scan] found, by model id. Downloads and removals scan
  /// again, so listeners see a model appear or go.
  Map<String, ModelAvailability> availability = const {};

  SpeechModel? downloadingModel;
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
      if (model is NemotronModel) {
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
    for (final model in nemotronModels) {
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
    availability = result;
    return result;
  }
}

/// Where a download is: waiting for its first bytes, receiving, or waiting to
/// reconnect after the connection dropped or stalled.
enum DownloadStage { connecting, receiving, retrying }

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
