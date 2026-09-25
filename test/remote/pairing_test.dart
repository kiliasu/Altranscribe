import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/services/remote/discovery.dart';
import 'package:altranscribe/data/services/remote/paired_devices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'pairing codes expire, limit guesses and mint one token per device',
    () async {
      final registry = PairedDevices();
      await registry.load();
      expect(registry.hostId.length, greaterThanOrEqualTo(16));
      expect(registry.pairingCode, isNull);
      final code = registry.beginPairing();
      expect(code, matches(RegExp(r'^\d{6}$')));
      expect(registry.pairingExpiry!.isAfter(DateTime.now()), isTrue);
      expect(await registry.pair('000000', 'Phone'), isNull);
      final paired = await registry.pair(
        ' $code ',
        '  My phone  ',
        platform: 'android',
      );
      expect(paired, isNotNull);
      expect(paired!.device.name, 'My phone');
      expect(paired.device.platform, 'android');
      expect(paired.token.length, greaterThanOrEqualTo(32));
      expect(registry.pairingCode, isNull, reason: 'a code is single use');
      expect(await registry.pair(code, 'Again'), isNull);
      expect(registry.authorize(paired.token)?.id, paired.device.id);
      expect(registry.authorize('${paired.token}x'), isNull);
      expect(registry.authorize(''), isNull);
      expect(registry.devices.single.lastSeen, isNotNull);

      final second = registry.beginPairing();
      for (var i = 0; i < PairedDevices.codeAttempts; i++) {
        expect(await registry.pair('999999', 'Guess'), isNull);
      }
      expect(
        registry.pairingCode,
        isNull,
        reason: 'guessing closes the window',
      );
      expect(await registry.pair(second, 'Late'), isNull);

      await registry.revoke(paired.device.id);
      expect(registry.devices, isEmpty);
      expect(registry.authorize(paired.token), isNull);
    },
  );

  test('registry persists hashes only and survives reloads', () async {
    final directory = await Directory.systemTemp.createTemp(
      'altranscribe-pairing',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/devices.json');
    final registry = PairedDevices(file: file);
    await registry.load();
    final created = await registry.create('Laptop', platform: 'windows');
    final text = await file.readAsString();
    expect(text, isNot(contains(created.token)));
    expect(text, contains(PairedDevices.hash(created.token)));
    expect(text, contains(registry.hostId));

    final reloaded = PairedDevices(file: file);
    await reloaded.load();
    expect(reloaded.hostId, registry.hostId);
    expect(reloaded.devices.single.name, 'Laptop');
    expect(reloaded.authorize(created.token)?.platform, 'windows');

    await file.writeAsString('{broken');
    final damaged = PairedDevices(file: file);
    await damaged.load();
    expect(damaged.devices, isEmpty);
    expect(damaged.hostId, isNotEmpty);
    expect(
      PairedDevices.sanitizeName('\u0001 x' * 60, 'Device').length,
      PairedDevices.nameLimit,
    );
  });

  test(
    'discovery answers probes on loopback and rejects forged answers',
    () async {
      final responder = DiscoveryResponder();
      var busy = false;
      await responder.start(
        () => {
          'id': 'host-1',
          'name': 'Study PC',
          'address': 'http://127.0.0.1:8178',
          'busy': busy,
        },
      );
      addTearDown(responder.stop);
      final hosts = await discoverHosts(
        targets: [InternetAddress.loopbackIPv4],
        timeout: const Duration(milliseconds: 600),
      );
      expect(hosts.map((host) => host.id), ['host-1']);
      expect(hosts.single.name, 'Study PC');
      expect(hosts.single.address, 'http://127.0.0.1:8178');
      expect(hosts.single.busy, isFalse);
      busy = true;
      final again = await discoverHosts(
        targets: [InternetAddress.loopbackIPv4],
        timeout: const Duration(milliseconds: 600),
      );
      expect(again.single.busy, isTrue);
      responder.stop();
      expect(
        await discoverHosts(
          targets: [InternetAddress.loopbackIPv4],
          timeout: const Duration(milliseconds: 400),
        ),
        isEmpty,
      );

      DiscoveredHost? parse(
        Map<String, Object?> json, [
        String from = '192.168.1.5',
      ]) =>
          parseDiscovery(utf8.encode(jsonEncode(json)), InternetAddress(from));
      final valid = {
        'altranscribe': 1,
        'id': 'h',
        'name': 'Desk',
        'address': 'http://192.168.1.5:8178',
        'busy': false,
      };
      expect(parse(valid)?.name, 'Desk');
      expect(
        parse({...valid, 'address': 'http://192.168.1.9:8178'}),
        isNull,
        reason: 'address must match the sender',
      );
      expect(parse({...valid, 'address': 'https://192.168.1.5:8178'}), isNull);
      expect(
        parse({...valid, 'address': 'http://8.8.8.8:8178'}, '8.8.8.8'),
        isNull,
      );
      expect(parse({...valid, 'address': 'http://example.com:8178'}), isNull);
      expect(parse({...valid, 'altranscribe': 2}), isNull);
      expect(parse({...valid, 'id': ''}), isNull);
      expect(parse({...valid, 'name': '   '})?.name, '192.168.1.5');
      expect(
        parseDiscovery(utf8.encode('nonsense'), InternetAddress('192.168.1.5')),
        isNull,
      );
    },
  );
}
