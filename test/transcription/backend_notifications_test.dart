import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../cloud/cloud_test.dart'
    show MemoryCredentials, SocketFixture, send, voice;
import '../support/fakes.dart';
import 'realtime_test.dart' show until;

void main() {
  test('streaming audio reaches the engine without redundant display notifications', () async {
    var frames = 0;
    final fixture = await SocketFixture.start((socket, event) {
      if (event.containsKey('setup')) send(socket, {'setupComplete': {}});
      if (event['realtimeInput']?['audio'] != null) frames++;
    });
    final audio = FakeAudio();
    final live =
        RealtimeController(
            audio: audio,
            engine: FakeEngine(),
            store: MemoryStore(),
            translator: FakeTranslator(),
            credentials: MemoryCredentials(),
            cloudSocketConnector: fixture.connect,
          )
          ..initialized = true
          ..generateSummary = false
          ..speechProvider = SpeechProvider.gemini;
    addTearDown(live.dispose);
    await live.start(microphone: true, system: false, language: 'en');
    var notifications = 0;
    live.addListener(() => notifications++);
    audio.events.addAll([
      for (var i = 0; i < 20; i++)
        {
          'type': 'frame',
          'source': 'microphone',
          'pcm': voice(160),
          'startMs': i * 10,
          'endMs': (i + 1) * 10,
        },
    ]);
    await until(() => frames == 20);
    expect(notifications, 0);
    send(fixture.sockets.single, {
      'serverContent': {
        'inputTranscription': {'text': 'A visible update.'},
        'generationComplete': true,
      },
    });
    await until(() => live.record!.lines.isNotEmpty);
    expect(notifications, greaterThan(0));
    expect(live.record!.lines.single.text, 'A visible update.');
    notifications = 0;
    audio.events.add({'type': 'level', 'source': 'microphone', 'level': .5});
    await until(() => live.levels['microphone'] == .5);
    expect(notifications, 1);
    await live.stop();
    expect(live.records.single.lines.single.text, 'A visible update.');
  });
}
