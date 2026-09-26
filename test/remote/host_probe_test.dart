import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:altranscribe/data/services/remote/shared_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';
import 'remote_test.dart' show startHost;

void main() {
  test('probing a host refreshes its status, name and shared model', () async {
    final host = SharedHost(engine: FakeEngine(), translator: FakeTranslator());
    await startHost(host);
    addTearDown(() async {
      await host.stop();
      host.dispose();
    });
    final live = fakeController()..useRemote = true;
    addTearDown(live.dispose);
    live.remoteConnection
      ..address = host.address
      ..token = (await host.devices.create('Client')).token
      ..name = 'Old name';
    expect(live.hostStatus, HostStatus.unknown);
    await live.probeHost(discover: false);
    expect(live.hostStatus, HostStatus.online);
    expect(live.hostSeen, isNotNull);
    expect(live.remoteConnection.name, 'Test host');
    expect(live.remoteConnection.hostId, host.devices.hostId);
    expect(live.hostLlmModel, 'test-llm');
    expect(live.sessionLlmModel, 'test-llm');
    expect(host.devices.devices.single.lastSeen, isNotNull);

    await host.stop();
    await live.probeHost(discover: false);
    expect(live.hostStatus, HostStatus.offline);
    expect(
      live.remoteConnection.name,
      'Test host',
      reason: 'kept while offline',
    );
  });
}
