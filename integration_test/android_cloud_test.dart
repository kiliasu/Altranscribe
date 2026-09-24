// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/cloud/cloud_api.dart';
import 'package:altranscribe/data/services/cloud/cloud_file_engine.dart';
import 'package:altranscribe/data/services/cloud/cloud_live.dart';
import 'package:altranscribe/data/services/cloud/cloud_live_session.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/cloud/credential_store.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Opt-in target. Uses only synthetic speech and the user's test credentials,
// transferred privately with scripts/prepare-android-cloud-test.ps1.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android real OpenAI/Gemini API and Gemini renewal', (
    tester,
  ) async {
    await MobilePlatform.initialize();
    final root = Directory(MobilePlatform.dataDirectory!).parent;
    final bootstrap = File('${root.path}/android-cloud.json');
    final setupDeadline = DateTime.now().add(const Duration(minutes: 2));
    while (!await bootstrap.exists()) {
      if (DateTime.now().isAfter(setupDeadline)) {
        fail('Missing private cloud test setup');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final directory = await Directory('${root.path}/cloud-smoke')
        .create(recursive: true);
    final credentials = WindowsCredentialStore(directory);
    final keys = jsonDecode(await bootstrap.readAsString()) as Map;
    try {
      for (final provider in CloudProvider.values) {
        await credentials.write(provider, keys[provider.name] as String);
      }
    } finally {
      keys.clear();
      await bootstrap.delete();
    }
    final pcm = <int, Uint8List>{};
    for (final rate in [16000, 24000]) {
      pcm[rate] = await File('${root.path}/cloud-speech-$rate.pcm')
          .readAsBytes();
    }
    final results = <String, Object?>{};
    Future<void> check(String name, Future<void> Function() run) async {
      try {
        await run();
        results[name] = {'passed': true};
      } catch (error) {
        results[name] = {'passed': false, 'error': error.toString()};
      }
      await File('${directory.path}/report.json')
          .writeAsString(jsonEncode(results));
      print('ANDROID_CLOUD $name ${(results[name] as Map)['passed']}');
    }

    for (final provider in CloudProvider.values) {
      await check('${provider.name}.file', () async {
        final engine = CloudFileEngine(CloudApi(credentials), provider);
        try {
          await engine.start('', '', directory);
          expect(
            (await engine.transcribe(
              pcmToWave(pcm[16000]!),
              'auto',
            )).toLowerCase(),
            contains('report'),
          );
        } finally {
          await engine.stop();
        }
      });
      await check('${provider.name}.llm', () async {
        final llm = LocalLlmService(cloudApi: CloudApi(credentials));
        try {
          await llm.prepare(
            '',
            provider == CloudProvider.openAI
                ? 'gpt-5.6-luna'
                : 'gemini-3.5-flash-lite',
            provider: provider == CloudProvider.openAI
                ? LlmProvider.openAI
                : LlmProvider.gemini,
          );
          expect(
            RegExp(r'[\u4e00-\u9fff]').hasMatch(
              await llm.translate(
                'Alice will bring the report tomorrow.',
                'auto',
                'zh',
              ),
            ),
            true,
          );
          final summary = await llm.summarize([
            'Alice will bring the report tomorrow.',
          ], 'zh');
          expect(summary.title, isNotEmpty);
          expect(summary.summary, isNotEmpty);
          final cleaned = await llm.cleanUp([
            'Alcie will bring the report.',
          ], const CleanupOptions(names: true, spellings: ['Alice']));
          expect(cleaned.texts, hasLength(1));
        } finally {
          llm.stop();
        }
      });
      for (final direct in [false, true]) {
        await check('${provider.name}.live.$direct', () async {
          final updates = <String, CloudLiveText>{};
          final errors = <String>[];
          var renewals = 0;
          final connection = CloudLiveSession(
            credentials: credentials,
            provider: provider == CloudProvider.openAI
                ? SpeechProvider.openAI
                : SpeechProvider.gemini,
            directTranslation: direct,
            source: 'synthetic-test',
            language: 'auto',
            targetLanguage: 'zh',
            onText: (text) => updates[text.id] = text,
            onError: errors.add,
            onRenewed: () => renewals++,
            renewAfter: const Duration(seconds: 12),
            renewBy: const Duration(seconds: 30),
          );
          try {
            await connection.start();
            final frameBytes = connection.sampleRate ~/ 5;
            var sent = 0;
            Future<void> feed(Uint8List bytes) async {
              for (var start = 0; start < bytes.length; start += frameBytes) {
                final end = (start + frameBytes).clamp(0, bytes.length);
                connection.add(
                  Uint8List.sublistView(bytes, start, end),
                  sent * 500 ~/ connection.sampleRate,
                  (sent + end - start) * 500 ~/ connection.sampleRate,
                );
                sent += end - start;
                await Future<void>.delayed(const Duration(milliseconds: 100));
              }
            }

            await feed(pcm[connection.sampleRate]!);
            if (provider == CloudProvider.gemini) {
              final wait = Stopwatch()..start();
              while (renewals == 0) {
                expect(errors, isEmpty);
                expect(wait.elapsed, lessThan(const Duration(seconds: 40)));
                await feed(Uint8List(frameBytes));
              }
              await feed(pcm[connection.sampleRate]!);
            }
            await connection.finish();
            expect(errors, isEmpty);
            final text = updates.values.map((text) => text.text).join(' ');
            expect(text.toLowerCase(), contains('report'));
            expect(updates.values.every((text) => text.finalized), true);
            if (direct) {
              expect(
                RegExp(r'[\u4e00-\u9fff]').hasMatch(
                  updates.values.map((text) => text.translation ?? '').join(),
                ),
                true,
              );
            }
            if (provider == CloudProvider.gemini) {
              expect(renewals, greaterThanOrEqualTo(1));
              expect(
                RegExp('report', caseSensitive: false).allMatches(text).length,
                2,
              );
            }
          } finally {
            connection.cancel();
          }
        });
      }
    }
    expect(
      results.entries
          .where((entry) => (entry.value as Map)['passed'] != true)
          .map((entry) => entry.key),
      isEmpty,
    );
    print('ANDROID_CLOUD_PASSED ${results.length} checks');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
