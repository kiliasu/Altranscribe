import 'dart:async';
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
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Diagnostic transport for opted-in tests. Logs event fields and close reasons,
// excluding audio bytes, endpoint URLs, request headers and API keys.
class ObservedSocket implements WebSocket {
  ObservedSocket(this.socket, this.events, this.connection);
  final WebSocket socket;
  final List<Object?> events;
  final int connection;
  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => socket.listen(
    (data) {
      final event = jsonDecode(
        data is String ? data : utf8.decode(data as List<int>),
      ) as Map<String, dynamic>;
      final content = event['serverContent'] as Map?;
      events.add({
        'connection': connection,
        'fields': event.keys.toList(),
        if (content != null)
          'serverContent': {
            for (final entry in content.entries)
              if (entry.key != 'modelTurn') entry.key: entry.value,
          },
      });
      onData?.call(data);
    },
    onError: onError,
    onDone: () {
      events.add({
        'connection': connection,
        'closeCode': socket.closeCode,
        'closeReason': socket.closeReason?.replaceAll(
          RegExp(r'(sk-|AQ\.)\S+'),
          '[redacted]',
        ),
      });
      onDone?.call();
    },
    cancelOnError: cancelOnError,
  );
  @override
  int get readyState => socket.readyState;
  @override
  set pingInterval(Duration? value) => socket.pingInterval = value;
  @override
  void add(dynamic data) => socket.add(data);
  @override
  Future close([int? code, String? reason]) => socket.close(code, reason);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Explicitly opt in: this uses the user's encrypted keys and makes paid requests.
// Only locally synthesized test speech is uploaded, never microphone recordings.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows cloud providers: real authenticated requests',
    (tester) async {
      final directory = Directory(
        Platform.environment['ALTRANSCRIBE_DATA_DIR']!,
      );
      final credentials = WindowsCredentialStore(directory);
      final reports = <String, Object?>{};
      final output = Directory('${directory.path}/cloud-smoke');
      await output.create(recursive: true);
      final existingReport = File('${output.path}/report.json');
      if (Platform.environment['ALTRANSCRIBE_CLOUD_CASE'] != null &&
          await existingReport.exists()) {
        reports.addAll(
          jsonDecode(await existingReport.readAsString())
              as Map<String, dynamic>,
        );
      }
      final wave = File('${output.path}/speech.wav').absolute;
      final generated = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Add-Type -AssemblyName System.Speech; '
            r'$voice = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
            '\$voice.SetOutputToWaveFile(\'${wave.path.replaceAll("'", "''")}\'); '
            r'$voice.Speak("Hello Alice. The meeting starts at nine tomorrow. Please bring the project report."); '
            r'$voice.Dispose();',
      ]);
      expect(generated.exitCode, 0);
      final pcm = <int, Uint8List>{};
      for (final rate in [16000, 24000]) {
        final decoded = await Process.run('ffmpeg', [
          '-v',
          'error',
          '-i',
          wave.path,
          '-ac',
          '1',
          '-ar',
          '$rate',
          '-f',
          's16le',
          'pipe:1',
        ], stdoutEncoding: null);
        expect(decoded.exitCode, 0);
        pcm[rate] = Uint8List.fromList(decoded.stdout as List<int>);
      }
      Future<void> check(String name, Future<Object?> Function() run) async {
        final filter = Platform.environment['ALTRANSCRIBE_CLOUD_CASE'];
        if (filter != null && !name.contains(filter)) return;
        try {
          reports[name] = {'passed': true, 'result': await run()};
        } catch (e) {
          reports[name] = {'passed': false, 'error': e.toString()};
        }
        await File('${output.path}/report.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
        // Reports contain synthetic speech only. Never log keys or request headers.
        // ignore: avoid_print
        print('$name: ${(reports[name] as Map)['passed']}');
      }

      await check('windowsEncryption', () async {
        final vault = WindowsCredentialStore(Directory('${output.path}/vault'));
        const dummy = 'dummy-roundtrip-key';
        await vault.write(CloudProvider.openAI, dummy);
        expect(await vault.read(CloudProvider.openAI), dummy);
        final encrypted = await File(
          '${vault.directory.path}/openAI.credential',
        ).readAsBytes();
        expect(
          utf8.decode(encrypted, allowMalformed: true),
          isNot(contains(dummy)),
        );
        await vault.write(CloudProvider.openAI, '');
        return 'DPAPI round trip; no plaintext persistence';
      });
      await check('windowsCloudFrames', () async {
        final audio = WindowsAudioService();
        final events = <Map<String, Object?>>[];
        try {
          await audio.start({
            'system': true,
            'streaming': true,
            'sampleRate': 24000,
          });
          for (var i = 0; i < 12; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            events.addAll(await audio.poll());
          }
        } finally {
          events.addAll(await audio.stop());
        }
        expect(events.where((e) => e['type'] == 'error'), isEmpty);
        final frames = events.where((e) => e['type'] == 'frame').toList();
        expect(frames, isNotEmpty);
        expect(
          frames.every((e) => (e['pcm'] as Uint8List).length <= 4800),
          isTrue,
        );
        return {'frames': frames.length, 'rate': 24000};
      });

      for (final provider in CloudProvider.values) {
        await check('${provider.name}.file', () async {
          final engine = CloudFileEngine(CloudApi(credentials), provider);
          try {
            await engine.start('', '', output);
            final result = await engine.transcribe(
              pcmToWave(pcm[16000]!),
              'auto',
            );
            expect(result.toLowerCase(), contains('meeting'));
            return {
              'model': engine.model,
              'text': result,
              'cleanupWarning': engine.cleanupWarning,
            };
          } finally {
            await engine.stop();
          }
        });
        await check('${provider.name}.text', () async {
          final llm = LocalLlmService(cloudApi: CloudApi(credentials));
          final selected = provider == CloudProvider.openAI
              ? LlmProvider.openAI
              : LlmProvider.gemini;
          final model = provider == CloudProvider.openAI
              ? 'gpt-5.6-luna'
              : 'gemini-3.5-flash-lite';
          try {
            await llm.prepare('', model, provider: selected);
            final result = await llm.translate(
              'The meeting starts at nine tomorrow.',
              'auto',
              'zh',
            );
            expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(result), isTrue);
            final summary = await llm.summarize([
              'Alice will bring the project report to the meeting tomorrow at nine.',
            ], 'zh');
            final cleanup = await llm.cleanUp([
              'Alcie will bring the report.',
            ], const CleanupOptions(names: true, spellings: ['Alice']));
            return {
              'model': model,
              'translation': result,
              'title': summary.title,
              'summary': summary.summary,
              'cleanup': cleanup.texts,
            };
          } finally {
            llm.stop();
          }
        });
        for (final direct in [false, true]) {
          await check('${provider.name}.live.$direct', () async {
            final wire = <Object?>[];
            final updates = <String, CloudLiveText>{};
            final errors = <String>[];
            final renewalCheck =
                provider == CloudProvider.gemini &&
                Platform.environment['ALTRANSCRIBE_CLOUD_RENEWAL_SMOKE'] == '1';
            var renewals = 0;
            var connections = 0;
            final connection = CloudLiveSession(
              credentials: credentials,
              provider: provider == CloudProvider.openAI
                  ? SpeechProvider.openAI
                  : SpeechProvider.gemini,
              directTranslation: direct,
              source: 'test',
              language: 'auto',
              targetLanguage: 'zh',
              onText: (update) => updates[update.id] = update,
              onError: errors.add,
              onRenewed: () => renewals++,
              renewAfter: renewalCheck
                  ? const Duration(seconds: 12)
                  : const Duration(minutes: 9),
              renewBy: renewalCheck
                  ? const Duration(seconds: 30)
                  : const Duration(minutes: 9, seconds: 30),
              connect: (uri, headers) async => ObservedSocket(
                await WebSocket.connect(uri.toString(), headers: headers),
                wire,
                connections++,
              ),
            );
            try {
              await connection.start();
              final original = pcm[connection.sampleRate]!;
              final frameBytes = connection.sampleRate ~/ 5;
              var sentBytes = 0;
              Future<void> feed(Uint8List bytes) async {
                for (var start = 0; start < bytes.length; start += frameBytes) {
                  final end = (start + frameBytes).clamp(0, bytes.length);
                  connection.add(
                    Uint8List.sublistView(bytes, start, end),
                    sentBytes * 500 ~/ connection.sampleRate,
                    (sentBytes + end - start) * 500 ~/ connection.sampleRate,
                  );
                  sentBytes += end - start;
                  await Future<void>.delayed(const Duration(milliseconds: 100));
                }
              }

              await feed(original);
              if (renewalCheck) {
                final waiting = Stopwatch()..start();
                while (renewals == 0) {
                  expect(errors, isEmpty);
                  expect(
                    waiting.elapsed,
                    lessThan(const Duration(seconds: 35)),
                  );
                  await feed(Uint8List(frameBytes));
                }
                await feed(original);
              }
              // Exercise graceful close immediately after speech, without a
              // pre-close delay that could hide lost final words.
              await connection.finish();
              expect(errors, isEmpty);
              final text = updates.values.map((e) => e.text).join(' ');
              expect(text.toLowerCase(), contains('report'));
              if (renewalCheck) {
                expect(renewals, greaterThanOrEqualTo(1));
                expect(
                  RegExp(
                    'report',
                    caseSensitive: false,
                  ).allMatches(text).length,
                  2,
                );
              }
              final translated = updates.values
                  .map((e) => e.translation ?? '')
                  .join();
              if (direct) {
                expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(translated), isTrue);
              }
              expect(updates.values.every((e) => e.finalized), isTrue);
              return {
                'text': text,
                'translation': translated,
                'segments': updates.length,
                'renewals': renewals,
                'connections': connections,
                'serverConfirmed': updates.values.every(
                  (e) => e.serverConfirmed,
                ),
              };
            } finally {
              connection.cancel();
              await File(
                '${output.path}/${provider.name}-live-$direct-events.json',
              ).writeAsString(const JsonEncoder.withIndent('  ').convert(wire));
            }
          });
        }
      }
      expect(
        reports.entries
            .where((entry) => (entry.value as Map)['passed'] != true)
            .map((entry) => entry.key)
            .toList(),
        isEmpty,
        reason: 'See cloud-smoke/report.json for synthetic-audio results.',
      );
    },
    skip: Platform.environment['ALTRANSCRIBE_CLOUD_SMOKE'] != '1',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
