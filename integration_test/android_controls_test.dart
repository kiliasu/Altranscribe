// ignore_for_file: avoid_print

import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/models/caption_preferences.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:integration_test/integration_test.dart';

// Real system-only capture and real remote inference. ADB operates the separate
// native caption window; each stage checks the resulting controller/disk state.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Android overlay controls across apps', (tester) async {
    await MobilePlatform.initialize();
    final root = Directory(MobilePlatform.dataDirectory!).parent;
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
    await live.connectRemote(
      live.remoteConnection.address,
      live.remoteConnection.token,
      live.remoteConnection.name,
    );
    live.generateSummary = false;
    await live.setCaptionPreferences(const CaptionPreferences(fontSize: 20));
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pump(const Duration(milliseconds: 300));
    Future<void> waitFor(String stage, bool Function() condition) async {
      print('ANDROID_CONTROLS_WAIT $stage');
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (!condition()) {
        if (live.error != null) fail(live.error!);
        if (DateTime.now().isAfter(deadline)) fail('Timed out: $stage');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      print('ANDROID_CONTROLS_PASSED $stage');
    }

    await live.start(
      microphone: false,
      system: true,
      language: 'en',
      targetLanguage: 'zh',
      summaryLanguage: 'zh',
    );
    expect(live.readySources, ['system']);
    live.setCaptionsVisible(true);
    await waitFor(
      'PLAY_SYSTEM_SPEECH',
      () => live.record!.lines.any((line) => line.translationStatus == 'done'),
    );
    await waitFor('FONT_LARGER', () => live.captionPreferences.fontSize == 22);
    await waitFor('FONT_SMALLER', () => live.captionPreferences.fontSize == 20);
    await waitFor(
      'DISCARD_DIALOG',
      () =>
          live.discardConfirmationPending && live.phase == SessionPhase.paused,
    );
    expect(live.phase, SessionPhase.paused);
    await waitFor('CANCEL_DISCARD', () => !live.discardConfirmationPending);
    expect(live.phase, SessionPhase.paused);
    expect(
      await File('${live.store.directory.path}/${live.record!.id}.json')
          .exists(),
      true,
    );
    await waitFor('RESUME', () => live.phase == SessionPhase.listening);
    await waitFor('STOP_AND_SAVE', () => !live.active);
    expect(live.records.first.lines, isNotEmpty);
    expect(live.records.first.status, 'completed');
    print('ANDROID_CONTROLS_FIRST_SESSION_SAVED');

    // New capture starts from the app, as required by Android's microphone
    // foreground-service permission. Stop must have released the old service.
    await waitFor(
      'RETURN_TO_APP',
      () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    await live.start(
      microphone: true,
      system: false,
      language: 'en',
      targetLanguage: null,
      summaryLanguage: 'zh',
    );
    expect(live.error, isNull);
    expect(live.readySources, ['microphone']);
    final discarded = live.record!.id;
    live.setCaptionsVisible(true);
    await waitFor(
      'CONFIRM_DISCARD_DIALOG',
      () =>
          live.discardConfirmationPending && live.phase == SessionPhase.paused,
    );
    expect(live.phase, SessionPhase.paused);
    await waitFor('CONFIRM_DISCARD', () => !live.active);
    expect(
      await File('${live.store.directory.path}/$discarded.json').exists(),
      false,
    );
    expect(live.records.any((record) => record.id == discarded), false);
    print('ANDROID_CONTROLS_ALL_PASSED');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
