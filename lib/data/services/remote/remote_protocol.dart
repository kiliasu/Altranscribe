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

/// What the last health check of the saved host found.
enum HostStatus { unknown, offline, online, busy }

class RemoteConnection {
  RemoteConnection({
    this.address = '',
    this.token = '',
    this.name = '',
    this.hostId = '',
  });
  String address, token, name, hostId;
  Map<String, dynamic>? info;
}

/// What a host's pairing QR code carries: where to reach it and a one-time
/// code, as `altranscribe://pair?v=1&address=…&code=…&name=…&id=…`.
class PairingInvite {
  const PairingInvite({
    required this.address,
    required this.code,
    this.name = '',
    this.hostId = '',
  });
  final String address, code, name, hostId;
  static final codePattern = RegExp(r'^\d{6}$');

  Uri toUri() => Uri(
    scheme: 'altranscribe',
    host: 'pair',
    queryParameters: {
      'v': '1',
      'address': address,
      'code': code,
      if (name.isNotEmpty) 'name': name,
      if (hostId.isNotEmpty) 'id': hostId,
    },
  );

  static PairingInvite parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'altranscribe' || uri.host != 'pair') {
      throw const FormatException('pairingQrInvalid');
    }
    final query = uri.queryParameters;
    final code = query['code'] ?? '';
    if (!codePattern.hasMatch(code)) {
      throw const FormatException('pairingQrInvalid');
    }
    return PairingInvite(
      address: remoteUri(query['address'] ?? '').toString(),
      code: code,
      name: (query['name'] ?? '').trim(),
      hostId: (query['id'] ?? '').trim(),
    );
  }
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

  /// Resolves the host to one validated private address and opens a client
  /// pinned to it; redirects and proxies are never followed.
  Future<void> _open() async {
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
    // MagicDNS may return both families; the sharing panel usually binds IPv4.
    final address =
        addresses
            .where((item) => item.type == InternetAddressType.IPv4)
            .firstOrNull ??
        addresses.first;
    _base = uri.replace(host: address.address);
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';
  }

  Future<Map<String, dynamic>> connect() async {
    if (connection.token.trim().length < 32) {
      throw const FormatException('remoteUnauthorized');
    }
    await _open();
    _token = connection.token.trim();
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
      if (info['hostId'] is String) {
        connection.hostId = info['hostId'] as String;
      }
      return info;
    } catch (_) {
      close();
      rethrow;
    }
  }

  /// Exchanges a pairing code for this device's own token. The host learns
  /// the device name it shows in its paired list.
  Future<Map<String, dynamic>> pair(
    String code,
    String deviceName,
    String platform,
  ) async {
    await _open();
    try {
      final result = await request(
        'pair',
        json: {'code': code.trim(), 'name': deviceName, 'platform': platform},
        timeout: const Duration(seconds: 15),
      );
      final token = result['token'];
      if (token is! String ||
          token.length < 32 ||
          result['hostId'] is! String) {
        throw const FormatException('remoteIncompatible');
      }
      return result;
    } finally {
      close();
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
      if (_token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      }
      request.headers.contentType = ContentType.parse(
        wave == null ? 'application/json' : 'audio/wav',
      );
      if (wave != null) request.add(wave);
      if (json != null) request.add(utf8.encode(jsonEncode(json)));
      final response = await request.close().timeout(timeout);
      final bytes = await boundedBytes(response, 2 * 1024 * 1024);
      if (response.statusCode != 200) {
        throw FormatException(switch (response.statusCode) {
          // Hosts before 0.6.2 answer every unauthenticated request with 401.
          401 when operation == 'pair' => 'pairingUnsupported',
          401 => 'remoteUnauthorized',
          403 when operation == 'pair' => 'pairingCodeInvalid',
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
