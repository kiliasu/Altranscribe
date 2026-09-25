import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:material_ui/material_ui.dart';

import 'app/app.dart';
import 'data/services/logging/app_log.dart';
import 'features/captions/caption_app.dart';
import 'shared/platform/mobile_platform.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MobilePlatform.initialize();
  await startLogging();
  runApp(const AltranscribeApp());
}

/// Diagnostics go to a folder the user can open; framework errors are logged
/// and then handled as usual.
Future<void> startLogging() async {
  final android = MobilePlatform.logDirectory;
  final directory = MobilePlatform.android
      ? (android == null ? null : Directory(android))
      : AppLog.defaultDirectory();
  if (directory == null) return;
  await AppLog.instance.initialize(directory);
  AppLog.instance.info(
    'app',
    'Altranscribe started on ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  );
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.instance.error(
      'flutter',
      details.exceptionAsString(),
      details.stack,
    );
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.instance.error('dart', error, stack);
    return false;
  };
}

@pragma('vm:entry-point')
void captionMain() => runApp(const CaptionApp());
