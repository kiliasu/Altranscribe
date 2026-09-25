import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/cloud/credential_store.dart';

/// One cancellable cloud operation. Endpoints are fixed to the provider;
/// test clients can redirect the transport without changing production URLs.
class CloudApi {
  CloudApi(this.credentials, {HttpClient Function()? clientFactory})
    : clientFactory = clientFactory ?? HttpClient.new;
  final CredentialStore credentials;
  final HttpClient Function() clientFactory;
  HttpClient? _client;
  CloudProvider? _provider;
  String _key = '';
  int _generation = 0;

  Future<void> prepare(CloudProvider provider) async {
    close();
    final generation = _generation;
    final key = await credentials.read(provider);
    if (generation != _generation) throw StateError('cloudCancelled');
    if (key.isEmpty) throw StateError('cloudKeyMissing');
    _provider = provider;
    _key = key;
    _client = clientFactory()..connectionTimeout = const Duration(seconds: 15);
  }

  Future<HttpClientResponse> send(
    String method,
    String path, {
    Object? body,
    Uint8List? bytes,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final client = _client;
    final provider = _provider;
    if (client == null || provider == null) throw StateError('cloudCancelled');
    final uri = provider.base.resolve(path);
    // Upload URLs are server supplied. Never forward an API key off-provider.
    if (uri.scheme != 'https' ||
        uri.host != provider.base.host ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      throw StateError('cloudInvalidEndpoint');
    }
    HttpClientRequest? request;
    try {
      request = await client.openUrl(method, uri).timeout(timeout);
      request.followRedirects = false;
      switch (provider) {
        case CloudProvider.openAI:
          request.headers.set('Authorization', 'Bearer $_key');
        case CloudProvider.gemini:
          request.headers.set('x-goog-api-key', _key);
        case CloudProvider.anthropic:
          request.headers.set('x-api-key', _key);
          request.headers.set('anthropic-version', '2023-06-01');
      }
      headers.forEach(request.headers.set);
      if (bytes != null) {
        request.contentLength = bytes.length;
        request.add(bytes);
      } else if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>().timeout(const Duration(seconds: 5));
        throw StateError('cloudHttp${response.statusCode}');
      }
      return response;
    } on StateError {
      rethrow;
    } catch (_) {
      request?.abort();
      // Exception URLs, response bodies, and close reasons can contain secrets.
      throw StateError('cloudConnectionFailed');
    }
  }

  Future<Map<String, dynamic>> json(
    String method,
    String path, {
    Object? body,
    Uint8List? bytes,
    Map<String, String> headers = const {},
  }) async {
    final response = await send(
      method,
      path,
      body: body,
      bytes: bytes,
      headers: headers,
    );
    try {
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(minutes: 5));
      if (text.isEmpty) return {};
      final data = jsonDecode(text) as Map<String, dynamic>;
      if (data['error'] != null) throw StateError('cloudResponseFailed');
      return data;
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('cloudInvalidResponse');
    }
  }

  Future<List<String>> models(CloudProvider provider) async {
    await prepare(provider);
    final result = <String>[];
    if (provider == CloudProvider.anthropic) {
      String? after;
      do {
        final data = await json(
          'GET',
          '/v1/models?limit=1000${after == null ? '' : '&after_id=${Uri.encodeQueryComponent(after)}'}',
        );
        final items = data['data'];
        if (items is! List) throw StateError('cloudInvalidResponse');
        result.addAll(items.map((item) => item['id'] as String));
        after = data['has_more'] == true ? data['last_id'] as String? : null;
      } while (after != null && after.isNotEmpty);
      return result.toSet().toList()..sort();
    }
    String? page;
    do {
      final data = await json(
        'GET',
        provider == CloudProvider.openAI
            ? '/v1/models'
            : '/v1beta/models?pageSize=1000${page == null ? '' : '&pageToken=${Uri.encodeQueryComponent(page)}'}',
      );
      final items = data[provider == CloudProvider.openAI ? 'data' : 'models'];
      if (items is! List) throw StateError('cloudInvalidResponse');
      result.addAll(
        items.map(
          (item) =>
              (item[provider == CloudProvider.openAI ? 'id' : 'name'] as String)
                  .replaceFirst(RegExp(r'^models/'), ''),
        ),
      );
      page = data['nextPageToken'] as String?;
    } while (page != null && page.isNotEmpty);
    return result.toSet().toList()..sort();
  }

  void close() {
    _generation++;
    _client?.close(force: true);
    _client = null;
    _key = '';
  }
}

/// REST Interactions output is nested in model-output steps, not SDK output_text.
String interactionText(Map<String, dynamic> response) {
  if (response['status'] != 'completed') {
    throw StateError('cloudIncomplete');
  }
  final text = StringBuffer();
  for (final step in response['steps'] as List? ?? []) {
    if (step['type'] != 'model_output') continue;
    for (final content in step['content'] as List? ?? []) {
      if (content['type'] == 'text' && content['text'] is String) {
        text.write(content['text']);
      }
    }
  }
  return text.toString().trim();
}
