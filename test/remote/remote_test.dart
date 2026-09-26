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
import 'package:altranscribe/data/services/remote/paired_devices.dart';
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
    expect(jsonDecode(info.$2)['llmModels'], ['test-llm', 'test-model']);
    // The challenge proves the host holds a device's credential without
    // revealing it; only well-formed nonces are answered.
    final nonce = 'ab' * 16;
    final challenge = await request('challenge?nonce=$nonce');
    expect(challenge.$1, 200);
    expect(jsonDecode(challenge.$2)['hostId'], host.devices.hostId);
    final port = Uri.parse(host.address).port;
    final proofs = jsonDecode(challenge.$2)['proofs'] as List;
    expect(
      proofs,
      contains(
        PairedDevices.proof(
          PairedDevices.hash(token),
          nonce,
          PairedDevices.endpoint(InternetAddress.loopbackIPv4, port),
        ),
      ),
    );
    // Proofs speak for the endpoint the host listens on, not another one.
    expect(
      proofs,
      isNot(
        contains(
          PairedDevices.proof(
            PairedDevices.hash(token),
            nonce,
            PairedDevices.endpoint(InternetAddress.loopbackIPv4, port + 1),
          ),
        ),
      ),
    );
    expect(challenge.$2, isNot(contains(token)));
    expect((await request('challenge?nonce=short')).$1, 400);
    expect(
      (await request('challenge?nonce=$nonce', origin: 'https://x.test')).$1,
      401,
    );
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
    expect(
      (await request(
        'translate',
        token: token,
        bytes: utf8.encode(
          '{"text":"x","source":"en","target":"zh","model":"unlisted"}',
        ),
      )).$1,
      400,
      reason: 'only models the host listed may be requested',
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

  test('a client that knows the host identity sends its credential only to a host that proves it', () async {
    final host = SharedHost(engine: FakeEngine(), translator: FakeTranslator());
    await startHost(host);
    addTearDown(() async {
      await host.stop();
      host.dispose();
    });
    final token = await pairedToken(host);
    final genuine = RemoteClient(
      RemoteConnection(
        address: host.address,
        token: token,
        hostId: host.devices.hostId,
      ),
    );
    addTearDown(genuine.close);
    expect((await genuine.connect())['hostId'], host.devices.hostId);

    // An impostor on the network advertises the same identity but cannot
    // answer the challenge; it must never see the token.
    final headers = <String?>[];
    final impostor = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => impostor.close(force: true));
    var answerChallenge = true;
    impostor.listen((request) async {
      headers.add(request.headers.value(HttpHeaders.authorizationHeader));
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/v1/challenge' && answerChallenge) {
        request.response.write(
          jsonEncode({
            'hostId': host.devices.hostId,
            'proofs': ['00' * 32],
          }),
        );
      } else if (request.uri.path == '/v1/info') {
        request.response.write(jsonEncode(host.info));
      } else {
        request.response.statusCode = 401;
      }
      await request.response.close();
    });
    for (final legacyAnswer in [false, true]) {
      answerChallenge = !legacyAnswer;
      final fooled = RemoteClient(
        RemoteConnection(
          address: 'http://127.0.0.1:${impostor.port}',
          token: token,
          hostId: host.devices.hostId,
        ),
      );
      await expectLater(
        fooled.connect(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'remoteUnverified',
          ),
        ),
      );
      fooled.close();
    }
    expect(headers, isNotEmpty);
    expect(headers.every((value) => value == null), isTrue);

    // A relay passes the challenge, and anything after it, on to the real
    // host. Its answer is genuine but speaks for the host's endpoint, so the
    // relay is refused before it can collect the token.
    final relayed = <String?>[];
    final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => relay.close(force: true));
    final onward = HttpClient();
    addTearDown(() => onward.close(force: true));
    relay.listen((request) async {
      final authorization = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      relayed.add(authorization);
      final forwarded = await onward.openUrl(
        request.method,
        Uri.parse(host.address).replace(
          path: request.uri.path,
          query: request.uri.hasQuery ? request.uri.query : null,
        ),
      );
      if (authorization != null) {
        forwarded.headers.set(HttpHeaders.authorizationHeader, authorization);
      }
      await forwarded.addStream(request);
      final answer = await forwarded.close();
      request.response.statusCode = answer.statusCode;
      request.response.headers.contentType = ContentType.json;
      await request.response.addStream(answer);
      await request.response.close();
    });
    final relayedClient = RemoteClient(
      RemoteConnection(
        address: 'http://127.0.0.1:${relay.port}',
        token: token,
        hostId: host.devices.hostId,
      ),
    );
    await expectLater(
      relayedClient.connect(),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'remoteUnverified',
        ),
      ),
    );
    relayedClient.close();
    expect(relayed, hasLength(1), reason: 'only the challenge went through');
    expect(relayed.single, isNull);

    // A controller following discovery keeps its saved address when the
    // host at the new one fails the challenge.
    final live = fakeController()..useRemote = true;
    addTearDown(live.dispose);
    live.remoteConnection
      ..address = host.address
      ..token = token
      ..hostId = host.devices.hostId;
    await live.probeHost(discover: false);
    expect(live.hostStatus, HostStatus.online);
  });

  test('real HTTP client routes speech, translation/context, summary and cleanup to local host only', () async {
    final engine = FakeEngine();
    final translator = FakeTranslator();
    final extras = <FakeTranslator>[];
    final host = SharedHost(
      engine: engine,
      translator: translator,
      createTranslator: () {
        final extra = FakeTranslator();
        extras.add(extra);
        return extra;
      },
    );
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
    // Another listed model gets its own service on the host, prepared once.
    await llm.prepare('', 'test-model');
    expect(llm.backend, 'Remote · ollama · test-model');
    expect(await llm.translate('Other model.', 'en', 'zh'), '测试译文');
    expect(await llm.translate('Again.', 'en', 'zh'), '测试译文');
    expect(extras.single.calls.map((call) => call.$1), [
      'Other model.',
      'Again.',
    ]);
    expect(extras.single.prepared, 1);
    expect(
      translator.calls.map((call) => call.$1),
      isNot(contains('Other model.')),
    );
    await expectLater(
      llm.prepare('', 'unlisted'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'remoteLlmModelMissing',
        ),
      ),
    );
    await llm.prepare('', '');
    expect(llm.backend, 'Remote · ollama · test-llm');
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
