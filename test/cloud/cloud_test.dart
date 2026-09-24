import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/cloud/cloud_api.dart';
import 'package:altranscribe/data/services/cloud/cloud_file_engine.dart';
import 'package:altranscribe/data/services/cloud/cloud_live.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/cloud/credential_store.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/features/settings/model_settings_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

class MemoryCredentials implements CredentialStore {
  final values = {
    for (final provider in CloudProvider.values) provider: 'dummy-test-key',
  };
  @override
  Future<String> read(CloudProvider provider) async => values[provider] ?? '';
  @override
  Future<void> write(CloudProvider provider, String key) async =>
      values[provider] = key;
}

class SocketFixture {
  SocketFixture(this.server);
  final HttpServer server;
  final sockets = <WebSocket>[];
  final requested = <Uri>[];
  final headers = <Map<String, String>>[];
  Future<WebSocket> connect(Uri uri, Map<String, String> auth) async {
    requested.add(uri);
    headers.add(auth);
    return WebSocket.connect('ws://127.0.0.1:${server.port}');
  }

  static Future<SocketFixture> start(
    void Function(WebSocket, Map<String, dynamic>) handle,
  ) async {
    final fixture = SocketFixture(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      fixture.sockets.add(socket);
      socket.listen(
        (raw) =>
            handle(socket, jsonDecode(raw as String) as Map<String, dynamic>),
      );
    });
    addTearDown(() async {
      for (final socket in fixture.sockets) {
        await socket.close();
      }
      await fixture.server.close(force: true);
    });
    return fixture;
  }
}

void send(WebSocket socket, Map<String, Object?> event) =>
    socket.add(jsonEncode(event));
Uint8List voice(int samples) {
  final pcm = Uint8List(samples * 2);
  final data = ByteData.sublistView(pcm);
  for (var i = 0; i < samples; i++) {
    data.setInt16(i * 2, 3000, Endian.little);
  }
  return pcm;
}

// Redirect only the test transport. Production URLs and authentication can be
// asserted while HTTP fixtures remain entirely on loopback with dummy keys.
class LoopbackHttpOverrides extends HttpOverrides {}

class FixtureHttpClient implements HttpClient {
  FixtureHttpClient(this.server, this.urls);
  final HttpServer server;
  final List<Uri> urls;
  final delegate = LoopbackHttpOverrides().createHttpClient(null);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    urls.add(url);
    return delegate.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}')
          .replace(path: url.path, query: url.hasQuery ? url.query : null),
    );
  }

  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'cloud settings save models and encrypted-key input independently in a narrow layout',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final credentials = MemoryCredentials();
      final controller = RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: MemoryStore(),
        catalog: FakeModelCatalog(),
        translator: FakeTranslator(),
        credentials: credentials,
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ModelSettingsDialog(
                    controller: controller,
                    english: true,
                  ),
                ),
                child: const Text('Open models'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open models'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('speech-provider-gemini')));
      await tester.pumpAndSettle();
      expect(find.text('dummy-test-key'), findsNothing);
      final keyField = find.byKey(const Key('api-key-gemini'));
      await tester.ensureVisible(keyField);
      await tester.enterText(keyField, 'replacement-test-key');
      await tester.ensureVisible(find.text('Save key'));
      await tester.tap(find.text('Save key'));
      await tester.pumpAndSettle();
      expect(
        await credentials.read(CloudProvider.gemini),
        'replacement-test-key',
      );
      expect(tester.widget<TextField>(keyField).controller!.text, isEmpty);
      expect(tester.widget<TextField>(keyField).obscureText, isTrue);
      await tester.ensureVisible(find.byKey(const Key('cloud-live-false')));
      await tester.tap(find.byKey(const Key('cloud-live-false')));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(controller.speechProvider, SpeechProvider.gemini);
      expect(controller.cloudDirectTranslation, isFalse);
      expect(controller.cloudAutoLanguage, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'Gemini preview drain does not pretend the server confirmed completion',
    () async {
      final fixture = await SocketFixture.start((socket, event) {
        if (event.containsKey('setup')) send(socket, {'setupComplete': {}});
        if (event['realtimeInput']?['audioStreamEnd'] == true) {
          send(socket, {
            'serverContent': {
              'inputTranscription': {'text': 'Final words.'},
            },
          });
          send(socket, {
            'serverContent': {
              'outputTranscription': {'text': '最后几个词。'},
            },
          });
        }
      });
      CloudLiveText? last;
      final live = CloudLive(
        credentials: MemoryCredentials(),
        provider: SpeechProvider.gemini,
        directTranslation: true,
        source: 'system',
        language: 'auto',
        targetLanguage: 'zh',
        connect: fixture.connect,
        onText: (e) => last = e,
        onError: (e) => fail(e),
      );
      await live.start();
      live.add(voice(1600), 0, 100);
      await live.finish();
      expect(last!.text, 'Final words.');
      expect(last!.finalized, isTrue);
      expect(last!.serverConfirmed, isFalse);
      final line = TranscriptLine(
        source: 'system',
        startMs: 0,
        endMs: 100,
        text: last!.text,
        translation: last!.translation,
        continuous: true,
        transcriptionStatus: 'streamed',
        translationStatus: 'done',
      );
      final saved = TranscriptLine.fromJson(
        jsonDecode(jsonEncode(line.toJson())) as Map<String, dynamic>,
      );
      expect(saved.transcriptionStatus, 'streamed');
      expect(saved.translation, '最后几个词。');
    },
  );

  test('Gemini file failure still deletes its upload; foreign upload URLs are rejected', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
    var foreign = false;
    server.listen((request) async {
      methods.add('${request.method} ${request.uri.path}');
      await request.drain<void>();
      if (request.uri.path == '/upload/v1beta/files') {
        request.response.headers.set(
          'x-goog-upload-url',
          foreign
              ? 'https://untrusted.invalid/upload'
              : 'https://generativelanguage.googleapis.com/upload/session',
        );
        request.response.write('{}');
      } else if (request.uri.path == '/upload/session') {
        request.response.write(
          jsonEncode({
            'file': {
              'name': 'files/own-upload',
              'state': 'ACTIVE',
              'uri': 'https://generativelanguage.googleapis.com/v1beta/files/own-upload',
            },
          }),
        );
      } else if (request.uri.path == '/v1beta/interactions') {
        request.response.statusCode = 429;
        request.response.write('Do not log dummy-test-key');
      } else {
        request.response.write('{}');
      }
      await request.response.close();
    });
    final api = CloudApi(
      MemoryCredentials(),
      clientFactory: () => FixtureHttpClient(server, []),
    );
    final engine = CloudFileEngine(api, CloudProvider.gemini);
    await engine.start('', '', Directory('unused'));
    await expectLater(
      engine.transcribe(pcmToWave(voice(1600)), 'auto'),
      throwsA(isA<StateError>()),
    );
    expect(methods.last, 'DELETE /v1beta/files/own-upload');
    expect(engine.cleanupWarning, isNull);
    foreign = true;
    await expectLater(
      engine.transcribe(pcmToWave(voice(1600)), 'auto'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'cloudInvalidEndpoint',
        ),
      ),
    );
    expect(methods.last, 'POST /upload/v1beta/files');
    await engine.stop();
  });
  test('OpenAI continuous speech submits after four seconds without waiting for silence', () async {
    var commits = 0;
    final fixture = await SocketFixture.start((socket, event) {
      if (event['type'] == 'session.update') {
        send(socket, {'type': 'session.updated'});
      } else if (event['type'] == 'input_audio_buffer.commit') {
        commits++;
        send(socket, {
          'type': 'input_audio_buffer.committed',
          'item_id': '$commits',
        });
        send(socket, {
          'type': 'conversation.item.input_audio_transcription.completed',
          'item_id': '$commits',
          'transcript': 'Part $commits',
        });
      }
    });
    final updates = <CloudLiveText>[];
    final live = CloudLive(
      credentials: MemoryCredentials(),
      provider: SpeechProvider.openAI,
      directTranslation: false,
      source: 'system',
      language: 'en',
      targetLanguage: null,
      connect: fixture.connect,
      onText: updates.add,
      onError: (error) => fail(error),
    );
    addTearDown(live.cancel);
    await live.start();
    live.add(voice(24000 * 3), 0, 3000);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(commits, 0);
    live.add(voice(24000), 3000, 4000);
    for (var i = 0; i < 100 && updates.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(commits, 1);
    expect(updates.single.endMs, 4000);
    expect(updates.single.continues, true);
    live.add(voice(24000), 4000, 5000);
    await live.finish();
    expect(updates.last.startMs, 4000);
    expect(updates.last.endMs, 5000);
    expect(updates.last.continues, false);
  });

  test('OpenAI ASR commits and associates out-of-order final items', () async {
    var commits = 0;
    final fixture = await SocketFixture.start((socket, event) {
      if (event['type'] == 'session.update') {
        final input = event['session']['audio']['input'];
        expect(input['format']['rate'], 24000);
        expect(input['transcription'], {'model': 'gpt-live-transcribe'});
        expect(input['turn_detection'], isNull);
        send(socket, {'type': 'session.updated'});
      } else if (event['type'] == 'input_audio_buffer.commit') {
        commits++;
        send(socket, {
          'type': 'input_audio_buffer.committed',
          'item_id': '$commits',
        });
        send(socket, {
          'type': 'conversation.item.input_audio_transcription.delta',
          'item_id': '$commits',
          'delta': 'draft',
        });
        if (commits == 2) {
          for (final id in [2, 1]) {
            send(socket, {
              'type': 'conversation.item.input_audio_transcription.completed',
              'item_id': '$id',
              'transcript': 'Final $id',
            });
          }
        }
      }
    });
    final updates = <String, CloudLiveText>{};
    final live = CloudLive(
      credentials: MemoryCredentials(),
      provider: SpeechProvider.openAI,
      directTranslation: false,
      source: 'microphone',
      language: 'auto',
      targetLanguage: null,
      connect: fixture.connect,
      onText: (e) => updates[e.id] = e,
      onError: (error) => fail(error),
    );
    await live.start();
    expect(fixture.requested.single.queryParameters['intent'], 'transcription');
    expect(fixture.headers.single['Authorization'], 'Bearer dummy-test-key');
    for (var i = 0; i < 2; i++) {
      live.add(voice(2400), i * 1000, i * 1000 + 100);
      live.add(Uint8List(28800), i * 1000 + 100, i * 1000 + 700);
    }
    await live.finish();
    expect(updates['microphone:1']!.text, 'Final 1');
    expect(updates['microphone:1']!.startMs, 0);
    expect(updates['microphone:2']!.startMs, 700);
    expect(updates.values.every((e) => e.finalized), isTrue);
  });

  test(
    'Gemini replaces interim text and flushes final text at audioStreamEnd',
    () async {
      final fixture = await SocketFixture.start((socket, event) {
        if (event.containsKey('setup')) {
          expect(event['setup']['inputAudioTranscription']['languageCodes'], [
            'cmn-Hans-CN',
          ]);
          expect(event['setup']['generationConfig']['responseModalities'], [
            'TEXT',
          ]);
          send(socket, {'setupComplete': {}});
        } else if (event['realtimeInput']?['audio'] != null) {
          expect(
            event['realtimeInput']['audio']['mimeType'],
            'audio/pcm;rate=16000',
          );
          send(socket, {
            'serverContent': {
              'interimInputTranscription': {'text': 'Hell'},
            },
          });
          send(socket, {
            'serverContent': {
              'interimInputTranscription': {'text': 'Hello'},
            },
          });
        } else if (event['realtimeInput']?['audioStreamEnd'] == true) {
          send(socket, {
            'serverContent': {
              'inputTranscription': {'text': 'Hello Alice.'},
            },
          });
          send(socket, {
            'serverContent': {'generationComplete': true},
          });
        }
      });
      final texts = <CloudLiveText>[];
      final live = CloudLive(
        credentials: MemoryCredentials(),
        provider: SpeechProvider.gemini,
        directTranslation: false,
        source: 'system',
        language: 'zh',
        targetLanguage: null,
        connect: fixture.connect,
        onText: texts.add,
        onError: (error) => fail(error),
      );
      await live.start();
      live.add(voice(1600), 1200, 1300);
      await live.finish();
      expect(texts.map((e) => e.text).toList(), [
        'Hell',
        'Hello',
        'Hello Alice.',
      ]);
      expect(texts.map((e) => e.id).toSet(), {'system:0'});
      expect(texts.last.finalized, isTrue);
    },
  );

  test(
    'OpenAI direct translation keeps timed bilingual windows and late text',
    () {
      final rows = <String, CloudLiveText>{};
      final live = CloudLive(
        credentials: MemoryCredentials(),
        provider: SpeechProvider.openAI,
        directTranslation: true,
        source: 'system',
        language: 'auto',
        targetLanguage: 'zh',
        onText: (text) => rows[text.id] = text,
        onError: fail,
      );
      addTearDown(live.cancel);
      void delta(bool input, String text, int elapsed, String id) =>
          live.handle({
            'type': 'session.${input ? 'input' : 'output'}_transcript.delta',
            'delta': text,
            'elapsed_ms': elapsed,
            'event_id': id,
          });
      delta(true, 'First sentence.', 1200, 'source-1');
      delta(true, ' Second sentence.', 6200, 'source-2');
      expect(rows.length, 2);
      expect(rows['system:window:0']!.finalized, isTrue);
      expect(rows['system:window:0']!.serverConfirmed, isFalse);
      expect(rows['system:window:0']!.translationFinalized, isFalse);

      // Translation arrives after newer source text, with several fragments
      // sharing one timestamp. Only event IDs identify duplicate deliveries.
      delta(false, '第一', 1200, 'target-1');
      delta(false, '句。', 1200, 'target-2');
      delta(false, '句。', 1200, 'target-2');
      delta(false, '第二句。', 6200, 'target-3');
      delta(false, '（补充）', 1400, 'target-late');
      expect(rows['system:window:0']!.text, 'First sentence.');
      expect(rows['system:window:0']!.translation, '第一句。（补充）');
      expect(rows['system:window:0']!.translationFinalized, isTrue);
      expect(rows['system:window:1']!.text, ' Second sentence.');
      expect(rows['system:window:1']!.translation, '第二句。');
      expect(rows['system:window:1']!.finalized, isFalse);
      expect(rows.values.every((row) => row.timingEstimated), isTrue);

      // Missing metadata stays explicitly unaligned rather than being guessed
      // into a preceding or following sentence by its arrival order.
      live.handle({
        'type': 'session.input_transcript.delta',
        'delta': 'Untimed',
      });
      live.handle({'type': 'session.output_transcript.delta', 'delta': '无时间'});
      expect(rows['system:stream']!.text, 'Untimed');
      expect(rows['system:stream']!.translation, '无时间');
      expect(rows['system:stream']!.continuous, isTrue);
      live.handle({'type': 'session.closed'});
      expect(
        rows.values.every((row) => row.finalized && row.serverConfirmed),
        isTrue,
      );
      expect(rows['system:window:1']!.translationFinalized, isTrue);
    },
  );

  for (final provider in [SpeechProvider.openAI, SpeechProvider.gemini]) {
    test(
      '${provider.name} direct translation appends fragments without invented spaces',
      () async {
        final fixture = await SocketFixture.start((socket, event) {
          if (event['type'] == 'session.update') {
            expect(
              event['session']['audio']['input']['transcription']['model'],
              'gpt-realtime-whisper',
            );
            expect(event['session']['audio']['output']['language'], 'zh');
            send(socket, {'type': 'session.updated'});
          } else if (event.containsKey('setup')) {
            final config = event['setup']['generationConfig'];
            expect(event['setup']['inputAudioTranscription'], isEmpty);
            expect(event['setup']['outputAudioTranscription'], isEmpty);
            expect(config.containsKey('inputAudioTranscription'), isFalse);
            expect(config['translationConfig'], {
              'targetLanguageCode': 'zh-Hans',
              'echoTargetLanguage': true,
            });
            send(socket, {'setupComplete': {}});
          } else if (event['type'] == 'session.close') {
            send(socket, {
              'type': 'session.output_transcript.delta',
              'delta': '你好',
            });
            send(socket, {
              'type': 'session.input_transcript.delta',
              'delta': 'Hel',
            });
            send(socket, {
              'type': 'session.input_transcript.delta',
              'delta': 'lo.',
            });
            send(socket, {
              'type': 'session.output_transcript.delta',
              'delta': '。',
            });
            send(socket, {'type': 'session.closed'});
          } else if (event['realtimeInput']?['audioStreamEnd'] == true) {
            for (final fragment in ['Hel', 'lo.']) {
              send(socket, {
                'serverContent': {
                  'inputTranscription': {'text': fragment},
                },
              });
            }
            send(socket, {
              'serverContent': {
                'outputTranscription': {'text': '你好。'},
              },
            });
            send(socket, {
              'serverContent': {'generationComplete': true},
            });
          }
        });
        CloudLiveText? last;
        final live = CloudLive(
          credentials: MemoryCredentials(),
          provider: provider,
          directTranslation: true,
          source: 'microphone',
          language: 'auto',
          targetLanguage: 'zh',
          connect: fixture.connect,
          onText: (e) => last = e,
          onError: (error) => fail(error),
        );
        await live.start();
        live.add(voice(live.sampleRate ~/ 10), 0, 100);
        await live.finish();
        expect(last!.text, 'Hello.');
        expect(last!.translation, '你好。');
        expect(last!.finalized, isTrue);
        expect(last!.continuous, isTrue);
      },
    );
  }

  test(
    'connection loss and quota errors never expose the key or claim completion',
    () async {
      final fixture = await SocketFixture.start((socket, event) {
        send(socket, {
          'type': 'error',
          'error': {
            'code': 'insufficient_quota',
            'message': 'secret dummy-test-key',
          },
        });
      });
      final errors = <String>[];
      final live = CloudLive(
        credentials: MemoryCredentials(),
        provider: SpeechProvider.openAI,
        directTranslation: false,
        source: 'system',
        language: 'auto',
        targetLanguage: null,
        connect: fixture.connect,
        onText: (_) {},
        onError: errors.add,
      );
      await expectLater(
        live.start(),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'cloudHttp429'),
        ),
      );
      expect(errors, ['cloudHttp429']);
    },
  );

  test(
    'missing final event times out explicitly while keeping partial text',
    () async {
      final fixture = await SocketFixture.start((socket, event) {
        if (event.containsKey('setup')) send(socket, {'setupComplete': {}});
        if (event['realtimeInput']?['audio'] != null) {
          send(socket, {
            'serverContent': {
              'interimInputTranscription': {'text': 'Unfinished'},
            },
          });
        }
      });
      final texts = <CloudLiveText>[];
      final live = CloudLive(
        credentials: MemoryCredentials(),
        provider: SpeechProvider.gemini,
        directTranslation: false,
        source: 'system',
        language: 'auto',
        targetLanguage: null,
        connect: fixture.connect,
        onText: texts.add,
        onError: (_) {},
        drainTimeout: const Duration(milliseconds: 120),
      );
      await live.start();
      live.add(voice(1600), 0, 100);
      await expectLater(
        live.finish(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cloudIncomplete',
          ),
        ),
      );
      expect(texts.single.text, 'Unfinished');
      expect(texts.single.finalized, isFalse);
    },
  );

  test('controller routes two sources to separate cloud sessions without Whisper or second translation', () async {
    final fixture = await SocketFixture.start((socket, event) {
      if (event['type'] == 'session.update') {
        send(socket, {'type': 'session.updated'});
      }
      if (event['type'] == 'session.close') {
        send(socket, {
          'type': 'session.output_transcript.delta',
          'delta': '下一句。',
          'elapsed_ms': 6200,
        });
        send(socket, {'type': 'session.closed'});
      }
    });
    final audio = FakeAudio();
    final engine = FakeEngine();
    final translator = FakeTranslator();
    final controller = RealtimeController(
      audio: audio,
      engine: engine,
      store: MemoryStore(),
      catalog: FakeModelCatalog(),
      translator: translator,
      credentials: MemoryCredentials(),
      cloudSocketConnector: fixture.connect,
    );
    await controller.initialize();
    controller.speechProvider = SpeechProvider.openAI;
    controller.generateSummary = false;
    await controller.start(
      microphone: true,
      system: true,
      language: 'en',
      targetLanguage: 'zh',
    );
    expect(controller.phase, SessionPhase.listening);
    expect(fixture.sockets.length, 2);
    expect(audio.options!['streaming'], true);
    expect(audio.options!['sampleRate'], 24000);
    expect(engine.starts, 0);
    expect(translator.prepared, 0);
    for (final socket in fixture.sockets) {
      send(socket, {
        'type': 'session.input_transcript.delta',
        'delta': 'Hello.',
        'elapsed_ms': 1200,
      });
      send(socket, {
        'type': 'session.input_transcript.delta',
        'delta': 'Next sentence.',
        'elapsed_ms': 6200,
      });
    }
    for (var i = 0; i < 100 && controller.record!.lines.length < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.record!.lines, hasLength(4));
    expect(
      controller.record!.lines
          .where((line) => line.text == 'Hello.')
          .every(
            (line) =>
                line.transcriptionStatus == 'streamed' &&
                line.translationStatus == 'pending' &&
                line.timingEstimated,
          ),
      isTrue,
    );
    for (final socket in fixture.sockets) {
      send(socket, {
        'type': 'session.output_transcript.delta',
        'delta': '你好。',
        'elapsed_ms': 1200,
      });
    }
    for (
      var i = 0;
      i < 100 &&
          controller.record!.lines
                  .where((line) => line.translation == '你好。')
                  .length <
              2;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.record!.lines, hasLength(4));
    expect(
      controller.record!.lines
          .where((line) => line.text == 'Hello.')
          .every(
            (line) =>
                line.translation == '你好。' &&
                line.translationStatus == 'streamed',
          ),
      isTrue,
    );
    await controller.stop();
    expect(controller.error, isNull);
    expect(translator.calls, isEmpty);
    expect(controller.record!.lines.map((e) => e.source).toSet(), {
      'microphone',
      'system',
    });
    expect(
      controller.record!.lines.every(
        (line) =>
            line.translation == (line.text == 'Hello.' ? '你好。' : '下一句。') &&
            line.transcriptionStatus == 'done' &&
            line.translationStatus == 'done',
      ),
      isTrue,
    );
    final saved = TranscriptRecord.fromJson(
      jsonDecode(jsonEncode(controller.record!.toJson()))
          as Map<String, dynamic>,
    );
    expect(saved.speechModel, 'gpt-realtime-translate');
    expect(saved.language, 'auto');
    expect(saved.directTranslation, true);
    expect(saved.dateTimeLabel, isNotEmpty);
    controller.dispose();
  });

  test('cloud file upload uses multipart gpt-transcribe and omits automatic language hints', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.headers.value('Authorization'), 'Bearer dummy-test-key');
      expect(request.uri.path, '/v1/audio/transcriptions');
      final body = await request
          .cast<List<int>>()
          .transform(latin1.decoder)
          .join();
      expect(body, contains('gpt-transcribe'));
      expect(body, contains('filename="audio.wav"'));
      expect(body, isNot(contains('name="languages')));
      request.response.write(
        jsonEncode({
          'text': 'File transcript',
          'languages': [
            {'code': 'en'},
          ],
        }),
      );
      await request.response.close();
    });
    final urls = <Uri>[];
    final api = CloudApi(
      MemoryCredentials(),
      clientFactory: () => FixtureHttpClient(server, urls),
    );
    final engine = CloudFileEngine(api, CloudProvider.openAI);
    await engine.start('', '', Directory('unused'));
    expect(
      await engine.transcribe(pcmToWave(voice(1600)), 'auto'),
      'File transcript',
    );
    expect(urls.single.host, 'api.openai.com');
    await engine.stop();
  });

  test('OpenAI text uses Responses output items, not SDK output_text or chat completions', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/v1/models') {
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'gpt-5.6-luna'},
            ],
          }),
        );
      } else {
        expect(request.uri.path, '/v1/responses');
        final body = jsonDecode(
          await request.cast<List<int>>().transform(utf8.decoder).join(),
        ) as Map;
        expect(body['store'], false);
        expect(body['instructions'], contains('automatically detected'));
        expect(body['reasoning'], {'effort': 'none'});
        request.response.write(
          jsonEncode({
            'status': 'completed',
            'output': [
              {'type': 'reasoning', 'summary': []},
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': '测试译文'},
                ],
              },
            ],
          }),
        );
      }
      await request.response.close();
    });
    final llm = LocalLlmService(
      cloudApi: CloudApi(
        MemoryCredentials(),
        clientFactory: () => FixtureHttpClient(server, []),
      ),
    );
    await llm.prepare('', 'gpt-5.6-luna', provider: LlmProvider.openAI);
    expect(await llm.translate('Test', 'auto', 'zh'), '测试译文');
    llm.stop();
  });
}
