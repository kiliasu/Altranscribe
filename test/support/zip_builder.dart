import 'dart:io';
import 'dart:typed_data';

/// A file to put into a test archive.
class ZipFile {
  const ZipFile(this.name, this.bytes, {this.deflate = true});
  final String name;
  final List<int> bytes;
  final bool deflate;
}

int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = crc & 1 != 0 ? 0xEDB88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// A zip archive of [files], laid out as release tools write one: a local
/// header and the data for each file, then the central directory and the
/// end record. [flags] and [method] override what the directory says, to
/// make archives the reader must refuse.
Uint8List buildZip(List<ZipFile> files, {int flags = 0, int? method}) {
  final out = BytesBuilder();
  final directory = BytesBuilder();
  for (final file in files) {
    final name = file.name.codeUnits;
    final data = file.deflate
        ? ZLibEncoder(raw: true).convert(file.bytes)
        : file.bytes;
    final header = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, flags, Endian.little)
      ..setUint16(8, method ?? (file.deflate ? 8 : 0), Endian.little)
      ..setUint32(14, crc32(file.bytes), Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, file.bytes.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    final entry = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, flags, Endian.little)
      ..setUint16(10, method ?? (file.deflate ? 8 : 0), Endian.little)
      ..setUint32(16, crc32(file.bytes), Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, file.bytes.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, out.length, Endian.little);
    out
      ..add(header.buffer.asUint8List())
      ..add(name)
      ..add(data);
    directory
      ..add(entry.buffer.asUint8List())
      ..add(name);
  }
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, files.length, Endian.little)
    ..setUint16(10, files.length, Endian.little)
    ..setUint32(12, directory.length, Endian.little)
    ..setUint32(16, out.length, Endian.little);
  out
    ..add(directory.takeBytes())
    ..add(end.buffer.asUint8List());
  return out.takeBytes();
}
