import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'package:altranscribe/data/services/transcription/simplified_chinese.dart';

SimplifiedChinese? _androidChinese;
Future<void> initializeChineseScript() async {
  if (!Platform.isAndroid || _androidChinese != null) return;
  _androidChinese = SimplifiedChinese(
    await Future.wait([
      rootBundle.loadString('assets/opencc/TSCharacters.txt'),
      rootBundle.loadString('assets/opencc/TSPhrases.txt'),
    ]),
  );
}

typedef _MapNative = Int32 Function(
  Pointer<Utf16>,
  Uint32,
  Pointer<Utf16>,
  Int32,
  Pointer<Utf16>,
  Int32,
  Pointer<Void>,
  Pointer<Void>,
  IntPtr,
);
typedef _MapDart = int Function(
  Pointer<Utf16>,
  int,
  Pointer<Utf16>,
  int,
  Pointer<Utf16>,
  int,
  Pointer<Void>,
  Pointer<Void>,
  int,
);

final _map = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<_MapNative, _MapDart>('LCMapStringEx');

/// Our Chinese language option is Simplified Chinese. Do not change Japanese
/// kanji or text in other languages, and do not depend on the UI locale.
String normalizeChineseScript(String text, String language) {
  if (text.isEmpty ||
      !const {
        'zh',
        'zh-cn',
        'zh-hans',
        'chinese',
      }.contains(language.toLowerCase())) {
    return text;
  }
  if (Platform.isAndroid) {
    if (_androidChinese == null) {
      throw StateError('Chinese script converter is not initialized');
    }
    return _androidChinese!.convert(text);
  }
  if (!Platform.isWindows) return text;
  final locale = 'zh-CN'.toNativeUtf16();
  final source = text.toNativeUtf16();
  const simplifiedChinese = 0x02000000; // LCMAP_SIMPLIFIED_CHINESE
  try {
    final length = _map(
      locale,
      simplifiedChinese,
      source,
      text.length,
      nullptr,
      0,
      nullptr,
      nullptr,
      0,
    );
    if (length == 0) throw StateError('Chinese script conversion failed');
    final destination = calloc<Uint16>(length).cast<Utf16>();
    try {
      final written = _map(
        locale,
        simplifiedChinese,
        source,
        text.length,
        destination,
        length,
        nullptr,
        nullptr,
        0,
      );
      if (written == 0) throw StateError('Chinese script conversion failed');
      return destination.toDartString(length: written);
    } finally {
      calloc.free(destination);
    }
  } finally {
    malloc.free(source);
    malloc.free(locale);
  }
}
