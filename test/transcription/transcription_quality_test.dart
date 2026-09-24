import 'dart:io';

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
}
