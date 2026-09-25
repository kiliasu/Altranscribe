import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'remote_protocol.dart';

/// Hosts answer on this UDP port; clients ask from any port.
const discoveryPort = 47653;
const _probe = 'ALTRANSCRIBE-DISCOVER 1';
final _multicastGroup = InternetAddress('239.255.87.1');
final _broadcast = InternetAddress('255.255.255.255');

/// A sharing host seen on the network.
class DiscoveredHost {
  const DiscoveredHost({
    required this.id,
    required this.name,
    required this.address,
    required this.busy,
  });
  final String id;
  final String name;
  final String address;
  final bool busy;
}

/// Answers discovery probes from private addresses while sharing runs.
class DiscoveryResponder {
  RawDatagramSocket? _socket;
  bool get running => _socket != null;

  Future<void> start(Map<String, Object?> Function() describe) async {
    stop();
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    // Multicast is joined per interface where the system allows it.
    try {
      socket.joinMulticast(_multicastGroup);
    } catch (_) {}
    try {
      for (final network in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        try {
          socket.joinMulticast(_multicastGroup, network);
        } catch (_) {}
      }
    } catch (_) {}
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null || !privateAddress(datagram.address)) return;
      if (utf8.decode(datagram.data, allowMalformed: true).trim() != _probe) {
        return;
      }
      final answer = jsonEncode({'altranscribe': 1, ...describe()});
      socket.send(utf8.encode(answer), datagram.address, datagram.port);
    }, onError: (Object _) => stop());
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }
}

/// Broadcasts a probe and collects answers for [timeout]. Hosts are keyed by
/// identity, so a host reachable through two interfaces appears once.
Future<List<DiscoveredHost>> discoverHosts({
  Duration timeout = const Duration(seconds: 2),
  List<InternetAddress>? targets,
  int port = discoveryPort,
}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  final found = <String, DiscoveredHost>{};
  final subscription = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null || !privateAddress(datagram.address)) return;
    final host = parseDiscovery(datagram.data, datagram.address);
    if (host != null) found[host.id] = host;
  });
  final destinations = targets ?? [_broadcast, _multicastGroup];
  try {
    // Two rounds cover a probe lost to a sleepy radio.
    for (var round = 0; round < 2; round++) {
      for (final destination in destinations) {
        try {
          socket.send(utf8.encode(_probe), destination, port);
        } catch (_) {}
      }
      await Future<void>.delayed(timeout ~/ 2);
    }
  } finally {
    await subscription.cancel();
    socket.close();
  }
  return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

/// Validates an answer: the advertised address must be a private HTTP
/// origin, and the host's own address must match where the answer came from.
DiscoveredHost? parseDiscovery(List<int> data, InternetAddress sender) {
  try {
    final json = jsonDecode(utf8.decode(data)) as Map;
    if (json['altranscribe'] != 1) return null;
    final id = json['id'], name = json['name'], address = json['address'];
    if (id is! String || id.isEmpty || id.length > 64) return null;
    if (name is! String || address is! String) return null;
    final uri = remoteUri(address);
    if (InternetAddress.tryParse(uri.host) case final ip?) {
      if (!privateAddress(ip) || ip.address != sender.address) return null;
    } else {
      return null;
    }
    return DiscoveredHost(
      id: id,
      name: name.trim().isEmpty ? uri.host : name.trim(),
      address: uri.toString(),
      busy: json['busy'] == true,
    );
  } catch (_) {
    return null;
  }
}
