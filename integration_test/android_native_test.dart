// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:altranscribe/data/services/cloud/credential_store.dart';
import 'package:altranscribe/data/services/files/android_audio_decoder.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android real native storage, Keystore, PCM decoder and capture lifecycle',
    (tester) async {
      expect(Platform.isAndroid, true);
      await MobilePlatform.initialize();
      final store = RecordStore.local();
      expect(
        store.directory.path,
        startsWith('/data/user/0/app.altranscribe/'),
      );
      final credential = WindowsCredentialStore(store.directory);
      const secret = 'android-native-test-only';
      await credential.writeNamed('native-smoke', secret);
      expect(await credential.readNamed('native-smoke'), secret);
      final encrypted = File('${store.directory.path}/native-smoke.credential');
      expect(
        latin1.decode(await encrypted.readAsBytes()),
        isNot(contains(secret)),
      );
      await credential.writeNamed('native-smoke', '');
      expect(await encrypted.exists(), false);

      final audio = PlatformAudioService();
      final engine = WhisperService(audio);
      await expectLater(
        engine.start('', '', store.directory),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        LocalLlmService().models('http://127.0.0.1:11434'),
        throwsA(isA<FormatException>()),
      );

      // Known generated waveform: no private recordings or model mocks.
      final pcm = Uint8List(16000 * 2 * 3);
      final values = ByteData.sublistView(pcm);
      for (var i = 0; i < pcm.length ~/ 2; i++) {
        values.setInt16(
          i * 2,
          (3000 * sin(i * 2 * pi * 440 / 16000)).round(),
          Endian.little,
        );
      }
      final fixture = File('${store.directory.path}/native-test-tone.wav');
      await fixture.writeAsBytes(pcmToWave(pcm));
      try {
        final chunks = await AndroidAudioDecoder()
            .decode(fixture.path, chunkSeconds: 2)
            .toList();
        expect(chunks.length, 2);
        expect(chunks.first.startMs, 0);
        expect(chunks.last.endMs, 3000);
        expect(
          chunks.fold<int>(0, (sum, chunk) => sum + chunk.pcm.length),
          pcm.length,
        );
        final samples = ByteData.sublistView(chunks.first.pcm);
        var energy = 0.0;
        for (var i = 1600; i < chunks.first.pcm.length ~/ 2; i++) {
          energy += pow(samples.getInt16(i * 2, Endian.little) / 32768, 2);
        }
        expect(
          sqrt(energy / (chunks.first.pcm.length ~/ 2 - 1600)),
          greaterThan(.05),
        );
      } finally {
        await fixture.delete();
      }

      final devices = await audio.devices();
      expect(
        devices.where((device) => device['source'] == 'microphone'),
        isNotEmpty,
      );
      final events = <Map<String, Object?>>[];
      try {
        await audio.start({
          'microphone': true,
          'system': false,
          'streaming': true,
          'sampleRate': 16000,
          'microphoneDenoise': true,
          'microphoneAutoGain': true,
          'interfaceLanguage': 'zh',
        });
        final deadline = DateTime.now().add(const Duration(seconds: 4));
        while (DateTime.now().isBefore(deadline)) {
          events.addAll(await audio.poll());
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(events.where((e) => e['type'] == 'error'), isEmpty);
        expect(events.where((e) => e['type'] == 'ready'), hasLength(1));
        expect(events.where((e) => e['type'] == 'frame'), isNotEmpty);
        expect(events.where((e) => e['type'] == 'level'), isNotEmpty);
        await audio.pause(true);
        final paused = await audio.poll();
        expect(paused.where((e) => e['type'] == 'paused'), hasLength(1));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          (await audio.poll()).where((e) => e['type'] == 'frame'),
          isEmpty,
        );
        await audio.pause(false);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          (await audio.poll()).where((e) => e['type'] == 'frame'),
          isNotEmpty,
        );
      } finally {
        await audio.stop();
        await MobilePlatform.backgroundWork(false);
      }
      expect(await audio.poll(), isEmpty);
      expect(
        store.directory.listSync().where((file) => file.path.endsWith('.wav')),
        isEmpty,
      );
      // Native platform calls must be registered on the retained engine.
      expect(
        await const MethodChannel('altranscribe/platform')
            .invokeListMethod<String>('pendingFiles'),
        isEmpty,
      );
      print(
        'ANDROID_NATIVE_PASSED ${jsonEncode({'microphones': devices.length, 'frames': events.where((e) => e['type'] == 'frame').length, 'keystore': true, 'decodedMs': 3000, 'paused': true, 'recordingFiles': 0})}',
      );
    },
  );
}
