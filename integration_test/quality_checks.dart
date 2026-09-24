import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// No user recordings: Windows notification sounds, synthetic tones and the
/// speech synthesized locally by the native smoke test.
Future<void> checkTranscriptionQuality(
  WhisperService engine,
  Directory directory,
  Uint8List speech,
) async {
  final outputs = <String, String>{};
  final sounds = <String, Uint8List>{'silence': Uint8List(16000 * 2 * 3)};
  final beep = Uint8List(16000 * 2 * 3);
  final beepData = ByteData.sublistView(beep);
  for (var i = 1600; i < 14400; i++) {
    final envelope = sin(pi * (i - 1600) / 12800);
    beepData.setInt16(
      i * 2,
      (8000 * envelope * sin(2 * pi * 880 * i / 16000)).round(),
      Endian.little,
    );
  }
  sounds['tone'] = beep;
  for (final name in [
    'notify.wav',
    'Windows Notify System Generic.wav',
    'Windows Notify Email.wav',
    'Windows Notify Messaging.wav',
    'ding.wav',
    'chimes.wav',
  ]) {
    final file = '${Platform.environment['SystemRoot']}/Media/$name';
    final decoded = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      file,
      '-f',
      's16le',
      '-ar',
      '16000',
      '-ac',
      '1',
      'pipe:1',
    ], stdoutEncoding: null);
    expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
    sounds[name] = Uint8List.fromList([
      ...decoded.stdout as List<int>,
      ...Uint8List(32000),
    ]);
  }
  for (final entry in sounds.entries) {
    for (final language in ['zh', 'auto']) {
      final text = await engine.transcribe(pcmToWave(entry.value), language);
      outputs['${entry.key}:$language'] = text;
      // Write each observation even if a later assertion fails.
      await File('${directory.path}/quality-report.json')
          .writeAsString(jsonEncode(outputs));
      expect(text, isEmpty, reason: '${entry.key} ($language) is not speech');
    }
  }
  final mixed = Uint8List.fromList(speech);
  final mixedData = ByteData.sublistView(mixed);
  final ding = ByteData.sublistView(sounds['ding.wav']!);
  for (var i = 0; i < min(mixed.length, ding.lengthInBytes); i += 2) {
    final value =
        mixedData.getInt16(i, Endian.little) +
        ding.getInt16(i, Endian.little) * .2;
    mixedData.setInt16(i, value.round().clamp(-32768, 32767), Endian.little);
  }
  final quiet = Uint8List.fromList(speech);
  final quietData = ByteData.sublistView(quiet);
  for (var i = 0; i < quiet.length; i += 2) {
    quietData.setInt16(
      i,
      (quietData.getInt16(i, Endian.little) * .1).round(),
      Endian.little,
    );
  }
  for (final entry in {
    'speech': speech,
    'speechWithNotification': mixed,
    'quietSpeech': quiet,
  }.entries) {
    final text = await engine.transcribe(pcmToWave(entry.value), 'en');
    outputs[entry.key] = text;
    await File('${directory.path}/quality-report.json')
        .writeAsString(jsonEncode(outputs));
    expect(text.toLowerCase(), contains('transcription'), reason: entry.key);
    expect(text.toLowerCase(), contains('system'), reason: entry.key);
  }
  final shortFile = File('${directory.path}/short-speech.wav').absolute;
  final quoted = "'${shortFile.path.replaceAll("'", "''")}'";
  final synthesized = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    'Add-Type -AssemblyName System.Speech; '
        r'$voice = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
        r'$voice.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::NotSet, [System.Speech.Synthesis.VoiceAge]::NotSet, 0, [System.Globalization.CultureInfo]::GetCultureInfo("en-US")); '
        '\$voice.SetOutputToWaveFile($quoted); '
        r'$voice.Speak("Yes. Okay."); $voice.Dispose();',
  ]);
  expect(synthesized.exitCode, 0, reason: '${synthesized.stderr}');
  for (final volume in ['1', '0.1']) {
    final decoded = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      shortFile.path,
      '-af',
      'volume=$volume',
      '-f',
      's16le',
      '-ar',
      '16000',
      '-ac',
      '1',
      'pipe:1',
    ], stdoutEncoding: null);
    expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
    final text = await engine.transcribe(
      pcmToWave(Uint8List.fromList(decoded.stdout as List<int>)),
      'en',
    );
    outputs['shortSpeech:$volume'] = text;
    await File('${directory.path}/quality-report.json')
        .writeAsString(jsonEncode(outputs));
    expect(text.toLowerCase(), contains('yes'));
    expect(text.toLowerCase(), contains('okay'));
  }
}
