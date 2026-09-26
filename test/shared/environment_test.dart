import 'dart:io';

import 'package:altranscribe/features/records/record_export.dart';
import 'package:altranscribe/shared/platform/environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty environment overrides count as unset', () {
    final environment = {'A': 'value', 'B': ''};
    expect(environmentValue('A', environment: environment), 'value');
    expect(environmentValue('B', environment: environment), isNull);
    expect(environmentValue('C', environment: environment), isNull);
  });

  test(
    'an export reads a media file only when it fits the embed limit',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'altranscribe-embed',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/clip.bin');
      await file.writeAsBytes(List.filled(10, 7));
      expect(await readWithin(file, 10), hasLength(10));
      await expectLater(
        readWithin(file, 9),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'fileTooLarge',
          ),
        ),
      );
      expect(
        embedLimit,
        256 << 20,
        reason: 'the desktop keeps the larger ceiling',
      );
    },
  );
}
