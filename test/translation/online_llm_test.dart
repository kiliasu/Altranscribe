import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/services/cloud/cloud_api.dart';
import 'package:altranscribe/data/services/cloud/credential_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
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
          jsonEncode(
            request.uri.path.endsWith('/models')
                ? {
                    'data': [
                      {'id': 'm1'},
                    ],
                  }
                : {
                    'choices': [
                      {
                        'message': {'content': ' 你好 '},
                        'finish_reason': 'stop',
                      },
                    ],
                  },
          ),
        );
        await request.response.close();
      });
      final credentials = NamedCredentials()
        ..values[compatibleKeyName] = 'compat-test-key';
      final address = 'http://127.0.0.1:${server.port}/api/v1';

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
      expect(paths, [
        '/api/v1/models',
        '/api/v1/models',
        '/api/v1/chat/completions',
      ]);
      expect(auth.toSet(), {'Bearer compat-test-key'});

      paths.clear();
      auth.clear();
      final anonymous = LocalLlmService();
      await anonymous.prepare(
        address,
        'm1',
        provider: LlmProvider.openAICompatible,
      );
      await anonymous.translate('Hello', 'en', 'zh');
      anonymous.stop();
      expect(auth.toSet(), {null});
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
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'm1'},
            ],
          }),
        );
        await request.response.close();
      });
      final credentials = NamedCredentials()
        ..values[compatibleKeyName] = 'compat-test-key';
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
      final address = 'http://127.0.0.1:${server.port}/v1';
      await live.sharedHost.translator.prepare(
        address,
        'm1',
        provider: LlmProvider.openAICompatible,
      );
      live.sharedHost.translator.stop();
      expect(auth, ['Bearer compat-test-key']);
    },
  );

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
}
