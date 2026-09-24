import 'dart:io';

import 'package:altranscribe/data/services/transcription/simplified_chinese.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android script conversion preserves phrases and supplementary characters',
    () {
      final converter = SimplifiedChinese([
        File('assets/opencc/TSCharacters.txt').readAsStringSync(),
        File('assets/opencc/TSPhrases.txt').readAsStringSync(),
      ]);
      expect(converter.convert('這是繁體中文，轉錄與翻譯。'), '这是繁体中文，转录与翻译。');
      expect(converter.convert('乾隆年間的乾燥天氣'), '乾隆年间的干燥天气');
      expect(converter.convert('English 😀 𪚥，簡體。'), 'English 😀 𪚥，简体。');
      expect(converter.convert(''), '');
    },
  );
}
