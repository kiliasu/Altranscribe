import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/services/cloud/cloud_api.dart';
import 'package:altranscribe/data/services/cloud/credential_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../cloud/cloud_test.dart' show FixtureHttpClient, MemoryCredentials;
import '../support/fakes.dart';

class NamedCredentials extends CredentialStore {
  final values = <String, String>{};
  @override
  Future<String> readNamed(String name) async => values[name] ?? '';
  @override
  Future<void> writeNamed(String name, String key) async => values[name] = key;
}

String completion(String content, {String finish = 'stop'}) => jsonEncode({
  'choices': [
    {
      'message': {'content': content},
      'finish_reason': finish,
    },
  ],
});

void main() {
  test(
    'address policy keeps keys off plain HTTP and Ollama on this machine',
    () {
      Uri address(String value, LlmProvider provider) =>
          LocalLlmService.serviceAddress(value, provider);
      expect(
        address(
          'https://openrouter.ai/api/v1/',
          LlmProvider.openAICompatible,
        ).toString(),
        'https://openrouter.ai/api/v1',
      );
      expect(
        address('http://127.0.0.1:1234/v1', LlmProvider.openAICompatible).path,
        '/v1',
      );
      expect(
        () => address('http://example.com/v1', LlmProvider.openAICompatible),
        throwsFormatException,
      );
      expect(
        () => address(
          'https://user:pw@openrouter.ai/v1',
          LlmProvider.openAICompatible,
        ),
        throwsFormatException,
      );
      expect(
        () => address('https://api.example.com/v1', LlmProvider.ollama),
        throwsFormatException,
      );
      expect(
        () => address('http://127.0.0.1:11434/custom', LlmProvider.ollama),
        throwsFormatException,
      );
      expect(LocalLlmService.isOnline(Uri.parse('https://a.example')), isTrue);
      expect(LocalLlmService.isOnline(Uri.parse('http://127.0.0.1')), isFalse);
    },
  );

  test(
    'compatible services get the saved key and keep the address prefix',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      final auth = <String?>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        auth.add(request.headers.value('authorization'));
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          request.uri.path.endsWith('/models')
              ? '{"data":[{"id":"m1"}]}'
              : completion(' 你好 '),
        );
        await request.response.close();
      });
      final address = 'http://127.0.0.1:${server.port}/api/v1';
      final credentials = NamedCredentials()
        ..values[LocalLlmService.compatibleCredentialName(address)] =
            'compat-test-key'
        ..values[compatibleKeyName] = 'legacy-key';

      final keyed = LocalLlmService(cloudApi: CloudApi(credentials));
      expect(
        await keyed.models(address, provider: LlmProvider.openAICompatible),
        ['m1'],
      );
      await keyed.prepare(
        address,
        'm1',
        provider: LlmProvider.openAICompatible,
      );
      expect(await keyed.translate('Hello', 'en', 'zh'), '你好');
      expect(keyed.backend, 'OpenAI compatible');
      keyed.stop();
      expect(paths, ['/api/v1/models', '/api/v1/chat/completions']);
      expect(auth.toSet(), {'Bearer compat-test-key'});

      paths.clear();
      auth.clear();
      final anonymous = LocalLlmService(cloudApi: CloudApi(credentials));
      await anonymous.prepare(
        '$address/other',
        'm1',
        provider: LlmProvider.openAICompatible,
      );
      await anonymous.translate('Hello', 'en', 'zh');
      anonymous.stop();
      expect(auth.toSet(), {null});
      expect(
        LocalLlmService.compatibleCredentialName('$address/'),
        LocalLlmService.compatibleCredentialName(address),
      );
      expect(
        LocalLlmService.compatibleCredentialName('https://other.example/v1'),
        LocalLlmService.compatibleCredentialName('https://other.example'),
      );
      await expectLater(
        anonymous.models(
          'https://other.example/v1',
          provider: LlmProvider.openAICompatible,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cloudKeyMissing',
          ),
        ),
      );
    },
  );

  test(
    'the shared host translators carry the saved compatible-service key',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final auth = <String?>[];
      server.listen((request) async {
        auth.add(request.headers.value('authorization'));
        request.response.headers.contentType = ContentType.json;
        request.response.write(completion('你好'));
        await request.response.close();
      });
      final address = 'http://127.0.0.1:${server.port}/v1';
      final credentials = NamedCredentials()
        ..values[LocalLlmService.compatibleCredentialName(address)] =
            'compat-test-key';
      final audio = FakeAudio();
      final live = RealtimeController(
        audio: audio,
        engine: FakeEngine(),
        store: MemoryStore(),
        translator: FakeTranslator(),
        recordSummarizer: FakeTranslator(),
        catalog: FakeModelCatalog(),
        credentials: credentials,
      )..initialized = true;
      addTearDown(live.dispose);
      await live.sharedHost.translator.prepare(
        address,
        'm1',
        provider: LlmProvider.openAICompatible,
      );
      expect(
        await live.sharedHost.translator.translate('Hello', 'en', 'zh'),
        '你好',
      );
      live.sharedHost.translator.stop();
      expect(auth, ['Bearer compat-test-key']);
    },
  );

  test('manual models work without listing access', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var listingStatus = 401;
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      await request.drain<void>();
      final listing = request.uri.path.endsWith('/models');
      request.response.statusCode = listing ? listingStatus : 200;
      request.response.write(
        listing ? '{"error":"No listing access"}' : completion('你好'),
      );
      await request.response.close();
    });
    final service = LocalLlmService();
    addTearDown(service.stop);
    final address = 'http://127.0.0.1:${server.port}/v1';
    await expectLater(
      service.models(address, provider: LlmProvider.openAICompatible),
      throwsA(
        isA<LlmHttpException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    listingStatus = 404;
    expect(
      await service.models(address, provider: LlmProvider.openAICompatible),
      isEmpty,
    );
    paths.clear();
    await service.prepare(
      address,
      'manual-model',
      provider: LlmProvider.openAICompatible,
    );
    expect(await service.translate('Hello', 'en', 'zh'), '你好');
    expect(paths, ['/v1/chat/completions']);
  });

  test('cleanup retries only unsupported formats, once, and still validates edits', () async {
    const unsupported = 'This response_format type is unavailable now';
    for (final status in [400, 401, 403, 422, 429, 500]) {
      expect(
        LlmHttpException(status, unsupported).unsupportedSchema,
        status == 400 || status == 422,
      );
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final formats = <String>[];
    var rejection = 400;
    var message = unsupported;
    var rejectObject = false;
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final format = body['response_format']['type'] as String;
      formats.add(format);
      final rejected = format == 'json_schema' || rejectObject;
      request.response.statusCode = rejected ? rejection : 200;
      const proposed =
          '{"edits":['
          '{"category":"correction","from":"Pythno","to":"Python","confidence":"high"},'
          '{"category":"correction","from":"10","to":"20","confidence":"high"}]}';
      request.response.write(
        rejected
            ? jsonEncode({
                'error': {'message': message},
              })
            : completion(proposed),
      );
      await request.response.close();
    });
    final service = LocalLlmService();
    addTearDown(service.stop);
    Future<void> prepare() => service.prepare(
      'http://127.0.0.1:${server.port}/v1',
      'm1',
      provider: LlmProvider.openAICompatible,
    );
    Future<CleanupResult> cleanup() => service.cleanUp([
      'Pythno has 10 items.',
    ], const CleanupOptions(corrections: true, spellings: ['Python', '20']));
    await prepare();
    expect((await cleanup()).texts, ['Python has 10 items.']);
    expect((await cleanup()).texts, ['Python has 10 items.']);
    expect(formats, ['json_schema', 'json_object', 'json_object']);
    for (final failure in [
      (400, unsupported, true),
      (401, unsupported, false),
      (400, 'Unknown model', false),
    ]) {
      (rejection, message, rejectObject) = failure;
      await prepare();
      formats.clear();
      await expectLater(cleanup(), throwsA(isA<LlmHttpException>()));
      expect(
        formats,
        rejectObject ? ['json_schema', 'json_object'] : ['json_schema'],
      );
    }
  });

  test(
    'listing cloud models never closes the client a session translates with',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'gpt-test'},
            ],
          }),
        );
        await request.response.close();
      });
      final api = CloudApi(
        MemoryCredentials(),
        clientFactory: () => FixtureHttpClient(server, []),
      );
      addTearDown(api.close);
      await api.prepare(CloudProvider.openAI);
      final service = LocalLlmService(cloudApi: api);
      expect(await service.models('', provider: LlmProvider.openAI), [
        'gpt-test',
      ]);
      // The session's own client is untouched, so its next request still works.
      final response = await api.send('GET', '/v1/models');
      expect(response.statusCode, 200);
      await response.drain<void>();
    },
  );

  test(
    'DeepSeek uses the output budget for translation and summary, not thinking',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final urls = <Uri>[];
      final bodies = <Map>[];
      var truncated = false;
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        bodies.add(body);
        final thinking =
            urls.last.host == 'api.deepseek.com' &&
            (body['thinking'] as Map?)?['type'] != 'disabled';
        final summary = body['messages'][0]['content'].startsWith(
          'Create a factual title',
        );
        final content = thinking
            ? ''
            : summary
            ? '{"title":"Amplifiers","summary":"Input impedance matters."}'
            : '输入阻抗很重要。';
        request.response.write(
          completion(
            content,
            finish: thinking || truncated ? 'length' : 'stop',
          ),
        );
        await request.response.close();
      });
      final credentials = NamedCredentials();
      for (final host in ['api.deepseek.com', 'compatible.example']) {
        credentials.values[LocalLlmService.compatibleCredentialName(
              'https://$host/v1',
            )] =
            'test-key';
      }
      await HttpOverrides.runZoned(() async {
        final service = LocalLlmService(cloudApi: CloudApi(credentials));
        addTearDown(service.stop);
        await service.prepare(
          'https://api.deepseek.com/v1',
          'deepseek-flash',
          provider: LlmProvider.openAICompatible,
        );
        expect(
          await service.translate('The input impedance matters.', 'en', 'zh'),
          '输入阻抗很重要。',
        );
        expect(
          (await service.summarize([
            'The input impedance matters.',
          ], 'en')).title,
          'Amplifiers',
        );
        truncated = true;
        await expectLater(
          service.translate('Long answer', 'en', 'zh'),
          throwsFormatException,
        );
        truncated = false;
        await service.prepare(
          'https://compatible.example/v1',
          'other-model',
          provider: LlmProvider.openAICompatible,
        );
        await service.translate('Hello', 'en', 'zh');
        expect(bodies.last.containsKey('thinking'), isFalse);
      }, createHttpClient: (_) => FixtureHttpClient(server, urls));
    },
  );
}
