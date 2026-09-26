import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:altranscribe/shared/platform/environment.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/services/transcription/chinese_script.dart';

enum ComputeMode { automatic, gpu, cpu }

abstract class SpeechEngine {
  String get backend;
  Future<void> start(
    String executable,
    String model,
    Directory directory, {
    ComputeMode compute = ComputeMode.automatic,
  });
  Future<String> transcribe(Uint8List wave, String language);
  Future<void> stop();
}

/// Owns one loopback-only whisper.cpp server, with the model loaded once.
class WhisperService implements SpeechEngine {
  WhisperService(this.audio);
  final AudioService audio;
  Process? _process;
  HttpClient? _client;
  Uri? _base;
  String _log = '';
  int? _exitCode;
  int _generation = 0;
  @override
  String backend = 'whisper.cpp';
  bool gpuActive = false;

  Future<String> _prepareVad(Directory directory) async {
    final data = await rootBundle.load('assets/models/ggml-silero-v5.1.2.bin');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final folder = Directory(
      environmentValue('ALTRANSCRIBE_MODELS_DIR') ?? '${directory.path}/models',
    );
    await folder.create(recursive: true);
    final file = File('${folder.path}/ggml-silero-v5.1.2.bin');
    if (!await file.exists() || !listEquals(await file.readAsBytes(), bytes)) {
      // Sharing and a local session may prepare the same bundled VAD together.
      final temporary = File(
        '${file.path}.${Random.secure().nextInt(1 << 32)}.tmp',
      );
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    return file.absolute.path;
  }

  /// Use acoustic evidence rather than a blacklist of phrases that could also
  /// be spoken intentionally. Keep uncertain segments when metadata is absent.
  static String decodeTranscript(Map<String, dynamic> result, String language) {
    if (result['segments'] is! List) {
      throw const FormatException('Whisper response has no segments');
    }
    final text = StringBuffer();
    for (final segment in result['segments'] as List) {
      if (segment is! Map || segment['text'] is! String) {
        throw const FormatException('Invalid Whisper segment');
      }
      final noSpeech = segment['no_speech_prob'];
      final logProbability = segment['avg_logprob'];
      if (noSpeech is num &&
          logProbability is num &&
          noSpeech > .6 &&
          logProbability < -1) {
        continue;
      }
      text.write(segment['text']);
    }
    return normalizeChineseScript(
      text.toString().trim(),
      language == 'auto' ? result['language'] as String? ?? 'auto' : language,
    );
  }

  // Loading a CUDA DLL is not proof of GPU inference; this line confirms the
  // model actually initialized a GPU compute backend.
  static String? gpuBackendFromLog(String log) =>
      RegExp(r'whisper_backend_init_gpu:\s+using (.+?) backend')
          .firstMatch(log)
          ?.group(1);

  @override
  Future<void> start(
    String executable,
    String model,
    Directory directory, {
    ComputeMode compute = ComputeMode.automatic,
  }) async {
    if (Platform.isAndroid) throw const FormatException('mobileRemoteOnly');
    if (!File(executable).existsSync()) {
      throw const FileSystemException('whisper-server.exe was not found');
    }
    if (!File(model).existsSync()) {
      throw const FileSystemException('Whisper model was not found');
    }
    final generation = _generation + 1;
    await stop();
    if (generation != _generation) {
      throw const HttpException('Whisper startup cancelled');
    }
    _log = '';
    _exitCode = null;
    backend = 'whisper.cpp';
    gpuActive = false;
    final cudaCache = Directory(
      environmentValue('CUDA_CACHE_PATH') ?? '${directory.path}/cuda-cache',
    );
    await cudaCache.create(recursive: true);
    final vadModel = await _prepareVad(directory);
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final random = Random.secure();
    final prefix =
        '/altranscribe-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    _base = Uri.parse('http://127.0.0.1:$port$prefix');
    final process = await Process.start(
      executable,
      [
        '--model',
        model,
        '--host',
        '127.0.0.1',
        '--port',
        '$port',
        '--request-path',
        prefix,
        '--public',
        Directory('${directory.path}/public').path,
        '--threads',
        '${min(8, max(1, Platform.numberOfProcessors ~/ 2))}',
        '--language',
        'auto',
        '--suppress-nst',
        '--vad',
        '--vad-model',
        vadModel,
        '--vad-threshold',
        // The default .5 also accepts Windows mail chimes as speech. This
        // threshold is checked against notification, short and quiet speech fixtures.
        '0.85',
        '--vad-min-speech-duration-ms',
        '250',
        '--vad-min-silence-duration-ms',
        '500',
        '--vad-speech-pad-ms',
        '200',
        '--no-language-probabilities',
        '--no-fallback',
        '--best-of',
        '1',
        '--beam-size',
        '1',
        if (compute == ComputeMode.cpu) '--no-gpu',
      ],
      workingDirectory: directory.path,
      environment: {'CUDA_CACHE_PATH': cudaCache.absolute.path},
    );
    if (generation != _generation) {
      process.kill();
      await process.exitCode;
      throw const HttpException('Whisper startup cancelled');
    }
    _process = process;
    void log(List<int> bytes) {
      final value = utf8.decode(bytes, allowMalformed: true);
      _log += value;
      if (_log.length > 6000) _log = _log.substring(_log.length - 6000);
      final gpu = gpuBackendFromLog(_log);
      if (gpu != null && compute != ComputeMode.cpu) {
        gpuActive = true;
        backend = 'GPU · $gpu · whisper.cpp';
      } else if (!gpuActive &&
          (_log.contains('using CPU backend') ||
              _log.contains('loaded CPU backend'))) {
        backend = 'CPU · whisper.cpp';
      }
    }

    process.stdout.listen(log);
    process.stderr.listen(log);
    unawaited(
      process.exitCode.then((value) {
        if (identical(_process, process)) _exitCode = value;
      }),
    );
    try {
      await audio.ownProcess(process.pid);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      _client = client;
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (DateTime.now().isBefore(deadline)) {
        if (generation != _generation) {
          throw const HttpException('Whisper startup cancelled');
        }
        if (_exitCode != null) {
          throw ProcessException(executable, [], _log, _exitCode!);
        }
        try {
          final request = await client.getUrl(Uri.parse('$_base/health'));
          final response = await request.close().timeout(
            const Duration(seconds: 2),
          );
          final body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 2));
          if (response.statusCode == 200 &&
              jsonDecode(body)['status'] == 'ok') {
            if (compute == ComputeMode.gpu && !gpuActive) {
              throw const FormatException('gpuUnavailable');
            }
            return;
          }
        } on SocketException {
          // The server is still loading the model.
        } on TimeoutException {
          // Keep the startup deadline bounded even for a stalled server.
        } on HttpException {
          if (generation != _generation) rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      throw TimeoutException('Whisper model startup exceeded 3 minutes. $_log');
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<String> transcribe(Uint8List wave, String language) async {
    if (_process == null || _client == null || _exitCode != null) {
      throw StateError('Whisper is not running. $_log');
    }
    final boundary = 'altranscribe-${DateTime.now().microsecondsSinceEpoch}';
    final bytes = BytesBuilder();
    void field(String name, String value) => bytes.add(
      utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="$name"\r\n\r\n$value\r\n',
      ),
    );
    field('language', language);
    field('response_format', 'verbose_json');
    field('token_timestamps', 'false');
    field('translate', 'false');
    field('temperature', '0');
    field('temperature_inc', '0');
    bytes.add(
      utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n',
      ),
    );
    bytes.add(wave);
    bytes.add(utf8.encode('\r\n--$boundary--\r\n'));
    final body = bytes.takeBytes();
    final request = await _client!.postUrl(Uri.parse('$_base/inference'));
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );
    request.contentLength = body.length;
    request.add(body);
    try {
      final response = await request.close().timeout(
        const Duration(minutes: 2),
      );
      final result = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw HttpException('Whisper ${response.statusCode}: $result');
      }
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      return decodeTranscript(decoded, language);
    } catch (_) {
      request.abort();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    _client?.close(force: true);
    _client = null;
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      await process.exitCode;
    }
  }
}
