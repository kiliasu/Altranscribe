import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/translation/translation_terms.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const geoffrey = TranslationTerm(
    source: 'Geoffrey',
    translation: '杰弗里',
    type: 'person',
  );
  test('fixed names accept evidenced aliases but reject invented and conflicting identities', () {
    final terms = TranslationTerm.accept(
      [geoffrey],
      [
        {
          'source': 'Geoffrey',
          'translation': '杰佛瑞',
          'type': 'person',
          'aliases': ['Geoff', 'Invented'],
        },
        {
          'source': 'Nobody',
          'translation': '某人',
          'type': 'person',
          'aliases': [],
        },
      ],
      'Geoffrey is also called Geoff.',
    );
    expect(terms.single.translation, '杰弗里');
    expect(terms.single.aliases, ['Geoff']);
    expect(terms.single.occursIn('Geoffreys'), false);
    final distinct = TranslationTerm.accept(
      [
        geoffrey,
        const TranslationTerm(
          source: 'Jeff',
          translation: '杰夫',
          type: 'person',
        ),
      ],
      [
        {
          'source': 'Geoffrey',
          'translation': '杰弗里',
          'type': 'person',
          'aliases': ['Jeff'],
        },
      ],
      'Geoffrey met Jeff.',
    );
    expect(distinct, hasLength(2));
    expect(distinct.first.aliases, isEmpty);
  });

  test('a line of one repeated sound or phrase is recognized, not changed', () {
    for (final text in [
      '啊啊啊啊啊啊',
      '哈哈哈！',
      'Ha ha ha!',
      '对对对',
      'you ' * 12,
      "I'm sorry. " * 9,
      '哦' * 240,
      'う ' * 36,
    ]) {
      expect(isRepetition(text), true, reason: text);
    }
    for (final text in [
      '啊啊',
      'Nooooooooo!',
      '啊啊啊啊啊啊，我终于做完了！',
      'The budget is 100000000 yen.',
      'No no no no, not that one.',
      'Thank you. Thank you.',
      'Step 1. Step 2. Step 3.',
    ]) {
      expect(isRepetition(text), false, reason: text);
    }
  });

  test('longest name wins while a separate shorter mention still uses its own name', () {
    const york = TranslationTerm(
      source: 'York',
      translation: '约克',
      type: 'place',
    );
    const newYork = TranslationTerm(
      source: 'New York',
      translation: '纽约',
      type: 'place',
    );
    expect(TranslationTerm.relevant([york, newYork], 'New York'), [newYork]);
    expect(
      TranslationTerm.relevant([york, newYork], 'York and New York'),
      containsAll([york, newYork]),
    );
  });

  test('record snapshots persist rules and names with backward-compatible defaults', () {
    final record = TranscriptRecord(
      id: 'session-1',
      createdAt: DateTime(2026),
      language: 'en',
      targetLanguage: 'zh',
      sources: ['file'],
      lines: [],
      translationRules: 'No emoji.',
      translationTerms: [geoffrey],
    );
    final restored = TranscriptRecord.fromJson(
      jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>,
    );
    expect(restored.translationRules, 'No emoji.');
    expect(restored.translationTerms.single.translation, '杰弗里');
    expect(
      record.copy().translationTerms,
      isNot(same(record.translationTerms)),
    );
    final legacy = record.toJson()
      ..remove('translationRules')
      ..remove('translationTerms');
    expect(
      TranscriptRecord.fromJson(legacy).translationRules,
      defaultTranslationRules,
    );
    expect(TranscriptRecord.fromJson(legacy).translationTerms, isEmpty);
  });

  group('model requests', () {
    late HttpServer server;
    late LocalLlmService service;
    final requests = <Map>[];
    late Map Function(Map body, int index) respond;
    Map completion(String content, {String reason = 'stop'}) => {
      'done': true,
      'done_reason': reason,
      'message': {'content': content},
    };
    setUp(() async {
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      service = LocalLlmService();
      server.listen((request) async {
        Object result;
        if (request.uri.path == '/api/tags') {
          result = {
            'models': [
              {'name': 'test'},
            ],
          };
        } else if (request.uri.path == '/api/ps') {
          result = {'models': []};
        } else {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          requests.add(body);
          result = respond(body, requests.length);
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result));
        await request.response.close();
      });
      await service.prepare('http://127.0.0.1:${server.port}', 'test');
    });
    tearDown(() async {
      service.stop();
      await server.close(force: true);
    });

    test('a repeated sound is sent as said, and a reply the limit cuts off still counts', () async {
      // The scream keeps its length on the way to the model.
      respond = (_, _) => completion('Aaaaaaah!');
      expect(await service.translate('啊啊啊啊啊啊', 'zh', 'en'), 'Aaaaaaah!');
      expect(requests.single['messages'][1]['content'], '啊啊啊啊啊啊');
      final instruction = requests.single['messages'][0]['content'] as String;
      expect(instruction, contains('same tone and intensity'));
      expect(instruction, contains('keep the repetition'));
      expect(requests.single['options']['num_predict'], 48);

      // A model that keeps going past a long sound is stopped by a limit
      // that follows the text, and the words it finished still count.
      requests.clear();
      respond = (_, _) => completion('Oh oh oh oh o', reason: 'length');
      expect(await service.translate('哦' * 240, 'zh', 'en'), 'Oh oh oh oh');
      expect(requests.single['messages'][1]['content'], '哦' * 240);
      expect(requests.single['options']['num_predict'], 272);

      requests.clear();
      expect(
        (await service.prepareText(['う ' * 36], 'ja', 'zh')).terms,
        isEmpty,
      );
      expect(requests, isEmpty, reason: 'repeated sounds are not fixed names');

      // Nothing at all keeps the sound as it is.
      requests.clear();
      respond = (_, _) => completion('');
      expect(await service.translate('哦' * 240, 'zh', 'en'), '哦' * 240);
      expect(requests, hasLength(2));

      // Ordinary text cut off twice is reported.
      requests.clear();
      respond = (_, _) => completion('Today we', reason: 'length');
      await expectLater(
        service.translate('今天我们来讨论一下发布计划和后续安排。', 'zh', 'en'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            'translationTruncated',
          ),
        ),
      );
      expect(requests.map((body) => body['options']['num_predict']), [
        512,
        2048,
      ]);

      // A long line retries with four times the room.
      requests.clear();
      respond = (_, index) =>
          completion('译文', reason: index == 1 ? 'length' : 'stop');
      final line = [for (var i = 0; i < 60; i++) 'item$i'].join(' ');
      expect(await service.translate(line, 'en', 'zh'), '译文');
      expect(requests.map((body) => body['options']['num_predict']), [
        2048,
        8192,
      ]);
    });

    test('empty output retries, symbols pass through, and custom rules reach the model', () async {
      respond = (_, index) => completion(index == 1 ? '' : '嗯。');
      expect(
        await service.translate(
          'Hmm.',
          'en',
          'zh',
          rules: 'Keep a neutral tone. No emoji.',
        ),
        '嗯。',
      );
      expect(
        requests.first['messages'][0]['content'],
        contains('Keep a neutral tone. No emoji.'),
      );
      expect(await service.translate('…?!', 'en', 'zh'), '…?!');
      expect(requests, hasLength(2));
    });

    test('Japanese names retry romanized suggestions and repair an old romanized glossary', () async {
      respond = (_, index) => completion(
        jsonEncode({
          'terms': [
            {
              'source': 'Hinata',
              'translation': index == 1 ? 'Hinata' : '日向',
              'type': 'person',
              'aliases': [],
            },
          ],
        }),
      );
      final prepared = await service.prepareText(
        ['Hinataは明日来ます。'],
        'ja',
        'zh',
        terms: [
          const TranslationTerm(
            source: 'Hinata',
            translation: 'Hinata',
            type: 'person',
          ),
        ],
      );
      expect(prepared.terms.single.translation, '日向');
      expect(requests, hasLength(2));
      expect(
        requests.first['messages'][0]['content'],
        contains('in Simplified Chinese'),
      );
      expect(
        requests.last['messages'][0]['content'],
        contains('Chinese characters'),
      );
      final input =
          jsonDecode(requests.first['messages'][1]['content'] as String) as Map;
      expect(input['known_terms'], isEmpty);
    });

    test(
      'a fixed name spelled another way gets one more request, never an error',
      () async {
        respond = (_, index) => completion(index == 1 ? '杰佛瑞来了。' : '杰弗里来了。');
        expect(
          await service.translate(
            'Geoffrey arrived.',
            'en',
            'zh',
            terms: [geoffrey],
          ),
          '杰弗里来了。',
        );
        final data = jsonDecode(
          requests.first['messages'][1]['content'] as String,
        ) as Map;
        expect(data['names'], [
          {'name': 'Geoffrey', 'translation': '杰弗里'},
        ]);
        expect(requests, hasLength(2));
        expect(requests.last['messages'][0]['content'], contains('杰弗里'));

        requests.clear();
        respond = (_, _) => completion('杰佛瑞来了。');
        expect(
          await service.translate(
            'Geoffrey arrived.',
            'en',
            'zh',
            terms: [geoffrey],
          ),
          '杰佛瑞来了。',
        );
        expect(requests, hasLength(2));

        // A name the line does not mention is not sent or checked.
        requests.clear();
        respond = (_, _) => completion('她来了。');
        expect(
          await service.translate(
            'She arrived.',
            'en',
            'zh',
            terms: [geoffrey],
          ),
          '她来了。',
        );
        expect(requests, hasLength(1));
        expect(requests.single['messages'][1]['content'], 'She arrived.');
      },
    );

    test('join decisions in another shape are retried, then skipped', () async {
      var valid = false;
      respond = (body, _) {
        final data =
            jsonDecode(body['messages'][1]['content'] as String) as Map;
        if (data['pairs'] is List) {
          return completion(
            jsonEncode({
              'decisions': valid
                  ? [
                      {'index': 1, 'join': true},
                    ]
                  : {'index': 1, 'join': true},
            }),
          );
        }
        return completion(
          jsonEncode({
            'terms': [
              {
                'source': 'Geoffrey',
                'translation': '杰弗里',
                'type': 'person',
                'aliases': [],
              },
            ],
          }),
        );
      };
      const texts = ['Geoffrey wanted to explain why', 'the hall was closed.'];
      int joinRequests() => requests
          .where(
            (body) =>
                (jsonDecode(body['messages'][1]['content'] as String)
                    as Map)['pairs'] !=
                null,
          )
          .length;
      var prepared = await service.prepareText(
        texts,
        'en',
        'zh',
        mergeSentences: true,
      );
      // Names found in the same pass survive a malformed join answer.
      expect(prepared.terms.single.translation, '杰弗里');
      expect(prepared.joins, isEmpty);
      expect(joinRequests(), 2);

      requests.clear();
      valid = true;
      prepared = await service.prepareText(
        texts,
        'en',
        null,
        mergeSentences: true,
      );
      expect(prepared.joins, [1]);
    });

    test('preparation covers a long document, carries locked names and bounds join decisions', () async {
      respond = (body, index) {
        final data =
            jsonDecode(body['messages'][1]['content'] as String) as Map;
        if (data['pairs'] is List) {
          return completion(
            jsonEncode({
              'decisions': [
                for (final pair in data['pairs'] as List)
                  {'index': pair['index'], 'join': true},
              ],
            }),
          );
        }
        final segments = data['segments'] as List;
        final last = segments.last['index'] as int;
        return completion(
          jsonEncode({
            'terms': [
              {
                'source': 'Geoffrey',
                'translation': index == 1 ? '杰弗里' : '杰佛瑞',
                'type': 'person',
                'aliases': [],
              },
            ],
            'joins': [-1, last, 99999],
          }),
        );
      };
      final texts = List.generate(
        70,
        (i) => 'Geoffrey explains part $i. ${'a ' * 70}',
      );
      final prepared = await service.prepareText(
        texts,
        'en',
        'zh',
        mergeSentences: true,
      );
      expect(requests.length, greaterThan(2));
      expect(prepared.terms.single.translation, '杰弗里');
      expect(prepared.joins.every((i) => i > 0 && i < texts.length), true);
      final last = requests
          .map(
            (request) =>
                jsonDecode(request['messages'][1]['content'] as String) as Map,
          )
          .where((data) => data.containsKey('segments'))
          .last;
      expect(last['known_terms'][0]['translation'], '杰弗里');
      expect(last['segments'].last['text'], contains('part 69.'));
    });
  });
}
