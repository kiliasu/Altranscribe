// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:material_ui/material_ui.dart';

// Windows peer for physical-phone integration tests. No simulated model APIs.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) throw StateError('Run this peer on Windows');
  final live = RealtimeController.local();
  await live.initialize();
  runApp(AltranscribeApp(realtime: live));
  final addresses = await sharingAddresses();
  final bind = addresses
      .firstWhere((entry) => entry.$2.address.startsWith('192.168.'))
      .$2;
  final directory = await Directory('${live.store.directory.path}/android-peer')
      .create(recursive: true);
  await live.sharedHost.start(
    bindAddress: bind,
    port: 0,
    name: 'Altranscribe Windows',
    executable: live.executable,
    model:
        '${Platform.environment['ALTRANSCRIBE_MODELS_DIR']}/ggml-large-v3-turbo.bin',
    compute: ComputeMode.gpu,
    directory: directory,
    shareTranslation: true,
    llmProvider: LlmProvider.ollama,
    llmAddress: 'http://127.0.0.1:11434',
    llmModel: Platform.environment['ALTRANSCRIBE_TRANSLATION_MODEL']!,
  );
  // The phone test pairs like a real client would, with a code and the address.
  final paired = await live.sharedHost.devices.create('Android test phone');
  await File('${live.store.directory.path}/android-peer.json').writeAsString(
    jsonEncode({
      'address': live.sharedHost.address,
      'token': paired.token,
      'pairingCode': live.sharedHost.devices.beginPairing(),
      'name': 'Altranscribe Windows',
    }),
    flush: true,
  );
  // Connection tokens are deliberately absent from diagnostic output.
  print(
    'ANDROID_PEER_READY ${live.sharedHost.address} ${live.sharedHost.info['backend']}',
  );
  final media = await HttpServer.bind(bind, 0);
  print('ANDROID_FIXTURE_READY http://${bind.address}:${media.port}/');
  media.listen((request) async {
    if (request.uri.path == '/speech.wav') {
      request.response.headers.contentType = ContentType('audio', 'wav');
      await request.response.addStream(
        File('${live.store.directory.path}/smoke/test-speech.wav').openRead(),
      );
    } else {
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><meta name="viewport" content="width=device-width"><title>Altranscribe audio test</title>'
        '<h1>Altranscribe audio test</h1><p>Known synthesized speech. Tap play to test system capture.</p>'
        '<audio controls loop src="/speech.wav"></audio>',
      );
    }
    await request.response.close();
  });
}
