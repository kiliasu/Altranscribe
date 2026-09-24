import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';

class SharedHost extends ChangeNotifier {
  SharedHost({required this.engine, required this.translator});
  final SpeechEngine engine;
  final TranslationService translator;
  HttpServer? _server;
  bool busy = false;
  bool _disposed = false;
  String? error;
  String token = '';
  String address = '';
  Map<String, Object?> info = {};
  final _speech = _HostQueue();
  final _llm = _HostQueue();
  final _requests = <Future<void>>{};
  bool get running => _server != null;
  int get pending => _speech.pending + _llm.pending;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start({
    required InternetAddress bindAddress,
    required int port,
    required String name,
    required String executable,
    required String model,
    required ComputeMode compute,
    required Directory directory,
    required bool shareTranslation,
    required LlmProvider llmProvider,
    required String llmAddress,
    required String llmModel,
  }) async {
    if (Platform.isAndroid) throw const FormatException('mobileRemoteOnly');
    if (busy || running) throw StateError('remoteHostBusy');
    if (!privateAddress(bindAddress) || port < 0 || port > 65535) {
      throw const FormatException('remoteAddressInvalid');
    }
    if (shareTranslation && llmProvider.isCloud) {
      throw const FormatException('remoteLocalOnly');
    }
    busy = true;
    error = null;
    _notify();
    try {
      if (shareTranslation) {
        LocalLlmService.localAddress(llmAddress);
        await translator.prepare(llmAddress, llmModel, provider: llmProvider);
      }
      await engine.start(executable, model, directory, compute: compute);
      if (_disposed) throw const FormatException('remoteCancelled');
      final server = await HttpServer.bind(bindAddress, port);
      if (_disposed) {
        await server.close(force: true);
        throw const FormatException('remoteCancelled');
      }
      server.idleTimeout = const Duration(seconds: 30);
      _server = server;
      final random = Random.secure();
      token = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', '');
      address = Uri(
        scheme: 'http',
        host: bindAddress.address,
        port: server.port,
      ).toString();
      info = {
        'protocol': 1,
        'name': name.trim().isEmpty ? Platform.localHostname : name.trim(),
        'speechProvider': 'whisper',
        'model': model.split(RegExp(r'[/\\]')).last,
        'backend': engine.backend,
        'llmProvider': shareTranslation ? llmProvider.name : null,
        'llmModel': shareTranslation ? llmModel : null,
      };
      server.listen(
        (request) {
          late Future<void> operation;
          operation = _handle(request).whenComplete(() {
            _requests.remove(operation);
            _notify();
          });
          _requests.add(operation);
        },
        onError: (Object _) {
          error = 'remoteHostFailed';
          unawaited(stop());
        },
      );
    } catch (_) {
      error = 'remoteHostFailed';
      translator.stop();
      await engine.stop();
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
  }

  bool _authorized(HttpRequest request) {
    final peer = request.connectionInfo?.remoteAddress;
    if (peer == null || !privateAddress(peer)) return false;
    final supplied =
        request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final expected = 'Bearer $token';
    var difference = supplied.length ^ expected.length;
    for (var i = 0; i < expected.length; i++) {
      difference |=
          expected.codeUnitAt(i) ^
          (i < supplied.length ? supplied.codeUnitAt(i) : 0);
    }
    return difference == 0;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.persistentConnection = false;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      if (!_authorized(request) || request.headers.value('origin') != null) {
        response.statusCode = 401;
      } else if (request.method == 'GET' && request.uri.path == '/v1/info') {
        response.write(jsonEncode(info));
      } else if (request.method != 'POST') {
        response.statusCode = 404;
      } else {
        final speech = request.uri.path == '/v1/transcribe';
        if (!speech &&
            ![
              '/v1/translate',
              '/v1/summarize',
              '/v1/cleanup',
            ].contains(request.uri.path)) {
          response.statusCode = 404;
          return;
        }
        if (!speech && info['llmModel'] == null) {
          response.statusCode = 503;
          return;
        }
        final queue = speech ? _speech : _llm;
        if (queue.pending >= 8 || _requests.length >= 16) {
          response.statusCode = 429;
          return;
        }
        final data = await boundedBytes(
          request,
          speech ? 960044 : 512 * 1024,
        ).timeout(const Duration(seconds: 30));
        if (!running) {
          response.statusCode = 503;
          return;
        }
        final json = speech
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(jsonDecode(utf8.decode(data)) as Map);
        if (speech) validateWave(data);
        final language = speech
            ? request.uri.queryParameters['language'] ?? 'auto'
            : null;
        if (speech) _language(language!);
        final result = await queue.run(() async {
          if (!running) throw const FormatException('remoteCancelled');
          if (speech) {
            return <String, Object?>{
              'text': await engine.transcribe(data, language!),
            };
          }
          return _text(request.uri.path, json);
        });
        response.write(jsonEncode(result));
      }
    } on FormatException catch (e) {
      response.statusCode = switch (e.message) {
        'remotePayloadTooLarge' => 413,
        'remoteBusy' => 429,
        _ => 400,
      };
    } on TypeError {
      response.statusCode = 400;
    } catch (_) {
      response.statusCode = 502;
    } finally {
      // Never log request bodies, audio, keys, or upstream error bodies.
      try {
        await response.close();
      } catch (_) {}
    }
  }

  static void _language(String value) {
    if (!LocalLlmService.languages.containsKey(value)) {
      throw const FormatException('remoteInvalidRequest');
    }
  }

  Future<Map<String, Object?>> _text(
    String operation,
    Map<String, dynamic> data,
  ) async {
    if (operation == '/v1/translate') {
      final text = data['text'] as String;
      final source = data['source'] as String,
          target = data['target'] as String;
      _language(source);
      _language(target);
      final context = (data['context'] as List? ?? [])
          .map(
            (item) => TranslationContext(
              item['original'] as String,
              item['translation'] as String?,
            ),
          )
          .toList();
      return {
        'text': await translator.translate(
          text,
          source,
          target,
          context: TranslationContextPolicy.bound(context),
        ),
      };
    }
    final texts = (data['texts'] as List).cast<String>();
    if (operation == '/v1/summarize') {
      final language = data['language'] as String;
      _language(language);
      final result = await translator.summarize(texts, language);
      return {'title': result.title, 'summary': result.summary};
    }
    final values = data['options'] as Map;
    final options = CleanupOptions(
      names: values['names'] == true,
      terms: values['terms'] == true,
      corrections: values['corrections'] == true,
      spellings: (values['spellings'] as List? ?? []).cast<String>(),
    );
    final result = await translator.cleanUp(texts, options);
    return {
      'edits': [
        for (final edits in result.edits)
          for (final edit in edits) {...edit.toJson(), 'confidence': 'high'},
      ],
    };
  }

  static void validateWave(Uint8List bytes) {
    if (bytes.length < 44 || bytes.length > 960044) {
      throw const FormatException('remoteInvalidAudio');
    }
    final data = ByteData.sublistView(bytes);
    String tag(int start, int end) =>
        String.fromCharCodes(bytes.sublist(start, end));
    if (tag(0, 4) != 'RIFF' ||
        tag(8, 16) != 'WAVEfmt ' ||
        tag(36, 40) != 'data' ||
        data.getUint32(4, Endian.little) != bytes.length - 8 ||
        data.getUint32(16, Endian.little) != 16 ||
        data.getUint16(20, Endian.little) != 1 ||
        data.getUint16(22, Endian.little) != 1 ||
        data.getUint32(24, Endian.little) != 16000 ||
        data.getUint32(28, Endian.little) != 32000 ||
        data.getUint16(32, Endian.little) != 2 ||
        data.getUint16(34, Endian.little) != 16 ||
        data.getUint32(40, Endian.little) != bytes.length - 44 ||
        (bytes.length - 44).isOdd) {
      throw const FormatException('remoteInvalidAudio');
    }
  }

  Future<void> stop() async {
    if (busy) return;
    busy = true;
    _notify();
    final server = _server;
    _server = null;
    token = '';
    try {
      await server?.close(force: true);
      translator.stop();
      await engine.stop();
      await Future.wait(_requests.toList());
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

class _HostQueue {
  Future<void> _tail = Future.value();
  int pending = 0;
  Future<Map<String, Object?>> run(
    Future<Map<String, Object?>> Function() operation,
  ) {
    if (pending >= 8) throw const FormatException('remoteBusy');
    pending++;
    final result = _tail.then((_) => operation());
    _tail = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => pending--);
    return result;
  }
}
