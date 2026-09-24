// ignore_for_file: avoid_print
import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Android authorization, notification and background lifecycle', (
    tester,
  ) async {
    await MobilePlatform.initialize();
    final audio = PlatformAudioService();
    final live = RealtimeController(
      audio: audio,
      engine: WhisperService(audio),
      store: RecordStore(
        Directory(
          '${Directory(MobilePlatform.dataDirectory!).parent.path}/remote-smoke',
        ),
      ),
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
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
    Future<void> waitFor(String stage, bool Function() ready) async {
      print('ANDROID_LIFECYCLE_WAIT $stage');
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (!ready()) {
        if (live.error != null) fail(live.error!);
        if (DateTime.now().isAfter(deadline)) fail('Timed out: $stage');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      print('ANDROID_LIFECYCLE_PASSED $stage');
    }

    print('ANDROID_LIFECYCLE_WAIT CANCEL_SYSTEM_AUTHORIZATION');
    await expectLater(
      audio.start({
        'microphone': false,
        'system': true,
        'interfaceLanguage': 'zh',
      }),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'androidSystemAudioPermission',
        ),
      ),
    );
    expect(await audio.poll(), isEmpty);
    print('ANDROID_LIFECYCLE_AUTH_CANCEL_PASSED');
    await live.start(
      microphone: true,
      system: false,
      language: 'en',
      summaryLanguage: 'zh',
    );
    expect(live.error, isNull);
    expect(live.phase, SessionPhase.listening);
    await waitFor(
      'BACK_MINIMIZE',
      () => find.byKey(const Key('restore-session')).evaluate().isNotEmpty,
    );
    await waitFor(
      'NOTIFICATION_PAUSE',
      () => live.phase == SessionPhase.paused,
    );
    await waitFor(
      'NOTIFICATION_RESUME',
      () => live.phase == SessionPhase.listening,
    );
    await waitFor('NOTIFICATION_CAPTIONS', () => live.captionsVisible);
    // The test uses the retained primary engine while the native overlay and
    // foreground service remain responsible for rendering and audio capture.
    print('ANDROID_LIFECYCLE_WAIT ROTATE_AND_LOCK');
    await Future<void>.delayed(const Duration(seconds: 35));
    expect(live.phase, SessionPhase.listening);
    expect(live.error, isNull);
    expect(live.levelHistory['microphone']!.length, greaterThan(25));
    print('ANDROID_LIFECYCLE_BACKGROUND_PASSED');
    await waitFor('NOTIFICATION_STOP', () => !live.active);
    expect(live.records.first.status, 'completed');
    expect(
      live.store.directory.listSync().where(
        (file) => file.path.endsWith('.wav'),
      ),
      isEmpty,
    );
    print('ANDROID_LIFECYCLE_ALL_PASSED');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
