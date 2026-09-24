import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:altranscribe/data/services/transcription/chinese_script.dart';

class MobilePlatform {
  static bool get android => Platform.isAndroid;
  static const channel = MethodChannel('altranscribe/platform');
  static String? dataDirectory;
  static String deviceName = 'Android';
  static final importedFiles = ValueNotifier<List<String>>([]);
  static Future<void> Function(String)? onSessionAction;

  static Future<void> initialize() async {
    if (!android) return;
    await initializeChineseScript();
    final info = await channel.invokeMapMethod<String, Object?>('initialize');
    dataDirectory = info!['dataDirectory'] as String;
    deviceName = info['deviceName'] as String;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'importFiles') {
        importedFiles.value = List<String>.from(call.arguments as List);
        await channel.invokeMethod<void>('pendingFiles');
      } else if (call.method == 'sessionAction') {
        await onSessionAction?.call(call.arguments as String);
      }
    });
    final pending = await channel.invokeListMethod<String>('pendingFiles');
    if (pending?.isNotEmpty == true) importedFiles.value = pending!;
  }

  static Future<List<String>> chooseFiles() async =>
      await channel.invokeListMethod<String>('chooseFiles') ?? [];

  static Future<void> backgroundWork(bool enabled, {String? language}) async {
    if (android) {
      await channel.invokeMethod<void>('backgroundWork', {
        'enabled': enabled,
        'interfaceLanguage': ?language,
      });
    }
  }
}
