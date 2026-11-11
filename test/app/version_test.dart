import 'dart:io';

import 'package:altranscribe/app/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the version shown in Settings is the one that is built', () {
    final declared = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((line) => line.startsWith('version:'))
        .split(':')
        .last
        .trim();
    // The part before the build number.
    expect(declared.split('+').first, appVersion);
  });
}
