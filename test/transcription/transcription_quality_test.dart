import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/services/transcription/chinese_script.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Chinese transcript conversion preserves punctuation, Latin text and emoji',
    () {
      expect(
        normalizeChineseScript('繁體中文：麥克風與系統音訊，轉錄測試 123 / GPU 😀。', 'zh'),
        '繁体中文：麦克风与系统音讯，转录测试 123 / GPU 😀。',
      );
      expect(normalizeChineseScript('已是简体\n第二行', 'zh'), '已是简体\n第二行');
      expect(normalizeChineseScript('乾隆、乾坤、皇后、頭髮', 'zh'), '乾隆、乾坤、皇后、头发');
      expect(normalizeChineseScript('', 'zh'), '');
      expect(normalizeChineseScript('日本語の漢字・図書館', 'ja'), '日本語の漢字・図書館');
      expect(
        normalizeChineseScript('Keep 繁體 inside an English quotation', 'en'),
        'Keep 繁體 inside an English quotation',
      );
      expect(normalizeChineseScript('繁體', 'auto'), '繁體');
    },
    skip: !Platform.isWindows,
  );

  test(
    'Whisper Chinese language detection normalizes auto and explicit Chinese',
    () {
      final result = <String, dynamic>{
        'language': 'chinese',
        'segments': [
          {'text': '這是一段繁體轉錄。', 'no_speech_prob': .01, 'avg_logprob': -.3},
        ],
      };
      expect(WhisperService.decodeTranscript(result, 'zh'), '这是一段繁体转录。');
      expect(WhisperService.decodeTranscript(result, 'auto'), '这是一段繁体转录。');
      result['language'] = 'japanese';
      expect(WhisperService.decodeTranscript(result, 'auto'), '這是一段繁體轉錄。');
    },
    skip: !Platform.isWindows,
  );

  test('non-speech filtering uses confidence, not advertising words', () {
    const advert = '请不吝点赞 订阅 转发 打赏支持明镜与点点栏目';
    expect(
      WhisperService.decodeTranscript({
        'segments': [
          {'text': advert, 'no_speech_prob': .95, 'avg_logprob': -1.5},
          {'text': '这是真实语音。', 'no_speech_prob': .01, 'avg_logprob': -.2},
        ],
      }, 'zh'),
      '这是真实语音。',
    );
    // The same phrase must survive when it was actually spoken confidently.
    for (final confidence in [
      {'no_speech_prob': .01, 'avg_logprob': -.2},
      {'no_speech_prob': .9, 'avg_logprob': -.2},
      <String, double>{},
    ]) {
      expect(
        WhisperService.decodeTranscript({
          'segments': [
            {'text': advert, ...confidence},
          ],
        }, 'zh'),
        advert,
      );
    }
    expect(WhisperService.decodeTranscript({'segments': []}, 'zh'), '');
    expect(
      () => WhisperService.decodeTranscript({'text': 'invalid format'}, 'zh'),
      throwsFormatException,
    );
  });

  test('quiet speech is raised to speech level before Whisper hears it', () {
    Int16List level(Uint8List wave) =>
        Int16List.sublistView(Uint8List.fromList(wave.sublist(44)));
    // Two seconds of a 200 Hz tone with a second of silence in the middle.
    Uint8List wave(double amplitude) => pcmToWave(
      Uint8List.sublistView(
        Int16List.fromList([
          for (var i = 0; i < 48000; i++)
            i >= 16000 && i < 32000
                ? 0
                : (amplitude * 32767 * sin(2 * pi * 200 * i / 16000)).round(),
        ]),
      ),
    );
    // A distant lecture: about -50 dBFS. The silence does not count.
    final quiet = WhisperService.raiseToSpeechLevel(wave(.004));
    final peak = level(quiet).map((value) => value.abs()).reduce(max);
    expect(peak / 32767, closeTo(.1 * sqrt2, .01));
    expect(level(quiet).sublist(16000, 32000).every((v) => v == 0), isTrue);
    // At most 40 times louder, and normal speech is left as it is.
    final faint = WhisperService.raiseToSpeechLevel(wave(.0001));
    expect(
      level(faint).map((value) => value.abs()).reduce(max) / 32767,
      closeTo(.004, .0005),
    );
    final normal = wave(.3);
    expect(WhisperService.raiseToSpeechLevel(normal), same(normal));
  });
}
