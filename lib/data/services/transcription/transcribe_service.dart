import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:altranscribe/shared/platform/environment.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/services/transcription/chinese_script.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';

/// Owns one loopback-only NeMo-Speech.cpp server running Nemotron 3.5
/// Transcribe, with the model loaded once. The model writes punctuation
/// itself and times every word, so files keep its own sentence timing.
class TranscribeService implements TimedSpeechEngine {
  TranscribeService(this.audio, {this.freeGpuMemory = nvidiaFreeMemory});
  final AudioService audio;

  /// Free GPU memory in bytes, or null when it cannot be read.
  final Future<int?> Function() freeGpuMemory;
  Process? _process;
  HttpClient? _client;
  Uri? _base;
  String _key = '';
  String _log = '';
  int? _exitCode;
  int _generation = 0;
  @override
  String backend = 'NeMo-Speech.cpp';

  /// Memory the server needs beyond its model files: KV cache, recurrent
  /// state and work buffers. Measured on an RTX 5090, a 55-minute piece
  /// peaked at 7.2 GB above the files.
  static const headroomBytes = 7500000000;

  /// What a live session adds to the files: its short windows stay near
  /// the 2.3 GB measured once the model has loaded.
  static const liveHeadroomBytes = 2500000000;

  /// Where NeMo-Speech.cpp's own installer puts the program, if it is there.
  static String? installedProgram() {
    final base = Platform.environment['LOCALAPPDATA'];
    if (!Platform.isWindows || base == null) return null;
    final path = '$base\\Programs\\NeMoSpeech\\bin\\nemo-speech.exe';
    return File(path).existsSync() ? path : null;
  }

  @override
  Future<void> start(
    String executable,
    String model,
    Directory directory, {
    ComputeMode compute = ComputeMode.automatic,
  }) async {
    if (Platform.isAndroid) throw const FormatException('mobileRemoteOnly');
    if (!File(executable).existsSync()) {
      throw const FormatException('transcribeProgramMissing');
    }
    final files = Directory(File(model).parent.path)
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.gguf'))
        .toList();
    if (!File(model).existsSync() || files.length < 2) {
      throw const FormatException('transcribeModelMissing');
    }
    final generation = _generation + 1;
    await stop();
    if (generation != _generation) {
      throw const HttpException('Transcribe startup cancelled');
    }
    final needed =
        files.fold<int>(0, (sum, file) => sum + file.lengthSync()) +
        headroomBytes;
    final free = await freeGpuMemory();
    if (free != null && free < needed) {
      throw FormatException(
        'transcribeMemory: ${(free / 1e9).toStringAsFixed(1)} '
        '${(needed / 1e9).toStringAsFixed(0)}',
      );
    }
    _log = '';
    _exitCode = null;
    backend = 'NeMo-Speech.cpp';
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final random = Random.secure();
    _key = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _base = Uri.parse('http://127.0.0.1:$port');
    final process = await Process.start(
      executable,
      [
        'serve',
        '--asr-model',
        model,
        '--host',
        '127.0.0.1',
        '--port',
        '$port',
        // The 4-bit weights run only on CUDA; without it the server stops
        // instead of falling back to the CPU.
        '--device',
        'cuda:0',
        // The app sends one request at a time: two slots whose shared cache
        // holds an hour of audio use less memory than the default sixteen.
        '--asr.salm.max_sequences',
        '2',
        '--asr.salm.n_ctx_per_sequence',
        '36864',
      ],
      workingDirectory: directory.path,
      // In the environment, the key stays out of the visible command line.
      environment: {
        'NEMO_SPEECH_HTTP_API_KEY': _key,
        'CUDA_CACHE_PATH': Directory(
          environmentValue('CUDA_CACHE_PATH') ?? '${directory.path}/cuda-cache',
        ).absolute.path,
      },
    );
    if (generation != _generation) {
      process.kill();
      await process.exitCode;
      throw const HttpException('Transcribe startup cancelled');
    }
    _process = process;
    void log(List<int> bytes) {
      _log += utf8.decode(bytes, allowMalformed: true);
      if (_log.length > 6000) _log = _log.substring(_log.length - 6000);
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
      // Twenty gigabytes come off the disk before the server is ready.
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (generation != _generation) {
          throw const HttpException('Transcribe startup cancelled');
        }
        if (_exitCode != null) {
          if (RegExp(
            'out of (device )?memory|cudaMalloc',
            caseSensitive: false,
          ).hasMatch(_log)) {
            throw const FormatException('transcribeOutOfMemory');
          }
          throw ProcessException(executable, [], _log, _exitCode!);
        }
        try {
          final request = await client.getUrl(Uri.parse('$_base/ready'));
          final response = await request.close().timeout(
            const Duration(seconds: 2),
          );
          final body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 2));
          if (response.statusCode == 200) {
            final ready = jsonDecode(body);
            if (ready is Map && ready['ready'] == true) {
              backend = 'GPU · CUDA · NeMo-Speech.cpp';
              return;
            }
          }
        } on SocketException {
          // The server is still loading the model.
        } on TimeoutException {
          // Keep the startup deadline bounded even for a stalled server.
        } on HttpException {
          if (generation != _generation) rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      throw TimeoutException(
        'Transcribe model startup exceeded 10 minutes. $_log',
      );
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<String> transcribe(Uint8List wave, String language) async =>
      (await _request(wave, language, timed: false)).text;

  @override
  Future<TimedTranscript> transcribeTimed(Uint8List wave, String language) =>
      _request(wave, language, timed: true);

  Future<TimedTranscript> _request(
    Uint8List wave,
    String language, {
    required bool timed,
  }) async {
    if (_process == null || _client == null || _exitCode != null) {
      throw StateError('Transcribe is not running. $_log');
    }
    final boundary = 'altranscribe-${DateTime.now().microsecondsSinceEpoch}';
    final head = StringBuffer();
    void field(String name, String value) => head.write(
      '--$boundary\r\nContent-Disposition: form-data; name="$name"\r\n\r\n$value\r\n',
    );
    // Without a language the model works it out itself.
    if (language != 'auto') field('language', language.split('-').first);
    field('response_format', timed ? 'verbose_json' : 'json');
    if (timed) field('timestamp_granularities[]', 'word');
    head.write(
      '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n',
    );
    // An hour of audio is a hundred megabytes: it goes out between the
    // form's parts as it is, not copied into one body first.
    final opening = utf8.encode(head.toString());
    final closing = utf8.encode('\r\n--$boundary--\r\n');
    final request = await _client!.postUrl(
      Uri.parse('$_base/v1/audio/transcriptions'),
    );
    request.headers
      ..set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      )
      ..set(HttpHeaders.authorizationHeader, 'Bearer $_key');
    request.contentLength = opening.length + wave.length + closing.length;
    request
      ..add(opening)
      ..add(wave)
      ..add(closing);
    try {
      // An hour of audio is one request.
      final response = await request.close().timeout(
        const Duration(minutes: 30),
      );
      final result = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('Transcribe ${response.statusCode}: $result');
      }
      return decodeTranscript(
        jsonDecode(result) as Map<String, dynamic>,
        language,
      );
    } catch (_) {
      request.abort();
      rethrow;
    }
  }

  /// The text and, with `verbose_json`, its words in milliseconds.
  static TimedTranscript decodeTranscript(
    Map<String, dynamic> result,
    String language,
  ) {
    final text = result['text'];
    if (text is! String) {
      throw const FormatException('Transcribe response has no text');
    }
    int ms(Object? seconds) => seconds is num
        ? (seconds * 1000).round()
        : throw const FormatException('Invalid Transcribe word time');
    // Words only place sentences in time; their script does not matter.
    final words = [
      for (final word in result['words'] as List? ?? const [])
        if (word is Map && word['word'] is String)
          TimedWord(word['word'] as String, ms(word['start']), ms(word['end'])),
    ];
    return TimedTranscript(
      normalizeChineseScript(text.trim(), language),
      words,
    );
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

/// The free memory nvidia-smi reports for the first GPU.
Future<int?> nvidiaFreeMemory() => _nvidiaMemory('free');

/// The first GPU's total memory.
Future<int?> nvidiaTotalMemory() => _nvidiaMemory('total');

Future<int?> _nvidiaMemory(String field) async {
  try {
    final result = await Process.run('nvidia-smi', [
      '--query-gpu=memory.$field',
      '--format=csv,noheader,nounits',
    ]).timeout(const Duration(seconds: 5));
    if (result.exitCode != 0) return null;
    final mebibytes = int.tryParse(
      (result.stdout as String).trim().split(RegExp(r'\s+')).first,
    );
    return mebibytes == null ? null : mebibytes * 1048576;
  } on Object {
    return null;
  }
}
