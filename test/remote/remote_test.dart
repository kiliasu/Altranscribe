import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:altranscribe/data/services/remote/remote_services.dart';
import 'package:altranscribe/data/services/remote/shared_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';
import '../files/file_transcription_test.dart' show FileDecoderFake;
import '../transcription/realtime_test.dart' show until;

Future<void> startHost(
  SharedHost host, {
  bool llm = true,
  LlmProvider provider = LlmProvider.ollama,
}) => host.start(
  bindAddress: InternetAddress.loopbackIPv4,
  port: 0,
  name: 'Test host',
  executable: 'test.exe',
  model: 'models/ggml-test.bin',
  compute: ComputeMode.cpu,
  directory: Directory('unused-test-data'),
  shareTranslation: llm,
  llmProvider: provider,
  llmAddress: 'http://127.0.0.1:11434',
  llmModel: 'test-llm',
);

/// A connection for a freshly paired test device.
Future<RemoteConnection> connection(SharedHost host) async =>
    RemoteConnection(address: host.address, token: await pairedToken(host));

Future<String> pairedToken(SharedHost host) async =>
    (await host.devices.create('Test client')).token;

class CancellableEngine extends FakeEngine {
  @override
  Future<void> stop() async {
    await super.stop();
    if (response != null && !response!.isCompleted) {
      response!.completeError(StateError('cancelled'));
    }
  }
}

void main() {
  test('network scope accepts LAN/Tailscale IPv4 and ULA, rejects public and HTTPS', () {
    for (final ip in [
      '10.2.3.4',
      '172.16.0.1',
      '192.168.2.5',
      '100.64.0.1',
      '100.127.255.254',
      'fd7a:115c:a1e0::123',
      '127.0.0.1',
    ]) {
      expect(privateAddress(InternetAddress(ip)), true, reason: ip);
    }
    for (final ip in [
      '8.8.8.8',
      '100.63.255.255',
      '100.128.0.1',
      '172.32.0.1',
      '0.0.0.0',
      '2606:4700::1111',
    ]) {
      expect(privateAddress(InternetAddress(ip)), false, reason: ip);
    }
    for (final address in [
      'https://100.64.1.2:8178',
      'http://user:token@10.0.0.2',
      'http://10.0.0.2/path',
      'http://10.0.0.2?key=x',
    ]) {
      expect(() => remoteUri(address), throwsFormatException);
    }
  });

  test('host authenticates, rejects malformed requests, never exposes cloud models or keys', () async {
    final engine = FakeEngine();
    final translator = FakeTranslator();
    final host = SharedHost(engine: engine, translator: translator);
    addTearDown(() async {
      await host.stop();
      host.dispose();
    });
    await expectLater(
      startHost(host, provider: LlmProvider.openAI),
      throwsFormatException,
    );
    expect(engine.starts, 0);
    await startHost(host);
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    Future<(int, String)> request(
      String path, {
      String? token,
      String? origin,
      List<int>? bytes,
    }) async {
      final req = await http.openUrl(
        bytes == null ? 'GET' : 'POST',
        Uri.parse('${host.address}/v1/$path'),
      );
      if (token != null) req.headers.set('authorization', 'Bearer $token');
      if (origin != null) req.headers.set('origin', origin);
      if (bytes != null) req.add(bytes);
      final response = await req.close();
      return (
        response.statusCode,
        await response.transform(utf8.decoder).join(),
      );
    }

    final token = await pairedToken(host);
    expect((await request('info')).$1, 401);
    expect((await request('info', token: 'x' * 43)).$1, 401);
    expect(
      (await request('info', token: token, origin: 'https://example.com')).$1,
      401,
    );
    final info = await request('info', token: token);
    expect(info.$1, 200);
    expect(info.$2, isNot(contains(token)));
    expect(jsonDecode(info.$2)['speechProvider'], 'whisper');
    expect(jsonDecode(info.$2)['hostId'], host.devices.hostId);
    expect(jsonDecode(info.$2)['busy'], false);
    expect(jsonDecode(info.$2)['device'], 'Test client');
    expect(host.devices.devices.single.lastSeen, isNotNull);
    expect(
      (await request(
        'transcribe?language=en',
        token: token,
        bytes: [1, 2, 3],
      )).$1,
      400,
    );
    expect(engine.languages, isEmpty);
    expect(
      (await request(
        'translate',
        token: token,
        bytes: utf8.encode('{"text":7}'),
      )).$1,
      400,
    );

    // Pairing: a code from the host's screen becomes a device token.
    Future<(int, String)> pair(String body, {String? origin}) =>
        request('pair', bytes: utf8.encode(body), origin: origin);
    expect((await pair('{"code":"123456","name":"Phone"}')).$1, 403);
    final code = host.devices.beginPairing();
    expect((await pair('{"code":"000000","name":"Phone"}')).$1, 403);
    expect((await pair('{"code":"$code"}', origin: 'https://x.test')).$1, 401);
    expect((await pair('{"code":7}')).$1, 400);
    final paired = await pair(
      '{"code":"$code","name":"Phone","platform":"android"}',
    );
    expect(paired.$1, 200);
    final grant = jsonDecode(paired.$2) as Map;
    expect(grant['hostId'], host.devices.hostId);
    expect(grant['name'], 'Test host');
    expect(host.devices.devices.last.name, 'Phone');
    expect(host.devices.devices.last.platform, 'android');
    expect((await pair('{"code":"$code","name":"Again"}')).$1, 403);
    expect((await request('info', token: grant['token'] as String)).$1, 200);

    // Tokens survive a restart of sharing, and revocation ends them.
    await host.stop();
    expect(host.devices.pairingCode, isNull);
    await startHost(host);
    expect((await request('info', token: token)).$1, 200);
    await host.devices.revoke(host.devices.devices.first.id);
    expect((await request('info', token: token)).$1, 401);
    expect((await request('info', token: grant['token'] as String)).$1, 200);

    final client = RemoteClient(RemoteConnection(address: host.address));
    host.devices.beginPairing();
    await expectLater(
      client.pair('111111', 'Laptop', 'windows'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'pairingCodeInvalid',
        ),
      ),
    );
    final result = await client.pair(
      host.devices.pairingCode!,
      'Laptop',
      'windows',
    );
    expect(result['token'], isA<String>());
    expect(host.devices.devices.last.name, 'Laptop');
  });

  test('real HTTP client routes speech, translation/context, summary and cleanup to local host only', () async {
    final engine = FakeEngine();
    final translator = FakeTranslator();
    final host = SharedHost(engine: engine, translator: translator);
    await startHost(host);
    addTearDown(() async {
      await host.stop();
      host.dispose();
    });
    final config = await connection(host);
    final speech = RemoteSpeechEngine(config),
        llm = RemoteTranslationService(config);
    addTearDown(() async {
      await speech.stop();
      llm.stop();
    });
    await speech.start('', '', Directory('unused'));
    // Local user cloud preferences cannot turn a remote request into a cloud call.
    await llm.prepare('', '', provider: LlmProvider.gemini);
    expect(
      await speech.transcribe(pcmToWave(Uint8List(64000)), 'zh'),
      isNotEmpty,
    );
    expect(engine.languages, ['zh']);
    expect(
      await llm.translate(
        'It is ready.',
        'en',
        'zh',
        context: const [TranslationContext('The GPU job.', 'GPU 任务。')],
      ),
      '测试译文',
    );
    expect(translator.contexts.single.single.text, 'The GPU job.');
    expect(translator.provider, LlmProvider.ollama);
    expect((await llm.summarize(['Hello'], 'zh')).title, isNotEmpty);
    expect(
      (await llm.cleanUp(['Hello'], const CleanupOptions(names: true))).texts,
      ['Hello'],
    );
    await speech.stop();
    expect(await llm.translate('Still running.', 'en', 'zh'), isNotEmpty);
    expect(host.running, true);
    expect(engine.starts, 1);
  });

  test('remote realtime keeps dual capture/local records and discard does not stop the host', () async {
    final host = SharedHost(engine: FakeEngine(), translator: FakeTranslator());
    await startHost(host);
    addTearDown(() async {
      await host.stop();
      host.dispose();
    });
    final live = fakeController()
      ..generateSummary = false
      ..useRemote = true;
    live.remoteConnection.address = host.address;
    live.remoteConnection.token = await pairedToken(host);
    addTearDown(live.dispose);
    await live.start(
      microphone: true,
      system: true,
      language: 'en',
      targetLanguage: 'zh',
    );
    expect(live.phase, SessionPhase.listening);
    (live.audio as FakeAudio).events.addAll([
      chunk('microphone', 0),
      chunk('system', 2000),
    ]);
    await until(
      () =>
          live.record!.lines.length == 2 &&
          live.record!.lines.every((line) => line.translationStatus == 'done'),
    );
    await live.stop();
    expect(live.records.single.speechProvider, 'whisperRemote');
    expect(live.records.single.llmProvider, 'remote');
    expect(live.records.single.llmModel, 'test-llm');
    expect((live.localEngine as FakeEngine).starts, 0);
    expect((live.localTranslator as FakeTranslator).prepared, 0);
    expect(host.running, true);
    await live.start(microphone: true, system: false, language: 'en');
    await live.togglePause();
    await live.discard();
    expect(live.records.length, 1);
    expect(host.running, true);
  });

  test(
    'remote file processing inherits translation, summary and cleanup',
    () async {
      final host = SharedHost(
        engine: FakeEngine(),
        translator: FakeTranslator(),
      );
      await startHost(host);
      addTearDown(() async {
        await host.stop();
        host.dispose();
      });
      final live =
          RealtimeController(
              audio: FakeAudio(),
              engine: FakeEngine(),
              store: MemoryStore(),
              translator: FakeTranslator(),
              fileDecoder: FileDecoderFake(),
              catalog: FakeModelCatalog(),
            )
            ..initialized = true
            ..useRemote = true;
      live.remoteConnection.address = host.address;
      live.remoteConnection.token = await pairedToken(host);
      addTearDown(live.dispose);
      await live.startFiles(
        paths: ['fixture.wav'],
        language: 'en',
        targetLanguage: 'zh',
        summaryLanguage: 'zh',
        options: const CleanupOptions(terms: true),
      );
      expect(live.records.single.lines.length, 2);
      expect(live.records.single.summaryStatus, 'done');
      expect(live.records.single.cleanupStatus, 'done');
      expect(
        live.records.single.lines.every(
          (line) => line.translationStatus == 'done',
        ),
        true,
      );
      expect(host.running, true);
    },
  );

  test('network failure preserves finished text and cloud choice never uses remote services', () async {
    final host = SharedHost(engine: FakeEngine(), translator: FakeTranslator());
    await startHost(host);
    addTearDown(() async {
      await host.stop();
      host.dispose();
    });
    final live = fakeController()
      ..generateSummary = false
      ..useRemote = true;
    live.remoteConnection.address = host.address;
    live.remoteConnection.token = await pairedToken(host);
    addTearDown(live.dispose);
    await live.start(microphone: true, system: false, language: 'en');
    (live.audio as FakeAudio).events.add(chunk('microphone', 0));
    await until(() => live.record!.lines.length == 1);
    await host.stop();
    (live.audio as FakeAudio).events.add(chunk('microphone', 2000));
    await until(() => !live.active);
    expect(live.records.single.lines.length, 1);
    expect(live.records.single.status, 'error');
    live.speechProvider = SpeechProvider.openAI;
    expect(live.remoteProcessing, false);
    expect(live.translator, same(live.localTranslator));
    expect(live.engine, same(live.localEngine));
  });

  test(
    'queue saturation is explicit and accepted requests finish in order',
    () async {
      final engine = FakeEngine()..response = Completer<String>();
      final host = SharedHost(engine: engine, translator: FakeTranslator());
      await startHost(host, llm: false);
      final clients = <RemoteClient>[];
      final tasks = <Future<Object>>[];
      addTearDown(() async {
        for (final client in clients) {
          client.close();
        }
        await host.stop();
        host.dispose();
      });
      for (var i = 0; i < 9; i++) {
        final client = RemoteClient(await connection(host));
        clients.add(client);
        await client.connect();
        tasks.add(
          client
              .request(
                'transcribe',
                wave: pcmToWave(Uint8List(64000)),
                language: 'en',
              )
              .then<Object>((r) => r, onError: (Object e) => e),
        );
        if (i < 8) await until(() => host.pending == i + 1);
      }
      expect((await tasks.last).toString(), contains('remoteBusy'));
      engine.response!.complete('Hello');
      final results = await Future.wait(tasks.take(8));
      expect(results.every((result) => result is Map), true);
      await host.stop();
      expect(host.pending, 0);
    },
  );

  test(
    'stopping sharing cancels inference and never starts queued work',
    () async {
      final engine = CancellableEngine()..response = Completer<String>();
      final host = SharedHost(engine: engine, translator: FakeTranslator());
      await startHost(host, llm: false);
      final clients = <RemoteClient>[];
      final tasks = <Future<Object>>[];
      addTearDown(() async {
        for (final client in clients) {
          client.close();
        }
        await host.stop();
        host.dispose();
      });
      for (var i = 0; i < 3; i++) {
        final client = RemoteClient(await connection(host));
        clients.add(client);
        await client.connect();
        tasks.add(
          client
              .request(
                'transcribe',
                wave: pcmToWave(Uint8List(64000)),
                language: 'en',
              )
              .then<Object>((r) => r, onError: (Object e) => e),
        );
        await until(() => host.pending == i + 1);
      }
      expect(engine.languages, ['en']);
      await host.stop();
      final results = await Future.wait(tasks);
      expect(results.every((result) => result is FormatException), true);
      expect(engine.languages, ['en']);
      expect(host.pending, 0);
      expect(host.running, false);
    },
  );
}
