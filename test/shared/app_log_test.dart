import 'dart:io';

import 'package:altranscribe/data/services/logging/app_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('log lines land in a dated file and old files are pruned', () async {
    final directory = await Directory.systemTemp.createTemp('altranscribe-log');
    addTearDown(() => directory.delete(recursive: true));
    final stale = File('${directory.path}/altranscribe-2020-01-01.log');
    await stale.writeAsString('old');
    await stale.setLastModified(DateTime(2020, 1, 1));

    final log = AppLog.instance;
    await log.initialize(directory);
    log.info('test', 'hello');
    log.warn('test', '  padded\r\n');
    log.error('test', StateError('boom'), StackTrace.current);
    await log.close();

    expect(await stale.exists(), isFalse);
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final file = File(
      '${directory.path}${Platform.pathSeparator}altranscribe-$today.log',
    );
    expect(await file.exists(), isTrue);
    final content = await file.readAsString();
    expect(content, contains('[I] test: hello\n'));
    expect(content, contains('[W] test: padded\n'));
    expect(content, contains('[E] test: Bad state: boom\n'));
    expect(content, contains('app_log_test.dart'));
    expect((await log.latest())?.path, file.path);
  });

  test('the environment override wins over the Documents folder', () {
    final directory = AppLog.defaultDirectory();
    if (Platform.environment.containsKey('ALTRANSCRIBE_LOG_DIR')) {
      expect(directory?.path, Platform.environment['ALTRANSCRIBE_LOG_DIR']);
    } else if (Platform.isWindows) {
      expect(directory?.path, endsWith(r'Documents\Altranscribe\logs'));
    } else {
      expect(directory, isNull);
    }
  });
}
