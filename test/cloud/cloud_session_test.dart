import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/cloud/cloud_live.dart';
import 'package:altranscribe/data/services/cloud/cloud_live_session.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_test.dart' show MemoryCredentials, SocketFixture, send, voice;
import '../support/fakes.dart';

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for fixture');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

CloudLiveSession session(
  SocketFixture fixture, {
  void Function(CloudLiveText)? onText,
  void Function(String)? onError,
  void Function()? onRenewed,
  CloudSocketConnector? connect,
  Duration renewAfter = const Duration(minutes: 9),
  Duration renewBy = const Duration(minutes: 9, seconds: 30),
  Duration drainTimeout = const Duration(seconds: 1),
  bool direct = false,
}) {
  final live = CloudLiveSession(
    credentials: MemoryCredentials(),
    provider: SpeechProvider.gemini,
    directTranslation: direct,
    source: 'system',
    language: 'auto',
    targetLanguage: direct ? 'zh' : null,
    onText: onText ?? (_) {},
    onError: onError ?? (_) {},
    onRenewed: onRenewed,
    connect: connect ?? fixture.connect,
    renewAfter: renewAfter,
    renewBy: renewBy,
    drainTimeout: drainTimeout,
  );
  addTearDown(live.cancel);
  return live;
}

void finalText(WebSocket socket, String text) => send(socket, {
  'serverContent': {
    'inputTranscription': {'text': text},
    'generationComplete': true,
  },
});

void main() {
  test(
    'replacement quota rejection keeps the old tail and does not retry',
    () async {
      final errors = <String>[];
      final texts = <CloudLiveText>[];
      var setups = 0;
      final fixture = await SocketFixture.start((socket, event) {
        if (event.containsKey('setup')) {
          if (++setups == 1) {
            send(socket, {'setupComplete': {}});
          } else {
            send(socket, {
              'error': {'code': 429, 'message': 'dummy-test-key'},
            });
          }
        }
        if (event['realtimeInput']?['audioStreamEnd'] == true) {
          finalText(socket, 'saved');
        }
      });
      final live = session(fixture, onText: texts.add, onError: errors.add);
      await live.start();
      live.add(voice(1600), 0, 100);
      send(fixture.sockets.first, {
        'goAway': {'timeLeft': '60s'},
      });
      await until(() => errors.isNotEmpty);
      await expectLater(live.finish(), throwsStateError);
      expect(errors, ['cloudHttp429']);
      expect(texts.single.text, 'saved');
      expect(setups, 2);
    },
  );

  test('preconnect keeps sending old audio, switches at quiet, and drains distinct IDs', () async {
    final received = <WebSocket, List<int>>{};
    final texts = <String, CloudLiveText>{};
    final errors = <String>[];
    var renewals = 0;
    WebSocket? candidate;
    final fixture = await SocketFixture.start((socket, event) {
      if (event.containsKey('setup')) {
        received[socket] = [];
        if (received.length == 1) {
          send(socket, {'setupComplete': {}});
        } else {
          candidate = socket;
        }
      }
      final audio = event['realtimeInput']?['audio'];
      if (audio != null) {
        received[socket]!.addAll(base64Decode(audio['data'] as String));
      }
      if (event['realtimeInput']?['audioStreamEnd'] == true) {
        finalText(socket, 'part-${received.keys.toList().indexOf(socket)}');
      }
    });
    final live = session(
      fixture,
      onText: (text) => texts[text.id] = text,
      onError: errors.add,
      onRenewed: () => renewals++,
      renewAfter: const Duration(milliseconds: 100),
      renewBy: const Duration(seconds: 2),
    );
    await live.start();
    final first = voice(1600), second = voice(3200), quiet = Uint8List(32000);
    live.add(first, 500, 600);
    await until(() => candidate != null);
    live.add(second, 600, 800);
    await until(
      () => received.values.first.length == first.length + second.length,
    );
    expect(renewals, 0);
    send(candidate!, {'setupComplete': {}});
    live.add(quiet, 800, 1800);
    await until(() => renewals == 1);
    live.add(first, 1800, 1900);
    await live.finish();
    expect(errors, isEmpty);
    expect(received.values.first, [...first, ...second, ...quiet]);
    expect(received.values.last, first);
    expect(texts.length, 2);
    expect(texts.values.map((e) => e.text), ['part-0', 'part-1']);
    expect(texts.values.every((e) => e.finalized), isTrue);
    expect(texts.values.first.startMs, 500);
    expect(texts.values.first.endMs, 1800);
    expect(texts.values.last.startMs, 1800);
    expect(texts.values.last.endMs, 1900);
  });

  test(
    'continuous speech switches by deadline without waiting for silence',
    () async {
      var renewals = 0;
      final fixture = await SocketFixture.start((socket, event) {
        if (event.containsKey('setup')) send(socket, {'setupComplete': {}});
        if (event['realtimeInput']?['audioStreamEnd'] == true) {
          finalText(socket, 'final');
        }
      });
      final live = session(
        fixture,
        renewAfter: const Duration(milliseconds: 500),
        renewBy: const Duration(milliseconds: 700),
        onRenewed: () => renewals++,
      );
      await live.start();
      live.add(voice(1600), 0, 100);
      await until(() => renewals == 1);
      expect(fixture.sockets.length, 2);
      live.add(voice(1600), 100, 200);
      await live.finish();
    },
  );

  test('idle or paused capture renews repeatedly on connection age', () async {
    var renewals = 0;
    final fixture = await SocketFixture.start((socket, event) {
      if (event.containsKey('setup')) send(socket, {'setupComplete': {}});
    });
    final live = session(
      fixture,
      renewAfter: const Duration(milliseconds: 100),
      renewBy: const Duration(seconds: 1),
      onRenewed: () => renewals++,
    );
    await live.start();
    await until(() => renewals == 2);
    await live.finish();
    expect(fixture.sockets.length, 3);
  });

  test(
    'duplicate GoAway renews once; direct translation retains both streams',
    () async {
      final texts = <String, CloudLiveText>{};
      var renewals = 0;
      final fixture = await SocketFixture.start((socket, event) {
        if (event.containsKey('setup')) send(socket, {'setupComplete': {}});
        if (event['realtimeInput']?['audioStreamEnd'] == true) {
          send(socket, {
            'serverContent': {
              'inputTranscription': {'text': 'hello'},
              'outputTranscription': {'text': '你好'},
              'generationComplete': true,
            },
          });
        }
      });
      final live = session(
        fixture,
        direct: true,
        onText: (text) => texts[text.id] = text,
        onRenewed: () => renewals++,
      );
      await live.start();
      live.add(voice(1600), 0, 100);
      for (var i = 0; i < 2; i++) {
        send(fixture.sockets.first, {
          'goAway': {'timeLeft': '60.500s'},
        });
      }
      await until(() => renewals == 1);
      live.add(voice(1600), 100, 200);
      await live.finish();
      expect(fixture.sockets.length, 2);
      expect(texts.length, 2);
      expect(
        texts.values.every(
          (e) => e.text == 'hello' && e.translation == '你好' && e.finalized,
        ),
        isTrue,
      );
    },
  );

  for (final discard in [false, true]) {
    test(
      '${discard ? 'discard' : 'stop'} during pending replacement closes late socket without restarting',
      () async {
        final lateSocket = Completer<WebSocket>();
        var connections = 0;
        var renewals = 0;
        final errors = <String>[];
        final fixture = await SocketFixture.start((socket, event) {
          if (event.containsKey('setup')) send(socket, {'setupComplete': {}});
          if (event['realtimeInput']?['audioStreamEnd'] == true) {
            finalText(socket, 'saved');
          }
        });
        final live = session(
          fixture,
          onError: errors.add,
          onRenewed: () => renewals++,
          connect: (uri, headers) {
            connections++;
            return connections == 1
                ? fixture.connect(uri, headers)
                : lateSocket.future;
          },
        );
        await live.start();
        live.add(voice(1600), 0, 100);
        send(fixture.sockets.first, {
          'goAway': {'timeLeft': '60s'},
        });
        await until(() => connections == 2);
        if (discard) {
          live.cancel();
        } else {
          await live.finish();
        }
        final socket = await fixture.connect(Uri(), {});
        lateSocket.complete(socket);
        await until(() => socket.readyState == WebSocket.closed);
        expect(renewals, 0);
        expect(errors, isEmpty);
      },
    );
  }

  test(
    'replacement deadline stops explicitly, drains old text and never retries',
    () async {
      final errors = <String>[];
      final texts = <CloudLiveText>[];
      var setups = 0;
      final fixture = await SocketFixture.start((socket, event) {
        if (event.containsKey('setup') && ++setups == 1) {
          send(socket, {'setupComplete': {}});
        }
        if (event['realtimeInput']?['audioStreamEnd'] == true) {
          finalText(socket, 'saved tail');
        }
      });
      final live = session(
        fixture,
        onText: texts.add,
        onError: errors.add,
        renewAfter: const Duration(milliseconds: 80),
        renewBy: const Duration(milliseconds: 180),
      );
      await live.start();
      live.add(voice(1600), 0, 100);
      await until(() => errors.isNotEmpty);
      await expectLater(live.finish(), throwsStateError);
      expect(errors, ['cloudSessionRenewalFailed']);
      expect(texts.single.text, 'saved tail');
      expect(texts.single.finalized, isTrue);
      expect(setups, 2);
    },
  );

  test(
    'retiring tail timeout preserves interim text without declaring completion',
    () async {
      final errors = <String>[];
      final texts = <CloudLiveText>[];
      var renewals = 0;
      final fixture = await SocketFixture.start((socket, event) {
        if (event.containsKey('setup')) send(socket, {'setupComplete': {}});
        if (event['realtimeInput']?['audio'] != null) {
          send(socket, {
            'serverContent': {
              'interimInputTranscription': {'text': 'partial tail'},
            },
          });
        }
      });
      final live = session(
        fixture,
        onText: texts.add,
        onError: errors.add,
        onRenewed: () => renewals++,
        drainTimeout: const Duration(milliseconds: 100),
      );
      await live.start();
      live.add(voice(1600), 0, 100);
      await until(() => texts.isNotEmpty);
      send(fixture.sockets.first, {
        'goAway': {'timeLeft': '60s'},
      });
      await until(() => renewals == 1);
      await expectLater(live.finish(), throwsStateError);
      expect(errors, ['cloudIncomplete']);
      expect(texts.single.finalized, isFalse);
    },
  );

  test('imminent expiry preserves text and stops without attempting unsafe renewal', () async {
    final errors = <String>[];
    final fixture = await SocketFixture.start((socket, event) {
      if (event.containsKey('setup')) send(socket, {'setupComplete': {}});
    });
    final live = session(fixture, onError: errors.add);
    await live.start();
    send(fixture.sockets.first, {
      'goAway': {'timeLeft': '0.5s'},
    });
    await until(() => errors.isNotEmpty);
    await expectLater(live.finish(), throwsStateError);
    expect(errors, ['cloudSessionExpiring']);
    expect(fixture.sockets.length, 1);
  });

  test(
    'server close after confirmed drain is completion, not a lost connection',
    () async {
      final errors = <String>[];
      CloudLiveText? last;
      final fixture = await SocketFixture.start((socket, event) {
        if (event.containsKey('setup')) send(socket, {'setupComplete': {}});
        if (event['realtimeInput']?['audioStreamEnd'] == true) {
          send(socket, {
            'serverContent': {
              'inputTranscription': {'text': 'complete'},
              'outputTranscription': {'text': '完整'},
              'generationComplete': true,
            },
          });
          unawaited(socket.close());
        }
      });
      final live = session(
        fixture,
        direct: true,
        onText: (text) => last = text,
        onError: errors.add,
      );
      await live.start();
      live.add(voice(1600), 0, 100);
      await live.finish();
      expect(errors, isEmpty);
      expect(last!.finalized, isTrue);
      expect(last!.serverConfirmed, isTrue);
    },
  );

  test('controller keeps two sources, timestamps and renewed text in the same saved record', () async {
    final received = <WebSocket, bool>{};
    final fixture = await SocketFixture.start((socket, event) {
      if (event.containsKey('setup')) {
        received[socket] = false;
        send(socket, {'setupComplete': {}});
      }
      if (event['realtimeInput']?['audio'] != null) received[socket] = true;
      if (event['realtimeInput']?['audioStreamEnd'] == true &&
          received[socket]!) {
        finalText(socket, 'part-${received.keys.toList().indexOf(socket)}');
      }
    });
    final audio = FakeAudio();
    final store = MemoryStore();
    final controller = RealtimeController(
      audio: audio,
      engine: FakeEngine(),
      store: store,
      catalog: FakeModelCatalog(),
      translator: FakeTranslator(),
      credentials: MemoryCredentials(),
      cloudSocketConnector: fixture.connect,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.speechProvider = SpeechProvider.gemini;
    controller.cloudDirectTranslation = false;
    controller.generateSummary = false;
    await controller.start(microphone: true, system: true, language: 'en');
    final id = controller.record!.id;
    void frames(int start) {
      for (final source in ['microphone', 'system']) {
        audio.events.add({
          'type': 'frame',
          'source': source,
          'pcm': voice(1600),
          'startMs': start,
          'endMs': start + 100,
        });
      }
    }

    frames(1000);
    await until(() => received.values.every((e) => e));
    for (final socket in fixture.sockets.toList()) {
      send(socket, {
        'goAway': {'timeLeft': '60s'},
      });
    }
    await until(() => controller.record!.lines.length == 2);
    expect(controller.phase, SessionPhase.listening);
    frames(2000);
    await until(() => received.length == 4 && received.values.every((e) => e));
    await controller.stop();
    expect(controller.error, isNull);
    final saved = TranscriptRecord.fromJson(store.values[id]!);
    expect(saved.id, id);
    expect(saved.lines.length, 4);
    expect(saved.lines.map((e) => e.text).toSet().length, 4);
    expect(saved.lines.map((e) => e.source).toSet(), {'microphone', 'system'});
    expect(saved.lines.map((e) => e.startMs), [1000, 1000, 2000, 2000]);
    expect(saved.lines.every((e) => e.transcriptionStatus == 'done'), isTrue);
    expect(saved.dateTimeLabel, isNotEmpty);
  });
}
