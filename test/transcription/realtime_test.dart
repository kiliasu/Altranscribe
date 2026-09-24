import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test(
    'volume history stays independent, bounded, frozen on pause and resets',
    () async {
      final controller = fakeController();
      addTearDown(controller.dispose);
      final audio = controller.audio as FakeAudio;
      Map<String, Object?> level(String source, double value) => {
        'type': 'level',
        'source': source,
        'level': value,
      };
      await controller.start(microphone: true, system: true, language: 'zh');
      audio.events.addAll([
        level('microphone', .1),
        level('system', .7),
        level('microphone', 0),
      ]);
      await until(() => controller.levelHistory['microphone']?.length == 2);
      expect(controller.levelHistory['microphone'], [.1, 0]);
      expect(controller.levelHistory['system'], [.7]);
      await controller.togglePause();
      audio.events.addAll([level('microphone', 0), level('system', 0)]);
      await until(() => controller.levels['system'] == 0);
      expect(controller.levelHistory['microphone'], [.1, 0]);
      expect(controller.levelHistory['system'], [.7]);
      await controller.togglePause();
      audio.events.addAll(
        List.generate(100, (i) => level('microphone', i / 100)),
      );
      await until(() => controller.levels['microphone'] == .99);
      expect(controller.levelHistory['microphone']!.length, 77);
      expect(controller.levelHistory['microphone']!.first, .23);
      expect(controller.levelHistory['microphone']!.last, .99);
      expect(controller.levelHistory['system'], [.7]);
      await controller.stop();
      expect(controller.levelHistory, isEmpty);
      await controller.start(microphone: true, system: false, language: 'zh');
      expect(controller.levelHistory, isEmpty);
      await controller.stop();
    },
  );

  test(
    'Whisper startup cancelled at its first await never launches a process',
    () async {
      final engine = WhisperService(FakeAudio());
      // Existing non-executable files pass the path check. Cancellation must happen
      // before Process.start could attempt to execute one.
      final future = engine.start(
        'pubspec.yaml',
        'pubspec.yaml',
        Directory('build'),
      );
      final assertion = expectLater(future, throwsA(isA<HttpException>()));
      await engine.stop();
      await assertion;
    },
  );

  test(
    'WAV payload preserves PCM and declares the actual native audio format',
    () {
      final bytes = pcmToWave(Uint8List.fromList([0, 0, 255, 127]));
      final header = ByteData.sublistView(bytes);
      expect(String.fromCharCodes(bytes.take(4)), 'RIFF');
      expect(header.getUint32(4, Endian.little), 40);
      expect(header.getUint16(22, Endian.little), 1);
      expect(header.getUint32(24, Endian.little), 16000);
      expect(header.getUint16(34, Endian.little), 16);
      expect(header.getUint32(40, Endian.little), 4);
      expect(bytes.sublist(44), [0, 0, 255, 127]);
    },
  );

  test(
    'independent sources, pause, final tail and chronological saved results',
    () async {
      final controller = fakeController();
      addTearDown(controller.dispose);
      final audio = controller.audio as FakeAudio;
      final engine = controller.engine as FakeEngine;
      await controller.start(microphone: true, system: true, language: 'zh');
      expect(controller.readySources, {'microphone', 'system'});
      expect(audio.options!['microphoneDenoise'], true);
      expect(audio.options!['microphoneAutoGain'], true);
      expect(audio.options!['systemDenoise'], false);
      expect(audio.options!['systemAutoGain'], false);
      await controller.togglePause();
      expect(audio.paused, isTrue);
      expect(controller.phase, SessionPhase.paused);
      await controller.togglePause();
      audio.events.add(chunk('system', 2000));
      await until(() => controller.record!.lines.length == 1);
      audio.finalEvents.add(chunk('microphone', 500));
      await controller.stop();
      expect(controller.phase, SessionPhase.idle);
      expect(engine.languages, ['zh', 'zh']);
      expect(controller.records.single.lines.map((line) => line.source), [
        'microphone',
        'system',
      ]);
      expect(controller.records.single.status, 'completed');
      expect(controller.pending, 0);
      await controller.start(microphone: false, system: true, language: 'en');
      expect(audio.options!['microphone'], false);
      expect(audio.options!['system'], true);
      await controller.stop();
    },
  );

  test(
    'stop waits for queued inference instead of losing the final chunk',
    () async {
      final controller = fakeController();
      addTearDown(controller.dispose);
      final audio = controller.audio as FakeAudio;
      final engine = controller.engine as FakeEngine;
      engine.response = Completer<String>();
      await controller.start(microphone: true, system: false, language: 'en');
      audio.events.add(chunk('microphone', 0));
      await until(() => controller.recognizing);
      audio.finalEvents.add(chunk('microphone', 2000));
      final stopped = controller.stop();
      expect(controller.phase, SessionPhase.stopping);
      expect(engine.stops, 0);
      engine.response!.complete('Finished speech');
      await stopped;
      expect(controller.records.single.lines.length, 2);
      expect(engine.stops, 1);
    },
  );

  test('startup cancellation releases engine and never starts audio', () async {
    final controller = fakeController();
    addTearDown(controller.dispose);
    final engine = controller.engine as FakeEngine;
    engine.loading = Completer<void>();
    final started = controller.start(
      microphone: true,
      system: true,
      language: 'en',
    );
    await until(() => engine.starts == 1);
    await controller.stop();
    await started;
    expect((controller.audio as FakeAudio).options, isNull);
    expect(controller.error, isNull);
    expect(controller.phase, SessionPhase.idle);
  });

  test(
    'a failed audio source stops the complete session and reports the error',
    () async {
      final controller = fakeController();
      addTearDown(controller.dispose);
      (controller.audio as FakeAudio).failure = 'Access denied';
      await controller.start(microphone: true, system: true, language: 'en');
      await until(() => controller.phase == SessionPhase.idle);
      expect(controller.error, contains('Access denied'));
      expect((controller.audio as FakeAudio).stops, 1);
    },
  );

  test('overload stops capture and keeps all accepted chunks', () async {
    final controller = fakeController();
    addTearDown(controller.dispose);
    final engine = controller.engine as FakeEngine;
    engine.response = Completer<String>();
    await controller.start(microphone: false, system: true, language: 'en');
    (controller.audio as FakeAudio).events.addAll(
      List.generate(10, (i) => chunk('system', i * 2000)),
    );
    await until(() => controller.phase == SessionPhase.stopping);
    expect(controller.warning, 'tooSlow');
    engine.response!.complete('Speech');
    await controller.stop();
    expect(controller.record!.lines.length, 10);
    expect(controller.record!.status, 'error');
  });

  test(
    'recognition failure stops capture without inventing any transcript',
    () async {
      final controller = fakeController();
      addTearDown(controller.dispose);
      await controller.start(microphone: true, system: false, language: 'en');
      (controller.engine as FakeEngine).failure = 'Engine exited';
      (controller.audio as FakeAudio).events.add(chunk('microphone', 0));
      await until(() => controller.phase == SessionPhase.idle);
      expect(controller.error, contains('Engine exited'));
      expect(controller.record!.lines, isEmpty);
    },
  );

  test(
    'records survive reopening and interrupted sessions are labeled honestly',
    () async {
      final root = Directory('build/test-data');
      await root.create(recursive: true);
      final directory = await root.createTemp('records-');
      addTearDown(() => directory.delete(recursive: true));
      final store = RecordStore(directory);
      await store.initialize();
      await store.saveSettings({'model': 'C:/模型/turbo.bin'});
      await store.saveSettings({'model': 'C:/模型/large.bin'});
      final record = TranscriptRecord(
        id: 'session-123',
        createdAt: DateTime(2026),
        language: 'zh',
        sources: ['system'],
        lines: [
          TranscriptLine(
            source: 'system',
            startMs: 20,
            endMs: 2000,
            text: '你好，世界。',
          ),
        ],
      );
      await store.save(record);
      final reopened = RecordStore(directory);
      expect((await reopened.loadSettings())['model'], 'C:/模型/large.bin');
      expect((await reopened.loadRecords()).single.status, 'interrupted');
      record.status = 'completed';
      await store.save(record);
      final saved = (await reopened.loadRecords()).single;
      expect(saved.status, 'completed');
      expect(saved.lines.single.text, '你好，世界。');
    },
  );
}
