import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:altranscribe/data/services/logging/app_log.dart';
import 'package:altranscribe/data/services/transcription/chinese_script.dart';

class MobilePlatform {
  static bool get android => Platform.isAndroid;
  static const channel = MethodChannel('altranscribe/platform');
  static String? dataDirectory;
  static String? logDirectory;
  static String deviceName = 'Android';
  static final importedFiles = ValueNotifier<List<String>>([]);
  static Future<void> Function(String)? onSessionAction;

  /// The download notification's cancel button.
  static VoidCallback? onDownloadCancel;

  static Future<void> initialize() async {
    if (!android) return;
    await initializeChineseScript();
    final info = await channel.invokeMapMethod<String, Object?>('initialize');
    dataDirectory = info!['dataDirectory'] as String;
    logDirectory = info['logDirectory'] as String?;
    deviceName = info['deviceName'] as String;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'importFiles') {
        importedFiles.value = List<String>.from(call.arguments as List);
        await channel.invokeMethod<void>('pendingFiles');
      } else if (call.method == 'sessionAction') {
        await onSessionAction?.call(call.arguments as String);
      } else if (call.method == 'downloadAction') {
        onDownloadCancel?.call();
      }
    });
    final pending = await channel.invokeListMethod<String>('pendingFiles');
    if (pending?.isNotEmpty == true) importedFiles.value = pending!;
  }

  static Future<List<String>> chooseFiles() async =>
      await channel.invokeListMethod<String>('chooseFiles') ?? [];

  /// Lets the user pick where to save [bytes]; false when they cancel.
  static Future<bool> saveDocument(
    String name,
    String mimeType,
    Uint8List bytes,
  ) async =>
      await channel.invokeMethod<bool>('saveDocument', {
        'name': name,
        'mime': mimeType,
        'bytes': bytes,
      }) ??
      false;

  /// Opens a stored document URI in the system viewer.
  static Future<void> openDocument(String uri) =>
      channel.invokeMethod<void>('openDocument', {'uri': uri});

  /// Reads a stored document URI for embedding in an export; the platform
  /// side stops at [limit] bytes instead of loading a huge file first.
  static Future<Uint8List> readDocument(
    String uri, {
    required int limit,
  }) async =>
      await channel.invokeMethod<Uint8List>('readDocument', {
        'uri': uri,
        'limit': limit,
      }) ??
      Uint8List(0);

  /// Offers a file from the app's own folders through the share sheet.
  static Future<void> shareFile(String path, String mimeType) =>
      channel.invokeMethod<void>('shareFile', {'path': path, 'mime': mimeType});

  /// Opens the camera scanner; null when the user backs out.
  static Future<String?> scanQr(String hint) =>
      channel.invokeMethod<String>('scanQr', {'hint': hint});

  /// Keeps a model download running with the screen off or the app in the
  /// background, with its progress in a notification. [state] is `start`,
  /// `progress` or `stop`; [stage] is a `DownloadStage` name.
  static Future<void> modelDownload(
    String state, {
    String? title,
    String? stage,
    int received = 0,
    int total = 0,
    bool english = false,
  }) async {
    if (!android) return;
    try {
      await channel.invokeMethod<void>('modelDownload', {
        'state': state,
        'title': ?title,
        'stage': ?stage,
        'received': received,
        'total': total,
        'english': english,
      });
    } on PlatformException catch (error) {
      // Without the service the download still runs while the app is open.
      AppLog.instance.warn('models', 'Download service: ${error.message}');
    }
  }

  static Future<void> backgroundWork(bool enabled, {String? language}) async {
    if (android) {
      await channel.invokeMethod<void>('backgroundWork', {
        'enabled': enabled,
        'interfaceLanguage': ?language,
      });
    }
  }
}
