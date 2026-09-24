// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'Android to real Windows GPU and LLM, files and two capture sources',
    (tester) async {
      await MobilePlatform.initialize();
      final root = Directory(MobilePlatform.dataDirectory!).parent;
      final setup = File('${root.path}/android-peer.json');
      final fixture = File('${root.path}/android-speech.wav');
      print('ANDROID_REMOTE_WAITING_FOR_FIXTURES');
      final setupDeadline = DateTime.now().add(const Duration(minutes: 3));
      while (!await setup.exists() || !await fixture.exists()) {
        if (DateTime.now().isAfter(setupDeadline)) {
          fail(
            'Push the generated peer configuration and synthetic speech fixture to the app private files directory',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final peer = jsonDecode(await setup.readAsString()) as Map;
      final audio = PlatformAudioService();
      final live = RealtimeController(
        audio: audio,
        engine: WhisperService(audio),
        store: RecordStore(Directory('${root.path}/remote-smoke')),
      );
      addTearDown(() async {
        await live.stop();
        live.dispose();
      });
      await live.initialize();
      live.generateSummary = true;
      final probe = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final response = await (await probe.getUrl(
          Uri.parse('${peer['address']}/v1/info'),
        )).close().timeout(const Duration(seconds: 10));
        print('ANDROID_REMOTE_HTTP_REACHABLE ${response.statusCode}');
        await response.drain<void>();
      } catch (error) {
        print(
          'ANDROID_REMOTE_HTTP_FAILURE $error',
        ); // No token was sent in this probe.
        rethrow;
      } finally {
        probe.close(force: true);
      }
      await live.connectRemote(
        peer['address'] as String,
        peer['token'] as String,
        peer['name'] as String,
      );
      await setup.delete(); // The pairing token is now Keystore-encrypted.
      expect(live.remoteProcessing, true);
      expect(live.localInferenceAllowed, false);
      await tester.pumpWidget(AltranscribeApp(realtime: live));
      await tester.pump(const Duration(milliseconds: 400));
      await live.startFiles(
        paths: [fixture.path],
        language: 'en',
        targetLanguage: 'zh',
        summaryLanguage: 'zh',
        options: const CleanupOptions(
          names: true,
          terms: true,
          corrections: true,
        ),
      );
      expect(live.error, isNull);
      final offline = live.records.first;
      expect(offline.status, 'completed');
      expect(
        offline.lines.map((line) => line.text).join(' ').toLowerCase(),
        contains('transcription'),
      );
      expect(
        offline.lines.every((line) => line.translationStatus == 'done'),
        true,
      );
      expect(offline.summaryStatus, 'done');
      expect(offline.cleanupStatus, 'done');
      await live.renameRecord(offline.id, '安卓文件联调');
      expect((await live.store.loadRecords()).first.title, '安卓文件联调');
      await live.deleteRecord(offline.id);
      expect(
        await File('${live.store.directory.path}/${offline.id}.json').exists(),
        false,
      );
      expect(await fixture.exists(), true);
      print('ANDROID_REMOTE_FILE_PASSED');

      live.generateSummary = false;
      print('ANDROID_REMOTE_WAITING_FOR_CAPTURE_PERMISSION');
      await live.start(
        microphone: true,
        system: true,
        language: 'en',
        targetLanguage: 'zh',
        summaryLanguage: 'zh',
      );
      expect(live.error, isNull);
      expect(live.readySources, containsAll(['microphone', 'system']));
      await tester.pump(const Duration(milliseconds: 400));
      live.setCaptionsVisible(true);
      print('ANDROID_REMOTE_PLAY_FIXTURE_NOW');
      // Open the Windows peer's test page in Chrome and play its known speech.
      // Native permissions and cross-app overlay appearance are inspected via ADB.
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (DateTime.now().isBefore(deadline)) {
        if (live.error != null) fail(live.error!);
        if (live.record!.lines.any(
          (line) => line.source == 'system' && line.translationStatus == 'done',
        )) {
          break;
        }
        // Frame pumping can wait forever while Android hides the activity.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(
        live.record!.lines.where((line) => line.source == 'system'),
        isNotEmpty,
      );
      expect(
        live.record!.lines.any(
          (line) => line.source == 'system' && line.translationStatus == 'done',
        ),
        true,
      );
      await live.togglePause();
      expect(live.phase, SessionPhase.paused);
      await live.stop();
      final captured = live.records.first;
      expect(captured.status, 'completed');
      expect(
        captured.lines.map((line) => line.text).join(' ').toLowerCase(),
        contains('transcription'),
      );
      expect(
        captured.lines
            .where((line) => line.source == 'system')
            .every((line) => line.translationStatus == 'done'),
        true,
      );
      await fixture.delete();
      expect(
        live.store.directory.listSync().where(
          (file) => file.path.endsWith('.wav'),
        ),
        isEmpty,
      );
      print(
        'ANDROID_REMOTE_CAPTURE_PASSED ${jsonEncode({'lines': captured.lines.length, 'backend': live.remoteConnection.info?['backend'], 'sources': captured.sources})}',
      );
    },
  );
}
