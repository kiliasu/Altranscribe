import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/remote/discovery.dart';
import 'package:altranscribe/data/services/remote/paired_devices.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';

class SharedHost extends ChangeNotifier {
  SharedHost({
    required this.engine,
    required this.translator,
    PairedDevices? devices,
    TranslationService Function()? createTranslator,
  }) : devices = devices ?? PairedDevices(),
       _createTranslator = createTranslator ?? LocalLlmService.new;
  final SpeechEngine engine;

  /// Serves the host's own model; other listed models get their own service.
  final TranslationService translator;
  final TranslationService Function() _createTranslator;
  final _extraTranslators = <String, Future<TranslationService>>{};
  String _llmAddress = '';
  LlmProvider _llmProvider = LlmProvider.ollama;

  /// Who may connect; pairing codes and revocation live here.
  final PairedDevices devices;
  final discovery = DiscoveryResponder();
  HttpServer? _server;
  bool busy = false;
  bool _disposed = false;
  String? error;

  /// Set when the LAN discovery port could not be opened; sharing still works
  /// by address.
  bool discoveryUnavailable = false;
  String address = '';

  /// The address and port this host listens on, which challenge proofs are
  /// bound to; never taken from a request, which anyone could have relayed.
  String _endpoint = '';
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
      var llmModels = const <String>[];
      if (shareTranslation) {
        LocalLlmService.serviceAddress(llmAddress, llmProvider);
        await translator.prepare(llmAddress, llmModel, provider: llmProvider);
        _llmAddress = llmAddress;
        _llmProvider = llmProvider;
        // Clients may pick any model the service lists; the host's own
        // choice stays the default.
        try {
          final listed = await translator.models(
            llmAddress,
            provider: llmProvider,
          );
          llmModels = [llmModel, ...listed.where((item) => item != llmModel)];
        } catch (_) {
          llmModels = [llmModel];
        }
      }
      await engine.start(executable, model, directory, compute: compute);
      if (_disposed) throw const FormatException('remoteCancelled');
      final server = await HttpServer.bind(bindAddress, port);
      if (_disposed) {
        await server.close(force: true);
        throw const FormatException('remoteCancelled');
      }
      server.idleTimeout = const Duration(seconds: 30);
      _endpoint = PairedDevices.endpoint(bindAddress, server.port);
      _server = server;
      await devices.load();
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
        'llmModels': llmModels,
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
      try {
        await discovery.start(describe);
        discoveryUnavailable = false;
      } catch (_) {
        discoveryUnavailable = true;
      }
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

  /// What discovery answers with; the address is where clients connect.
  Map<String, Object?> describe() => {
    'id': devices.hostId,
    'name': info['name'],
    'address': address,
    'busy': pending > 0,
  };

  static bool _privatePeer(HttpRequest request) {
    final peer = request.connectionInfo?.remoteAddress;
    return peer != null && privateAddress(peer);
  }

  PairedDevice? _authorized(HttpRequest request) {
    if (!_privatePeer(request)) return null;
    final supplied =
        request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!supplied.startsWith('Bearer ')) return null;
    return devices.authorize(supplied.substring(7));
  }

  /// Trades a pairing code for a device token. Wrong codes answer 403 and
  /// count against the code, which closes after a few guesses.
  Future<void> _pair(HttpRequest request, HttpResponse response) async {
    final data = await boundedBytes(
      request,
      4096,
    ).timeout(const Duration(seconds: 30));
    final json = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(data)) as Map,
    );
    final code = json['code'] as String;
    final name = json['name'] as String? ?? '';
    final platform = json['platform'] as String? ?? '';
    final paired = await devices.pair(code, name, platform: platform);
    if (paired == null) {
      response.statusCode = 403;
      return;
    }
    response.write(
      jsonEncode({
        'token': paired.token,
        'deviceId': paired.device.id,
        'hostId': devices.hostId,
        'name': info['name'],
      }),
    );
  }

  /// Answers a client's nonce with one keyed hash per paired device, bound
  /// to this host's own endpoint, so the client can confirm the machine it
  /// dialled holds its credential before sending it.
  void _challenge(HttpRequest request, HttpResponse response) {
    final nonce = request.uri.queryParameters['nonce'] ?? '';
    if (!PairedDevices.noncePattern.hasMatch(nonce)) {
      response.statusCode = 400;
      return;
    }
    response.write(
      jsonEncode({
        'hostId': devices.hostId,
        'proofs': devices.proofs(nonce, _endpoint),
      }),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.persistentConnection = false;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      final browser = request.headers.value('origin') != null;
      final pairing =
          request.method == 'POST' && request.uri.path == '/v1/pair';
      final challenge =
          request.method == 'GET' && request.uri.path == '/v1/challenge';
      final open = !browser && (pairing || challenge) && _privatePeer(request);
      final device = browser || pairing || challenge
          ? null
          : _authorized(request);
      if (open && challenge) {
        _challenge(request, response);
      } else if (open && pairing) {
        await _pair(request, response);
      } else if (device == null) {
        response.statusCode = 401;
      } else if (request.method == 'GET' && request.uri.path == '/v1/info') {
        response.write(
          jsonEncode({
            ...info,
            'hostId': devices.hostId,
            'busy': pending > 0,
            'device': device.name,
          }),
        );
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

  /// A prepared service for one of the other listed models, made on first use.
  Future<TranslationService> _translatorFor(String model) =>
      _extraTranslators[model] ??= () async {
        final service = _createTranslator();
        try {
          await service.prepare(_llmAddress, model, provider: _llmProvider);
        } catch (_) {
          service.stop();
          _extraTranslators.remove(model);
          rethrow;
        }
        return service;
      }();

  Future<Map<String, Object?>> _text(
    String operation,
    Map<String, dynamic> data,
  ) async {
    var service = translator;
    final requested = data['model'];
    if (requested != null && requested != '') {
      final listed = info['llmModels'] as List? ?? const [];
      if (requested is! String || !listed.contains(requested)) {
        throw const FormatException('remoteInvalidRequest');
      }
      if (requested != info['llmModel']) {
        service = await _translatorFor(requested);
      }
    }
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
        'text': await service.translate(
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
      final result = await service.summarize(texts, language);
      return {'title': result.title, 'summary': result.summary};
    }
    final values = data['options'] as Map;
    final options = CleanupOptions(
      names: values['names'] == true,
      terms: values['terms'] == true,
      corrections: values['corrections'] == true,
      spellings: (values['spellings'] as List? ?? []).cast<String>(),
    );
    final result = await service.cleanUp(texts, options);
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
    discovery.stop();
    devices.cancelPairing();
    try {
      await server?.close(force: true);
      translator.stop();
      for (final pending in _extraTranslators.values) {
        unawaited(
          pending.then((service) => service.stop(), onError: (Object _) {}),
        );
      }
      _extraTranslators.clear();
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
