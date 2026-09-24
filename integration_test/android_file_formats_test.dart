// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:altranscribe/data/services/files/android_audio_decoder.dart';
import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android decodes every supported file extension', (tester) async {
    await MobilePlatform.initialize();
    final directory = Directory(
      '${Directory(MobilePlatform.dataDirectory!).parent.path}/formats',
    );
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (!await File('${directory.path}/测试音频.wav').exists()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Missing synthetic format fixtures');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final failures = <String>[];
    for (final extension in audioFileExtensions) {
      final decoder = AndroidAudioDecoder();
      try {
        var bytes = 0, end = 0;
        var energy = 0.0;
        await for (final chunk in decoder.decode(
          '${directory.path}/测试音频.$extension',
          chunkSeconds: 2,
        )) {
          expect(chunk.startMs, end);
          end = chunk.endMs;
          expect(chunk.pcm.length, lessThanOrEqualTo(64000));
          final pcm = ByteData.sublistView(chunk.pcm);
          for (var i = 0; i < pcm.lengthInBytes; i += 2) {
            energy += pow(pcm.getInt16(i, Endian.little) / 32768, 2);
          }
          bytes += chunk.pcm.length;
        }
        expect(end, inInclusiveRange(2900, 3150));
        expect(sqrt(energy / (bytes / 2)), greaterThan(.04));
        print('ANDROID_FORMAT_PASSED $extension ${end}ms');
      } catch (error) {
        failures.add(extension);
        print('ANDROID_FORMAT_FAILED $extension $error');
      } finally {
        await decoder.cancel();
      }
    }
    expect(failures, isEmpty);
    final decoder = AndroidAudioDecoder();
    var chunks = 0;
    await for (final _ in decoder.decode(
      '${directory.path}/测试音频.wav',
      chunkSeconds: 1,
    )) {
      chunks++;
      await decoder.cancel();
    }
    expect(chunks, 1);
    print('ANDROID_FORMAT_CANCELLATION_PASSED');
    // Two-hour lossless audio and a 15-minute WMA fixture must yield immediately
    // with bounded memory; cancellation must also release the fallback decoder.
    for (final extension in ['flac', 'wma']) {
      final decoder = AndroidAudioDecoder();
      final before = ProcessInfo.currentRss;
      final clock = Stopwatch()..start();
      var windows = 0;
      await for (final chunk in decoder.decode(
        '${directory.path}/long-silence.$extension',
        chunkSeconds: 2,
      )) {
        expect(chunk.pcm.length, lessThanOrEqualTo(64000));
        expect(ProcessInfo.currentRss - before, lessThan(128 * 1024 * 1024));
        if (++windows == 2) await decoder.cancel();
      }
      expect(windows, 2);
      expect(clock.elapsed, lessThan(const Duration(seconds: 15)));
      expect(
        (await decoder.decode('${directory.path}/测试音频.wav').toList())
            .last
            .endMs,
        3000,
      );
      print(
        'ANDROID_LONG_FILE_PASSED $extension ${clock.elapsedMilliseconds}ms',
      );
    }
  });
}
