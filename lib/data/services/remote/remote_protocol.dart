import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Only LAN, Tailscale's CGNAT space, and loopback for same-machine testing.
bool privateAddress(InternetAddress address) {
  if (address.isLoopback) return true;
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }
  return b[0] & 0xfe == 0xfc; // ULA, including Tailscale fd7a:115c:a1e0::/48.
}

Future<List<(String, InternetAddress)>> sharingAddresses() async => [
  for (final network in await NetworkInterface.list())
    for (final address in network.addresses)
      if (privateAddress(address) && !address.isLoopback)
        (network.name, address),
];

Uri remoteUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'http' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !['', '/'].contains(uri.path) ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw const FormatException('remoteAddressInvalid');
  }
  return uri.replace(path: '');
}

Future<Uint8List> boundedBytes(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('remotePayloadTooLarge');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

class RemoteConnection {
  RemoteConnection({this.address = '', this.token = '', this.name = ''});
  String address, token, name;
  Map<String, dynamic>? info;
}

/// Each ASR/LLM consumer owns its connection, so cancelling one never cancels
/// another or sends a shutdown request to the host.
class RemoteClient {
  RemoteClient(this.connection);
  final RemoteConnection connection;
  HttpClient? _client;
  Uri? _base;
  String _token = '';
  int _generation = 0;

  Future<Map<String, dynamic>> connect() async {
    close();
    final generation = _generation;
    final uri = remoteUri(connection.address);
    final addresses =
        await InternetAddress.lookup(uri.host.replaceAll(RegExp(r'[\[\]]'), ''))
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw const FormatException('remoteUnavailable'),
            );
    if (addresses.isEmpty ||
        addresses.any((address) => !privateAddress(address))) {
      throw const FormatException('remoteAddressInvalid');
    }
    if (generation != _generation) {
      throw const FormatException('remoteCancelled');
    }
    if (connection.token.trim().length < 32) {
      throw const FormatException('remoteUnauthorized');
    }
    // Pin the validated IP for this session, never follow a redirect or proxy.
    // MagicDNS may return both families; the sharing panel usually binds IPv4.
    final address =
        addresses
            .where((item) => item.type == InternetAddressType.IPv4)
            .firstOrNull ??
        addresses.first;
    _base = uri.replace(host: address.address);
    _token = connection.token.trim();
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';
    try {
      final info = await request('info', timeout: const Duration(seconds: 10));
      if (info['protocol'] != 1 ||
          info['speechProvider'] != 'whisper' ||
          info['model'] is! String ||
          info['name'] is! String ||
          (info['llmProvider'] != null &&
              !['ollama', 'openAICompatible'].contains(info['llmProvider']))) {
        throw const FormatException('remoteIncompatible');
      }
      connection.info = info;
      return info;
    } catch (_) {
      close();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> request(
    String operation, {
    Map<String, Object?>? json,
    Uint8List? wave,
    String? language,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final client = _client;
    if (client == null || _base == null) {
      throw const FormatException('remoteUnavailable');
    }
    HttpClientRequest? request;
    try {
      request = await client
          .openUrl(
            operation == 'info' ? 'GET' : 'POST',
            _base!.replace(
              path: '/v1/$operation',
              queryParameters: language == null ? null : {'language': language},
            ),
          )
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      request.headers.contentType = ContentType.parse(
        wave == null ? 'application/json' : 'audio/wav',
      );
      if (wave != null) request.add(wave);
      if (json != null) request.add(utf8.encode(jsonEncode(json)));
      final response = await request.close().timeout(timeout);
      final bytes = await boundedBytes(response, 2 * 1024 * 1024);
      if (response.statusCode != 200) {
        throw FormatException(switch (response.statusCode) {
          401 => 'remoteUnauthorized',
          429 => 'remoteBusy',
          413 => 'remotePayloadTooLarge',
          503 => 'remoteLlmUnavailable',
          _ => 'remoteRequestFailed',
        });
      }
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('remoteUnavailable');
    } finally {
      request?.abort();
    }
  }

  void close() {
    _generation++;
    _client?.close(force: true);
    _client = null;
    _base = null;
    _token = '';
  }
}
