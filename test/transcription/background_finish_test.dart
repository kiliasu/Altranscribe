import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../cloud/cloud_test.dart' show MemoryCredentials, SocketFixture, send;
import '../support/fakes.dart';
import 'realtime_test.dart' show until;

void main() {
  test('stop and save returns after durable snapshot while cloud tail and summary finish', () async {
    final root = Directory('build/test-data');
    await root.create(recursive: true);
    final directory = await root.createTemp('background-finish-');
    addTearDown(() => directory.delete(recursive: true));
    final closing = Completer<WebSocket>();
    final fixture = await SocketFixture.start((socket, event) {
      if (event['type'] == 'session.update') {
        send(socket, {'type': 'session.updated'});
        send(socket, {
          'type': 'session.input_transcript.delta',
          'delta': 'Already received.',
        });
        send(socket, {
          'type': 'session.output_transcript.delta',
          'delta': '已收到。',
        });
      } else if (event['type'] == 'session.close') {
        closing.complete(socket);
      }
    });
    final audio = FakeAudio();
    final translator = FakeTranslator()
      ..summaryResponse = Completer<RecordSummary>();
    final store = RecordStore(directory);
    final controller = RealtimeController(
      audio: audio,
      engine: FakeEngine(),
      store: store,
      catalog: FakeModelCatalog(),
      translator: translator,
      credentials: MemoryCredentials(),
      cloudSocketConnector: fixture.connect,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.speechProvider = SpeechProvider.openAI;
    await controller.start(
      microphone: true,
      system: false,
      language: 'en',
      targetLanguage: 'zh',
    );
    await until(() => controller.record!.lines.isNotEmpty);
    controller.setCaptionsVisible(true);
    await controller.stopAndSave().timeout(const Duration(seconds: 2));
    final id = controller.record!.id;
    final file = File('${directory.path}/$id.json');
    final snapshot = jsonDecode(await file.readAsString()) as Map;
    expect(snapshot['status'], 'finishing');
    expect(
      (snapshot['lines'] as List).first['text'],
      contains('Already received'),
    );
    expect(audio.stops, 1);
    expect(controller.backgroundFinishing, isTrue);
    expect(controller.captionsVisible, isFalse);
    expect(controller.records.single.status, 'finishing');
    expect(controller.canEditRecord(controller.records.single), isFalse);
    expect((await store.loadRecords()).single.status, 'interrupted');
    await controller.start(microphone: true, system: false, language: 'en');
    expect(controller.record!.id, id);

    final socket = await closing.future;
    send(socket, {
      'type': 'session.input_transcript.delta',
      'delta': ' Late tail.',
    });
    send(socket, {'type': 'session.output_transcript.delta', 'delta': '最后一句。'});
    send(socket, {'type': 'session.closed'});
    await until(() => translator.summaryCalls.isNotEmpty);
    expect(controller.backgroundFinishing, isTrue);
    translator.summaryResponse!.complete(const RecordSummary('标题', '摘要'));
    await controller.stop();
    final completed = (await store.loadRecords()).single;
    expect(controller.phase, SessionPhase.idle);
    expect(controller.backgroundFinishing, isFalse);
    expect(completed.status, 'completed');
    expect(
      completed.lines.map((line) => line.text).join(' '),
      contains('Late tail.'),
    );
    expect(
      completed.lines.map((line) => line.translation).join(),
      contains('最后一句。'),
    );
    expect(completed.title, '标题');
    expect(completed.summary, '摘要');
  });
}
