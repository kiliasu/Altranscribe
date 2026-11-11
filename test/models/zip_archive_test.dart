import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/models/zip_archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/zip_builder.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('zip-archive-'));
  tearDown(() => directory.deleteSync(recursive: true));

  String archive(Uint8List bytes) =>
      (File('${directory.path}/archive.zip')..writeAsBytesSync(bytes)).path;

  test('unpacks stored and deflated files into their folders', () async {
    // Larger than one piece, so reading and inflating span several.
    final large = Uint8List.fromList([
      for (var i = 0; i < 3 * 1024 * 1024; i++) (i * 31 + (i >> 9)) & 0xFF,
    ]);
    final path = archive(
      buildZip([
        ZipFile('Release/program.exe', [77, 90, 1, 2, 3]),
        ZipFile('Release/data/large.bin', large),
        ZipFile(
          'Release/notes.txt',
          'stored as it is'.codeUnits,
          deflate: false,
        ),
        const ZipFile('Release/empty.txt', []),
      ]),
    );
    final reports = <(int, int)>[];
    final target = '${directory.path}/out';
    await ZipArchive.extract(
      path,
      target,
      progress: (written, total) => reports.add((written, total)),
    );
    expect(File('$target/Release/program.exe').readAsBytesSync(), [
      77,
      90,
      1,
      2,
      3,
    ]);
    expect(File('$target/Release/data/large.bin').readAsBytesSync(), large);
    expect(
      File('$target/Release/notes.txt').readAsStringSync(),
      'stored as it is',
    );
    expect(File('$target/Release/empty.txt').lengthSync(), 0);
    // Progress counts up to the whole and is told at the end.
    final total = large.length + 5 + 15;
    expect(reports.last, (total, total));
    expect(reports.length, greaterThan(2));
    expect(
      reports.map((r) => r.$1),
      orderedEquals(reports.map((r) => r.$1).toList()..sort()),
    );
  });

  test('refuses a name that would leave the folder', () async {
    for (final name in [
      '../outside.txt',
      '/absolute.txt',
      'C:/drive.txt',
      'a/../../b.txt',
    ]) {
      final path = archive(buildZip([ZipFile(name, 'x'.codeUnits)]));
      await expectLater(
        ZipArchive.extract(path, '${directory.path}/out'),
        throwsFormatException,
        reason: name,
      );
    }
    expect(File('${directory.path}/outside.txt').existsSync(), isFalse);
    expect(
      ZipArchive.destination('t', r'bin\tool.exe'.replaceAll(r'\', '/')),
      't/bin/tool.exe',
    );
  });

  test('a damaged file is not accepted', () async {
    final bytes = buildZip([
      ZipFile('a.bin', List.generate(4096, (i) => i & 0xFF), deflate: false),
    ]);
    // One byte of the stored data changed: the size is right, the CRC not.
    bytes[30 + 'a.bin'.length + 100] ^= 0xFF;
    await expectLater(
      ZipArchive.extract(archive(bytes), '${directory.path}/out'),
      throwsFormatException,
    );
    // Deflated data cut short.
    final deflated = buildZip([
      ZipFile('b.bin', List.generate(4096, (i) => (i * 7) & 0xFF)),
    ]);
    final cut = Uint8List.fromList(deflated)
      ..fillRange(30 + 'b.bin'.length + 8, 30 + 'b.bin'.length + 40, 0);
    await expectLater(
      ZipArchive.extract(archive(cut), '${directory.path}/out2'),
      throwsFormatException,
    );
  });

  test('refuses what it does not read rather than guessing', () async {
    final file = ZipFile('a.txt', 'text'.codeUnits);
    // Encrypted entries, and a compression method other than deflate.
    for (final bytes in [
      buildZip([file], flags: 1),
      buildZip([file], method: 12),
      Uint8List.fromList(List.filled(64, 7)),
    ]) {
      await expectLater(
        ZipArchive.extract(archive(bytes), '${directory.path}/out'),
        throwsFormatException,
      );
    }
    // The 64-bit extension marks sizes it holds elsewhere with all ones.
    final wide = buildZip([file]);
    final end = wide.length - 22;
    ByteData.sublistView(wide).setUint32(end + 16, 0xFFFFFFFF, Endian.little);
    await expectLater(
      ZipArchive.extract(archive(wide), '${directory.path}/out'),
      throwsFormatException,
    );
  });

  test('stops between two pieces when asked, with its files closed', () async {
    final large = Uint8List.fromList([
      for (var i = 0; i < 5 * 1024 * 1024; i++) (i * 131 + (i >> 7)) & 0xFF,
    ]);
    final path = archive(
      buildZip([
        ZipFile('first.bin', large, deflate: false),
        ZipFile('second.bin', 'never reached'.codeUnits),
      ]),
    );
    final target = '${directory.path}/out';
    var asked = 0;
    await expectLater(
      ZipArchive.extract(path, target, stop: () async => ++asked > 2),
      throwsA(isA<ZipStopped>()),
    );
    // Two pieces of a megabyte were written before the third was refused.
    expect(asked, 3);
    expect(File('$target/first.bin').lengthSync(), 2 * 1024 * 1024);
    expect(File('$target/second.bin').existsSync(), isFalse);
    // Nothing is held open: the folder and the archive can go at once.
    Directory(target).deleteSync(recursive: true);
    File(path).deleteSync();
  });

  test('an archive with a comment and no files unpacks to nothing', () async {
    final bytes = BytesBuilder()
      ..add(buildZip(const []))
      ..add('a trailing comment'.codeUnits);
    final withComment = bytes.takeBytes();
    ByteData.sublistView(withComment)
        .setUint16(20, 'a trailing comment'.length, Endian.little);
    final target = '${directory.path}/out';
    await ZipArchive.extract(archive(withComment), target);
    expect(Directory(target).listSync(), isEmpty);
  });
}
