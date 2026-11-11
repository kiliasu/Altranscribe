import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/services/cloud/cloud_api.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../cloud/cloud_test.dart' show FixtureHttpClient, MemoryCredentials;

void main() {
  setUp(() {
    final delays = LocalLlmService.retryDelays;
    LocalLlmService.retryDelays = const [
      Duration(milliseconds: 10),
      Duration(milliseconds: 10),
      Duration(milliseconds: 10),
      Duration(milliseconds: 10),
    ];
    addTearDown(() => LocalLlmService.retryDelays = delays);
  });

  Future<(HttpServer, List<int>)> cloud(
    int Function(int request) status,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final statuses = <int>[];
    server.listen((request) async {
      if (request.uri.path == '/v1/models') {
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'gpt-test'},
            ],
          }),
        );
      } else {
        final code = status(statuses.length);
        statuses.add(code);
        request.response.statusCode = code;
        request.response.write(
          code == 200
              ? jsonEncode({
                  'status': 'completed',
                  'output': [
                    {
                      'type': 'message',
                      'content': [
                        {'type': 'output_text', 'text': '你好'},
                      ],
                    },
                  ],
                })
              : '{"error":{"message":"slow down"}}',
        );
      }
      await request.response.close();
    });
    return (server, statuses);
  }

  Future<LocalLlmService> prepared(HttpServer server) async {
    final api = CloudApi(
      MemoryCredentials(),
      clientFactory: () => FixtureHttpClient(server, []),
    );
    final service = LocalLlmService(cloudApi: api);
    addTearDown(service.stop);
    await service.prepare('', 'gpt-test', provider: LlmProvider.openAI);
    return service;
  }

  test('a rate-limited cloud request is repeated after a pause', () async {
    final (server, statuses) = await cloud(
      (request) => request < 2 ? 429 : 200,
    );
    final service = await prepared(server);
    expect(await service.translate('Hello', 'en', 'zh'), '你好');
    expect(statuses, [429, 429, 200]);
  });

  test('a service that stays overloaded fails after the last repeat', () async {
    final (server, statuses) = await cloud((_) => 503);
    final service = await prepared(server);
    await expectLater(
      service.translate('Hello', 'en', 'zh'),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'cloudHttp503'),
      ),
    );
    expect(statuses, hasLength(1 + LocalLlmService.retryDelays.length));
  });

  test('only limits, server errors and lost connections are repeated', () {
    expect(LocalLlmService.retryDelay(400, 0), isNull);
    expect(LocalLlmService.retryDelay(401, 0), isNull);
    expect(LocalLlmService.retryDelay(429, 0), isNotNull);
    expect(LocalLlmService.retryDelay(429, 3), isNotNull);
    expect(LocalLlmService.retryDelay(429, 4), isNull);
    expect(LocalLlmService.retryDelay(529, 0), isNotNull);
    expect(LocalLlmService.retryDelay(0, 1), isNotNull);
    expect(LocalLlmService.retryDelay(0, 2), isNull);
    // Each pause is at least the listed one and at most half as long again.
    final pause = LocalLlmService.retryDelay(429, 1)!;
    expect(pause.inMilliseconds, inInclusiveRange(10, 15));
  });
}
