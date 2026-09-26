import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// A client that may use this host. Only a hash of its token is kept, so the
/// registry file never reveals a usable credential.
class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required this.tokenHash,
    required this.pairedAt,
    this.platform = '',
    this.lastSeen,
  });
  final String id;
  final String name;
  final String tokenHash;
  final DateTime pairedAt;
  final String platform;
  DateTime? lastSeen;

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    tokenHash: json['tokenHash'] as String,
    pairedAt: DateTime.parse(json['pairedAt'] as String),
    platform: json['platform'] as String? ?? '',
    lastSeen: json['lastSeen'] == null
        ? null
        : DateTime.parse(json['lastSeen'] as String),
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'tokenHash': tokenHash,
    'pairedAt': pairedAt.toIso8601String(),
    'platform': platform,
    'lastSeen': lastSeen?.toIso8601String(),
  };
}

/// The host's pairing registry: a stable host identity, the devices that may
/// connect, and one short-lived pairing code at a time.
class PairedDevices extends ChangeNotifier {
  PairedDevices({this.file});

  /// Where the registry persists; null keeps it in memory (tests, phones).
  final File? file;
  static const codeLifetime = Duration(minutes: 10);
  static const codeAttempts = 5;
  static const nameLimit = 80;
  String hostId = '';
  final devices = <PairedDevice>[];
  String? _code;
  DateTime? _codeExpiry;
  int _failedAttempts = 0;
  DateTime? _seenSaved;
  bool _loaded = false;
  bool _disposed = false;

  String? get pairingCode =>
      _code != null && DateTime.now().isBefore(_codeExpiry!) ? _code : null;
  DateTime? get pairingExpiry => pairingCode == null ? null : _codeExpiry;

  /// Synchronous file access on purpose: the registry is tiny, and callers
  /// such as widget tests may run where asynchronous I/O never completes.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final target = file;
    if (target != null && target.existsSync()) {
      try {
        final json = jsonDecode(target.readAsStringSync()) as Map;
        hostId = json['hostId'] as String? ?? '';
        devices
          ..clear()
          ..addAll(
            (json['devices'] as List? ?? []).map(
              (item) => PairedDevice.fromJson(Map<String, dynamic>.from(item)),
            ),
          );
      } catch (_) {
        // A damaged registry only loses pairings; the host stays usable.
      }
    }
    if (hostId.isEmpty) {
      hostId = randomToken(12);
      _save();
    }
  }

  void _save() {
    final target = file;
    if (target == null) return;
    final snapshot = const JsonEncoder.withIndent('  ').convert({
      'hostId': hostId,
      'devices': [for (final device in devices) device.toJson()],
    });
    final temporary = File('${target.path}.tmp');
    try {
      temporary.writeAsStringSync(snapshot, flush: true);
      temporary.renameSync(target.path);
    } on FileSystemException {
      // A read-only or missing folder keeps the registry in memory only.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Opens a pairing window and returns its six-digit code.
  String beginPairing() {
    final random = Random.secure();
    _code = List.generate(6, (_) => random.nextInt(10)).join();
    _codeExpiry = DateTime.now().add(codeLifetime);
    _failedAttempts = 0;
    _notify();
    return _code!;
  }

  void cancelPairing() {
    _code = null;
    _codeExpiry = null;
    _notify();
  }

  static String sanitizeName(String name, String fallback) {
    final trimmed = name.trim().replaceAll(RegExp(r'[\u0000-\u001f]'), '');
    if (trimmed.isEmpty) return fallback;
    return trimmed.length > nameLimit
        ? trimmed.substring(0, nameLimit)
        : trimmed;
  }

  /// Exchanges a current code for a new device token; null when the code is
  /// wrong. Too many wrong guesses close the pairing window.
  Future<({String token, PairedDevice device})?> pair(
    String code,
    String name, {
    String platform = '',
  }) async {
    final current = pairingCode;
    if (current == null) return null;
    if (!constantTimeEquals(code.trim(), current)) {
      if (++_failedAttempts >= codeAttempts) cancelPairing();
      return null;
    }
    final result = await create(name, platform: platform);
    _code = null;
    _codeExpiry = null;
    _notify();
    return result;
  }

  /// Registers a device directly, for host-side tooling and tests.
  Future<({String token, PairedDevice device})> create(
    String name, {
    String platform = '',
  }) async {
    final token = randomToken(32);
    final device = PairedDevice(
      id: randomToken(12),
      name: sanitizeName(name, 'Device'),
      tokenHash: hash(token),
      pairedAt: DateTime.now(),
      platform: platform == 'android' || platform == 'windows' ? platform : '',
    );
    devices.add(device);
    _save();
    _notify();
    return (token: token, device: device);
  }

  /// The device owning [token], if any; a match also counts as a sighting.
  PairedDevice? authorize(String token) {
    if (token.trim().length < 32) return null;
    final supplied = hash(token.trim());
    PairedDevice? match;
    for (final device in devices) {
      // Every registered hash is compared so timing never reveals which one matched.
      if (constantTimeEquals(supplied, device.tokenHash)) match = device;
    }
    if (match != null) {
      match.lastSeen = DateTime.now();
      _notify();
      if (_seenSaved == null ||
          DateTime.now().difference(_seenSaved!) > const Duration(minutes: 1)) {
        _seenSaved = DateTime.now();
        _save();
      }
    }
    return match;
  }

  Future<void> revoke(String id) async {
    devices.removeWhere((device) => device.id == id);
    _save();
    _notify();
  }

  static String hash(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  /// Hex nonces of 16 to 32 bytes, as clients send them.
  static final noncePattern = RegExp(r'^[0-9a-f]{32,64}$');

  /// Proves this host holds its devices' credentials without revealing them:
  /// one keyed hash per device over the caller's nonce. A client checks for
  /// the proof of its own token before sending that token anywhere.
  List<String> proofs(String nonce) => [
    for (final device in devices) proof(device.tokenHash, nonce),
  ];
  static String proof(String tokenHash, String nonce) => Hmac(
    sha256,
    utf8.encode(tokenHash),
  ).convert(utf8.encode(nonce)).toString();

  static String randomToken(int bytes) {
    final random = Random.secure();
    return base64UrlEncode(List.generate(bytes, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static bool constantTimeEquals(String a, String b) {
    var difference = a.length ^ b.length;
    for (var i = 0; i < b.length; i++) {
      difference |= b.codeUnitAt(i) ^ (i < a.length ? a.codeUnitAt(i) : 0);
    }
    return difference == 0;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
