import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'quality_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows WASAPI + existing Whisper model, no simulated services', (
    tester,
  ) async {
    final root = Platform.environment['ALTRANSCRIBE_WHISPER_DIR'];
    final gpu = Platform.environment['ALTRANSCRIBE_COMPUTE_MODE'] == 'gpu';
    final executable =
        Platform.environment['ALTRANSCRIBE_WHISPER_EXECUTABLE'] ??
        '$root/build/bin/whisper-server.exe';
    final translationModel =
        Platform.environment['ALTRANSCRIBE_TRANSLATION_MODEL'];
    expect(
      root,
      isNotNull,
      reason: 'Run dev.ps1 -Smoke -WhisperDirectory <whisper.cpp directory>',
    );
    final directory = Directory(
      '${Platform.environment['ALTRANSCRIBE_DATA_DIR']}/smoke',
    );
    await directory.create(recursive: true);
    final audio = WindowsAudioService();
    final engine = WhisperService(audio);
    addTearDown(() async {
      await audio.stop();
      await engine.stop();
    });
    final devices = await audio.devices();
    expect(
      devices.where((device) => device['source'] == 'microphone'),
      isNotEmpty,
    );
    expect(devices.where((device) => device['source'] == 'system'), isNotEmpty);

    // Invalid selection must produce a real error instead of falling back silently.
    await audio.start({
      'microphone': true,
      'microphoneDevice': 'missing-test-device',
    });
    final invalid = <Map<String, Object?>>[];
    for (int i = 0; i < 40 && invalid.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      invalid.addAll(await audio.poll());
    }
    expect(invalid.any((event) => event['type'] == 'error'), isTrue);
    await audio.stop();

    // Local Windows speech synthesis creates known test input, never user recordings.
    final wave = File('${directory.path}/test-speech.wav').absolute;
    final quoted = "'${wave.path.replaceAll("'", "''")}'";
    final generated = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Add-Type -AssemblyName System.Speech; '
          r'$voice = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
          r'$voice.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::NotSet, [System.Speech.Synthesis.VoiceAge]::NotSet, 0, [System.Globalization.CultureInfo]::GetCultureInfo("en-US")); '
          '\$voice.SetOutputToWaveFile($quoted); '
          r'$voice.Speak("This is a local transcription test. The microphone and system audio can run together."); '
          r'$voice.Dispose();',
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    if (gpu) {
      await expectLater(
        engine.start(
          '$root/build/bin/whisper-server.exe',
          '$root/models/ggml-large-v3-turbo.bin',
          directory,
          compute: ComputeMode.gpu,
        ),
        throwsFormatException,
      );
      await engine.start(
        executable,
        '$root/models/ggml-large-v3-turbo.bin',
        directory,
        compute: ComputeMode.cpu,
      );
      expect(engine.gpuActive, isFalse);
      expect(engine.backend, startsWith('CPU'));
      await engine.stop();
    }
    await engine.start(
      executable,
      '$root/models/ggml-large-v3-turbo.bin',
      directory,
      compute: gpu ? ComputeMode.gpu : ComputeMode.automatic,
    );
    if (gpu) expect(engine.gpuActive, isTrue);
    await audio.start({
      'microphone': true,
      'system': true,
      'systemDenoise': true,
      'systemAutoGain': true,
    });
    final ready = <String>{};
    final chunks = <Map<String, Object?>>[];
    final previews = <Map<String, Object?>>[];
    final errors = <Object?>[];
    double systemPeak = 0;
    void collect(List<Map<String, Object?>> events) {
      for (final event in events) {
        if (event['type'] == 'ready') ready.add(event['source'] as String);
        if (event['type'] == 'error') errors.add(event['message']);
        if (event['source'] == 'system' && event['type'] == 'chunk') {
          (event['partial'] == true ? previews : chunks).add(event);
        }
        if (event['source'] == 'system' && event['type'] == 'level') {
          final value = (event['level'] as num).toDouble();
          if (value > systemPeak) systemPeak = value;
        }
      }
    }

    for (int i = 0; i < 80 && ready.length < 2 && errors.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      collect(await audio.poll());
    }
    expect(errors, isEmpty);
    expect(ready, {'microphone', 'system'});
    await audio.pause(true);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await audio.pause(false);
    final playback = Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "\$player = New-Object System.Media.SoundPlayer($quoted); \$player.PlaySync(); \$player.Dispose();",
    ]);
    bool finished = false;
    final played = playback.then((value) {
      finished = true;
      return value;
    });
    while (!finished) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      collect(await audio.poll());
    }
    expect((await played).exitCode, 0);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    collect(await audio.stop());
    expect(errors, isEmpty);
    expect(systemPeak, greaterThan(.002));
    expect(chunks, isNotEmpty);
    expect(previews, isNotEmpty);
    expect(
      (previews.first['endMs'] as int) - (previews.first['startMs'] as int),
      lessThanOrEqualTo(3010),
    );
    expect(
      chunks.length,
      1,
      reason: 'A short pause inside the utterance must not split it',
    );
    final pcm = BytesBuilder();
    for (final chunk in chunks) {
      pcm.add(chunk['pcm'] as Uint8List);
    }
    final clock = Stopwatch()..start();
    final speechPcm = pcm.takeBytes();
    final text = await engine.transcribe(pcmToWave(speechPcm), 'en');
    final inferenceSeconds = clock.elapsedMilliseconds / 1000;
    final previewClock = Stopwatch()..start();
    final previewText = await engine.transcribe(
      pcmToWave(previews.first['pcm'] as Uint8List),
      'en',
    );
    final previewSeconds = previewClock.elapsedMilliseconds / 1000;
    expect(
      previewText,
      isNotEmpty,
      reason: 'Early speech must already produce visible words',
    );
    final report = {
      'devices': devices.length,
      'readySources': ready.toList(),
      'systemPeak': systemPeak,
      'systemChunks': chunks.length,
      'previewCount': previews.length,
      'backend': engine.backend,
      'inferenceSeconds': inferenceSeconds,
      'firstPreviewText': previewText,
      'firstPreviewInferenceSeconds': previewSeconds,
      'text': text,
    };
    await File('${directory.path}/report.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    // ignore: avoid_print
    print('REAL AUDIO REPORT: ${jsonEncode(report)}');
    expect(text.toLowerCase(), contains('transcription'));
    expect(text.toLowerCase(), contains('system'));
    await checkTranscriptionQuality(engine, directory, speechPcm);
    await engine.stop();

    // Exercise the same controller used by the UI, including final inference and persistence.
    final store = RecordStore(Directory('${directory.path}/controller'));
    final controller = RealtimeController(
      audio: audio,
      engine: engine,
      store: store,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.generateSummary = translationModel != null;
    if (Platform.environment.containsKey('ALTRANSCRIBE_MODELS_DIR')) {
      expect(
        controller.model,
        startsWith(Platform.environment['ALTRANSCRIBE_MODELS_DIR']!),
      );
    }
    await controller.start(
      microphone: false,
      system: true,
      language: 'en',
      targetLanguage: translationModel == null ? null : 'zh',
      summaryLanguage: 'zh',
    );
    expect(controller.phase, SessionPhase.listening, reason: controller.error);
    final secondPlayback = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "\$player = New-Object System.Media.SoundPlayer($quoted); \$player.PlaySync(); \$player.Dispose();",
    ]);
    expect(secondPlayback.exitCode, 0);
    await controller.stop();
    expect(controller.error, isNull);
    final restored = (await store.loadRecords()).first;
    expect(restored.status, 'completed');
    expect(restored.lines.every((line) => line.source == 'system'), isTrue);
    expect(
      restored.lines.map((line) => line.text).join(' ').toLowerCase(),
      contains('transcription'),
    );
    if (translationModel != null) {
      expect(restored.summaryStatus, 'done', reason: restored.summaryError);
      expect(restored.title, isNotEmpty);
      expect(restored.summary, isNotEmpty);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(restored.title!), isTrue);
      expect(
        restored.lines.every((line) => line.translationStatus == 'done'),
        isTrue,
        reason: restored.lines.map((line) => line.translationError).join(', '),
      );
      expect(
        restored.lines.every(
          (line) => RegExp(r'[\u4e00-\u9fff]').hasMatch(line.translation ?? ''),
        ),
        isTrue,
      );
      await File('${directory.path}/translated-report.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'backend': controller.engine.backend,
          'translationModel': translationModel,
          'lastInferenceSeconds': controller.lastInferenceSeconds,
          'lastTranslationSeconds': controller.lastTranslationSeconds,
          'record': restored.toJson(),
        }),
      );
      // ignore: avoid_print
      print('REAL TRANSLATION REPORT: ${jsonEncode(restored.toJson())}');
      // Validate the OpenAI-compatible wire protocol against Ollama's
      // compatibility endpoint.
      final compatible = LocalLlmService();
      try {
        await compatible.prepare(
          'http://127.0.0.1:11434/v1',
          translationModel,
          provider: LlmProvider.openAICompatible,
        );
        final translation = await compatible.translate(
          'This is a local transcription test.',
          'en',
          'zh',
        );
        expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(translation), isTrue);
        final summary = await compatible.summarize(
          restored.lines.map((line) => line.text).toList(),
          'zh',
        );
        expect(summary.title, isNotEmpty);
        expect(summary.summary, isNotEmpty);
        await File('${directory.path}/compatible-report.json').writeAsString(
          jsonEncode({
            'provider': 'openAICompatible',
            'server': 'Ollama compatibility endpoint',
            'translation': translation,
            'title': summary.title,
            'summary': summary.summary,
          }),
        );
      } finally {
        compatible.stop();
      }
      // Exercise Library actions on a saved transcript without generated metadata.
      final archived = TranscriptRecord(
        id: 'session-${DateTime.now().microsecondsSinceEpoch}',
        createdAt: restored.createdAt,
        language: restored.language,
        targetLanguage: restored.targetLanguage,
        translationModel: restored.translationModel,
        sources: restored.sources,
        lines: restored.lines,
        status: 'completed',
      );
      await store.save(archived);
      controller.records = await store.loadRecords();
      await controller.generateRecordSummary(archived.id, 'zh');
      final generated = controller.records.firstWhere(
        (item) => item.id == archived.id,
      );
      expect(generated.title, isNotEmpty);
      expect(generated.summaryStatus, 'done');
      expect(
        generated.lines.map((line) => line.toJson()).toList(),
        archived.lines.map((line) => line.toJson()).toList(),
      );
      await controller.renameRecord(archived.id, '重命名联调记录');
      final renamed = (await store.loadRecords()).firstWhere(
        (item) => item.id == archived.id,
      );
      expect(renamed.title, '重命名联调记录');
      expect(renamed.summary, generated.summary);
      await File('${directory.path}/record-actions-report.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'generatedTitle': generated.title,
          'record': renamed.toJson(),
        }),
      );
      await controller.deleteRecord(archived.id);
      expect(
        (await store.loadRecords()).any((item) => item.id == archived.id),
        false,
      );
    }
    // Use only a test session in the smoke directory for destructive actions.
    await controller.start(microphone: true, system: true, language: 'en');
    expect(controller.phase, SessionPhase.listening, reason: controller.error);
    final discardedId = controller.record!.id;
    await controller.togglePause();
    expect(controller.phase, SessionPhase.paused);
    await controller.discard();
    expect(controller.phase, SessionPhase.idle);
    expect(controller.error, isNull);
    expect(controller.record, isNull);
    final afterDiscard = await store.loadRecords();
    expect(afterDiscard.any((item) => item.id == discardedId), false);
    expect(afterDiscard.any((item) => item.id == restored.id), true);
    await File('${directory.path}/discard-report.json').writeAsString(
      jsonEncode({
        'pausedBeforeDiscard': true,
        'discardedId': discardedId,
        'recordRemoved': true,
        'previousRecordPreserved': true,
      }),
    );
    // Decode a real compressed file, including non-ASCII and spaces in its path.
    final mp3 = File('${directory.path}/离线 测试.mp3').absolute;
    final converted = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-i',
      wave.path,
      '-c:a',
      'libmp3lame',
      mp3.path,
    ]);
    expect(converted.exitCode, 0, reason: '${converted.stderr}');
    // A longer decode checks boundaries and byte accounting without storing
    // decoded audio or depending on Whisper's wording at a cut.
    final longer = File('${directory.path}/long-test.wav');
    final looped = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-stream_loop',
      '5',
      '-i',
      wave.path,
      '-t',
      '35',
      '-ar',
      '16000',
      '-ac',
      '1',
      longer.path,
    ]);
    expect(looped.exitCode, 0);
    final decoder = FfmpegAudioDecoder();
    var bytes = 0;
    var endMs = 0;
    var fileChunks = 0;
    await for (final chunk in decoder.decode(longer.path)) {
      expect(chunk.startMs, endMs);
      expect(chunk.pcm.length, lessThanOrEqualTo(20 * 32000));
      bytes += chunk.pcm.length;
      endMs = chunk.endMs;
      fileChunks++;
    }
    expect(fileChunks, greaterThan(1));
    expect(bytes, 35 * 32000);
    await controller.startFiles(
      paths: [mp3.path],
      language: 'en',
      targetLanguage: translationModel == null ? null : 'zh',
      summaryLanguage: 'zh',
      options: CleanupOptions(
        names: translationModel != null,
        terms: translationModel != null,
        corrections: translationModel != null,
      ),
    );
    expect(controller.error, isNull);
    final offline = controller.record!;
    expect(offline.status, 'completed', reason: offline.error);
    expect(offline.lines, isNotEmpty);
    expect(
      offline.lines.map((line) => line.text).join(' ').toLowerCase(),
      contains('transcription'),
    );
    expect(offline.lines.every((line) => line.source == 'file'), true);
    if (translationModel != null) {
      expect(offline.cleanupStatus, 'done', reason: offline.cleanupError);
      expect(offline.summaryStatus, 'done', reason: offline.summaryError);
      expect(
        offline.lines.every((line) => line.translationStatus == 'done'),
        true,
      );
      final cleanup = LocalLlmService();
      try {
        await cleanup.prepare('http://127.0.0.1:11434', translationModel);
        final result = await cleanup.cleanUp(
          [
            'Alice uses Kubernetes. Alice uses Kubernetes again. '
                'Alcie uses Kubernets. Please recieve the file; receive the file; receive it.',
          ],
          const CleanupOptions(
            names: true,
            terms: true,
            corrections: true,
            spellings: ['Alice', 'Kubernetes', 'receive'],
          ),
        );
        expect(result.texts.single, contains('receive'));
        expect(result.edits.single, isNotEmpty);
        await File('${directory.path}/cleanup-report.json').writeAsString(
          jsonEncode({
            'texts': result.texts,
            'edits': result.edits.single.map((edit) => edit.toJson()).toList(),
          }),
        );
      } finally {
        cleanup.stop();
      }
    }
    final reopened = (await store.loadRecords()).firstWhere(
      (r) => r.id == offline.id,
    );
    expect(reopened.toJson(), offline.toJson());
    await File('${directory.path}/file-report.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(offline.toJson()),
    );
  }, timeout: const Timeout(Duration(minutes: 6)));
}
