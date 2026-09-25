import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:altranscribe/data/services/remote/remote_services.dart';
import 'package:altranscribe/data/services/remote/shared_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real HTTP with local GPU Whisper and local LLM, no cloud or user audio',
    (tester) async {
      final dataRoot = Platform.environment['ALTRANSCRIBE_DATA_DIR']!;
      final directory = Directory('$dataRoot/remote-smoke');
      await directory.create(recursive: true);
      final localSettings = await RecordStore(Directory(dataRoot))
          .loadSettings();
      final executable =
          Platform.environment['ALTRANSCRIBE_WHISPER_EXECUTABLE'] ??
          localSettings['executable'] as String;
      final model =
          '${Platform.environment['ALTRANSCRIBE_MODELS_DIR']}/ggml-large-v3-turbo.bin';
      final llmModel = Platform.environment['ALTRANSCRIBE_TRANSLATION_MODEL']!;
      final interfaces = await sharingAddresses();
      final bind =
          interfaces
              .where((entry) => entry.$2.type == InternetAddressType.IPv4)
              .firstOrNull
              ?.$2 ??
          InternetAddress.loopbackIPv4;
      final engine = WhisperService(WindowsAudioService());
      final host = SharedHost(engine: engine, translator: LocalLlmService());
      final config = RemoteConnection();
      final speech = RemoteSpeechEngine(config);
      final llm = RemoteTranslationService(config);
      addTearDown(() async {
        await speech.stop();
        llm.stop();
        await host.stop();
        host.dispose();
      });
      await host.start(
        bindAddress: bind,
        port: 0,
        name: 'Altranscribe integration test',
        executable: executable,
        model: model,
        compute: ComputeMode.gpu,
        directory: directory,
        shareTranslation: true,
        llmProvider: LlmProvider.ollama,
        llmAddress: 'http://127.0.0.1:11434',
        llmModel: llmModel,
      );
      expect(engine.gpuActive, true);
      config.address = host.address;
      final pairedToken = (await host.devices.create('Smoke client')).token;
      config.token = pairedToken;
      await speech.start('', '', directory);
      await llm.prepare('', '');
      // Reuse only the known synthesized fixture from the prior smoke test.
      final fixture = File('$dataRoot/smoke/test-speech.wav');
      expect(
        await fixture.exists(),
        true,
        reason: 'Run dev.ps1 -Smoke first to create the synthesized fixture.',
      );
      final decoder = FfmpegAudioDecoder();
      final texts = <String>[];
      await for (final chunk in decoder.decode(fixture.path)) {
        texts.add(await speech.transcribe(pcmToWave(chunk.pcm), 'en'));
      }
      expect(texts.join(' ').toLowerCase(), contains('transcription'));
      final translated = await llm.translate(
        texts.join(' '),
        'en',
        'zh',
        context: const [
          TranslationContext(
            'We are testing transcription software.',
            '我们正在测试转录软件。',
          ),
        ],
      );
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(translated), true);
      final summary = await llm.summarize(texts, 'zh');
      expect(summary.title, isNotEmpty);
      // File routing uses the same remote services with real FFmpeg decoding and
      // client-side record persistence; no native microphone capture is started.
      final client = RealtimeController(
        audio: WindowsAudioService(),
        engine: WhisperService(WindowsAudioService()),
        store: RecordStore(Directory('${directory.path}/client')),
        translator: LocalLlmService(),
      );
      addTearDown(client.dispose);
      await client.initialize();
      await client.connectRemote(host.address, pairedToken, 'Smoke host');
      await client.startFiles(
        paths: [fixture.path],
        language: 'en',
        targetLanguage: 'zh',
        summaryLanguage: 'zh',
        options: const CleanupOptions(),
      );
      expect(client.error, isNull);
      final record = client.records.first;
      expect(record.speechProvider, 'whisperRemote');
      expect(record.summaryStatus, 'done');
      expect(
        record.lines.every((line) => line.translationStatus == 'done'),
        true,
      );
      expect(
        await File('${directory.path}/client/remote-host.credential').exists(),
        true,
      );
      final settingsText = await File('${directory.path}/client/settings.json')
          .readAsString();
      expect(settingsText, isNot(contains(pairedToken)));
      expect(host.running, true);
      await File('${directory.path}/report.json').writeAsString(
        jsonEncode({
          'transport':
              'HTTP over ${bind.isLoopback ? 'loopback' : 'local network interface'}',
          'backend': engine.backend,
          'llmModel': llmModel,
          'original': texts,
          'translation': translated,
          'summary': summary.title,
          'fileStatus': record.status,
          'hostSurvivesClientStop': host.running,
        }),
      );
      // Do not print the address, token, or decrypted credentials.
      // ignore: avoid_print
      print(
        'REMOTE_SMOKE_PASSED: ${engine.backend}; real LLM; real file routing; encrypted pairing',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
