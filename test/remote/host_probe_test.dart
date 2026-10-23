import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/services/remote/paired_devices.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:altranscribe/data/services/remote/shared_host.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../cloud/cloud_test.dart' show MemoryCredentials;
import '../support/fakes.dart';
import 'remote_test.dart' show startHost;

/// Keeps the last settings the controller saved.
class SettingsStore extends MemoryStore {
  Map<String, Object?> saved = {};
  @override
  Future<void> saveSettings(Map<String, Object?> value) async =>
      saved = Map.of(value);
}

/// A paired host that proves itself at once but holds its details until
/// [release] completes, like one answering slowly over Wi-Fi.
class SlowHost {
  SlowHost._(this.server, this.token, this.models);
  final HttpServer server;
  final String token;
  final List<String> models;
  final asked = Completer<void>();
  final release = Completer<void>();
  String get address => 'http://127.0.0.1:${server.port}';

  static Future<SlowHost> start(
    String token, {
    List<String> models = const ['a-llm'],
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = SlowHost._(server, token, models);
    server.listen(host._answer);
    return host;
  }

  Future<void> _answer(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (request.uri.path == '/v1/challenge') {
      final nonce = request.uri.queryParameters['nonce']!;
      final endpoint = PairedDevices.endpoint(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      response.write(
        jsonEncode({
          'hostId': 'host-a',
          'proofs': [
            PairedDevices.proof(PairedDevices.hash(token), nonce, endpoint),
          ],
        }),
      );
    } else {
      if (!asked.isCompleted) asked.complete();
      await release.future;
      response.write(
        jsonEncode({
          'protocol': 1,
          'name': 'Host A',
          'speechProvider': 'whisper',
          'model': 'ggml-a.bin',
          'hostId': 'host-a',
          'busy': false,
          'llmProvider': 'ollama',
          'llmModel': models.first,
          'llmModels': models,
        }),
      );
    }
    await response.close();
  }
}

RealtimeController savingController(SettingsStore store) => RealtimeController(
  audio: FakeAudio(),
  engine: FakeEngine(),
  store: store,
  translator: FakeTranslator(),
  recordSummarizer: FakeTranslator(),
  catalog: FakeModelCatalog(),
  credentials: MemoryCredentials(),
)..initialized = true;

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

  test(
    'a probe that answers after the host changed cannot rewrite the new one',
    () async {
      final slow = await SlowHost.start('a' * 43);
      addTearDown(() => slow.server.close(force: true));
      final host = SharedHost(
        engine: FakeEngine(),
        translator: FakeTranslator(),
      );
      await startHost(host);
      addTearDown(() async {
        await host.stop();
        host.dispose();
      });
      final token = (await host.devices.create('Client')).token;
      final store = SettingsStore();
      final live = savingController(store)..useRemote = true;
      addTearDown(live.dispose);
      live.remoteConnection
        ..address = slow.address
        ..token = slow.token
        ..name = 'Host A'
        ..hostId = 'host-a';

      final stale = live.probeHost(discover: false);
      await slow.asked.future;
      await live.connectRemote(
        host.address,
        token,
        '',
        hostId: host.devices.hostId,
      );
      slow.release.complete();
      await stale;

      expect(live.remoteConnection.address, host.address);
      expect(live.remoteConnection.hostId, host.devices.hostId);
      expect(live.remoteConnection.name, 'Test host');
      expect(live.remoteConnection.info!['hostId'], host.devices.hostId);
      expect(live.hostLlmModel, 'test-llm');
      expect(store.saved['remoteAddress'], host.address);
      expect(store.saved['remoteHostId'], host.devices.hostId);
      expect(store.saved['remoteName'], 'Test host');
      // The next check still recognises the new host.
      await live.probeHost(discover: false);
      expect(live.hostStatus, HostStatus.online);
    },
  );

  test(
    'forgetting the host while a probe is out leaves nothing of it',
    () async {
      final slow = await SlowHost.start('a' * 43);
      addTearDown(() => slow.server.close(force: true));
      final store = SettingsStore();
      final live = savingController(store)..useRemote = true;
      addTearDown(live.dispose);
      live.remoteConnection
        ..address = slow.address
        ..token = slow.token
        ..name = 'Host A'
        ..hostId = 'host-a';

      final stale = live.probeHost(discover: false);
      await slow.asked.future;
      await live.forgetHost();
      slow.release.complete();
      await stale;

      expect(live.remoteConnection.address, isEmpty);
      expect(live.remoteConnection.name, isEmpty);
      expect(live.remoteConnection.hostId, isEmpty);
      expect(live.remoteConnection.info, isNull);
      expect(live.hostStatus, HostStatus.unknown);
      expect(store.saved['remoteName'], '');
      expect(store.saved['remoteHostId'], '');
    },
  );

  test(
    'a connection that answers after a local session started leaves it alone',
    () async {
      final slow = await SlowHost.start('a' * 43);
      addTearDown(() => slow.server.close(force: true));
      final live = savingController(SettingsStore())..useRemote = false;
      addTearDown(live.dispose);
      final connecting = live.connectRemote(
        slow.address,
        slow.token,
        '',
        hostId: 'host-a',
      );
      await slow.asked.future;
      await live.start(microphone: true, system: false, language: 'en');
      slow.release.complete();
      await expectLater(
        connecting,
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'recordBusy'),
        ),
      );
      expect(live.useRemote, isFalse);
      expect(live.remoteConnection.address, isEmpty);
      expect(await live.credentials.readNamed('remote-host'), isEmpty);
      // The session keeps transcribing with its own engine.
      (live.audio as FakeAudio).events.add(chunk('microphone', 0));
      for (var i = 0; i < 600 && live.record!.lines.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(live.record!.lines, isNotEmpty);
      expect(live.error, isNull);
      await live.stop();
    },
  );

  test('a connection given up while it waits changes nothing', () async {
    final slow = await SlowHost.start('a' * 43);
    addTearDown(() => slow.server.close(force: true));
    final store = SettingsStore();
    final live = savingController(store);
    addTearDown(live.dispose);
    final connecting = live.connectRemote(
      slow.address,
      slow.token,
      '',
      hostId: 'host-a',
    );
    await slow.asked.future;
    live.cancelHostConnection();
    slow.release.complete();
    await expectLater(
      connecting,
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'remoteCancelled',
        ),
      ),
    );
    expect(live.remoteConnection.address, isEmpty);
    expect(store.saved, isEmpty);
    expect(await live.credentials.readNamed('remote-host'), isEmpty);
  });

  test('a text model chosen on one host is not carried to another', () async {
    final first = await SlowHost.start('a' * 43, models: ['a-llm', 'a-large']);
    first.release.complete();
    addTearDown(() => first.server.close(force: true));
    final second = SharedHost(
      engine: FakeEngine(),
      translator: FakeTranslator(),
    );
    await startHost(second);
    addTearDown(() async {
      await second.stop();
      second.dispose();
    });
    final token = (await second.devices.create('Client')).token;
    final store = SettingsStore();
    final live = savingController(store);
    addTearDown(live.dispose);
    await live.connectRemote(first.address, first.token, '', hostId: 'host-a');
    live.remoteLlmModel = 'a-large';
    // Connecting to the same host again keeps a choice it still offers.
    await live.connectRemote(first.address, first.token, '', hostId: 'host-a');
    expect(live.remoteLlmModel, 'a-large');
    await live.connectRemote(
      second.address,
      token,
      '',
      hostId: second.devices.hostId,
    );
    expect(live.remoteLlmModel, isEmpty);
    expect(store.saved['remoteLlmModel'], '');
    expect(live.sessionLlmModel, 'test-llm');
    live.remoteLlmModel = 'test-llm';
    await live.forgetHost();
    expect(store.saved['remoteLlmModel'], '');
  });
}
