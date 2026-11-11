import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// One file in a zip archive, as its central directory describes it.
class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.method,
    required this.crc,
    required this.compressedSize,
    required this.size,
    required this.offset,
  });

  /// The path inside the archive, with forward slashes.
  final String name;

  /// 0 for stored, 8 for deflated.
  final int method;
  final int crc;
  final int compressedSize;
  final int size;

  /// Where the entry's local header starts.
  final int offset;
  bool get isDirectory => name.endsWith('/');
}

/// Thrown by [ZipArchive.extract] when it was asked to stop.
class ZipStopped implements Exception {
  const ZipStopped();
  @override
  String toString() => 'Unpacking was stopped';
}

/// Reads and unpacks the zip archives programs are published in: stored or
/// deflated files, without encryption, spanning or the 64-bit extension.
/// Everything is read in pieces, so an archive of a gigabyte costs no more
/// memory than a small one. It reads and writes synchronously and is meant
/// to run in an isolate of its own.
abstract final class ZipArchive {
  static const _piece = 1 << 20;

  /// The entries of [archive], in the order of its central directory.
  static List<ZipEntry> entries(RandomAccessFile archive) {
    final length = archive.lengthSync();
    // The end record is the last thing in the file, before a comment of at
    // most 65535 bytes.
    final tailSize = min(length, 22 + 0xFFFF);
    archive.setPositionSync(length - tailSize);
    final tail = archive.readSync(tailSize);
    var end = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4b &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        end = i;
        break;
      }
    }
    if (end < 0) throw const FormatException('Not a zip archive');
    final record = ByteData.sublistView(tail, end, end + 22);
    final count = record.getUint16(10, Endian.little);
    final directorySize = record.getUint32(12, Endian.little);
    final directoryOffset = record.getUint32(16, Endian.little);
    if (record.getUint16(4, Endian.little) != 0 ||
        record.getUint16(6, Endian.little) != 0 ||
        count != record.getUint16(8, Endian.little)) {
      throw const FormatException('Zip archives in several parts are not read');
    }
    if (count == 0xFFFF ||
        directorySize == 0xFFFFFFFF ||
        directoryOffset == 0xFFFFFFFF) {
      throw const FormatException('64-bit zip archives are not read');
    }
    if (directoryOffset + directorySize > length) {
      throw const FormatException('The zip directory lies outside the file');
    }
    archive.setPositionSync(directoryOffset);
    final directory = archive.readSync(directorySize);
    if (directory.length != directorySize) {
      throw const FormatException('The zip directory is cut short');
    }
    final data = ByteData.sublistView(directory);
    final result = <ZipEntry>[];
    var at = 0;
    for (var i = 0; i < count; i++) {
      if (at + 46 > directory.length ||
          data.getUint32(at, Endian.little) != 0x02014b50) {
        throw const FormatException('The zip directory is damaged');
      }
      final flags = data.getUint16(at + 8, Endian.little);
      final method = data.getUint16(at + 10, Endian.little);
      final compressedSize = data.getUint32(at + 20, Endian.little);
      final size = data.getUint32(at + 24, Endian.little);
      final nameLength = data.getUint16(at + 28, Endian.little);
      final extraLength = data.getUint16(at + 30, Endian.little);
      final commentLength = data.getUint16(at + 32, Endian.little);
      final offset = data.getUint32(at + 42, Endian.little);
      final next = at + 46 + nameLength + extraLength + commentLength;
      if (next > directory.length) {
        throw const FormatException('The zip directory is damaged');
      }
      if (flags & 1 != 0) {
        throw const FormatException('Encrypted zip entries are not read');
      }
      if (compressedSize == 0xFFFFFFFF ||
          size == 0xFFFFFFFF ||
          offset == 0xFFFFFFFF) {
        throw const FormatException('64-bit zip archives are not read');
      }
      if (method != 0 && method != 8) {
        throw FormatException('Zip compression method $method is not read');
      }
      // Names are UTF-8 when the archive says so and in practice otherwise:
      // the archives read here hold ASCII file names.
      result.add(
        ZipEntry(
          name: String.fromCharCodes(
            directory,
            at + 46,
            at + 46 + nameLength,
          ).replaceAll(r'\', '/'),
          method: method,
          crc: data.getUint32(at + 16, Endian.little),
          compressedSize: compressedSize,
          size: size,
          offset: offset,
        ),
      );
      at = next;
    }
    return result;
  }

  /// Where [name] lands under [target], or an error for a name that would
  /// leave it: an absolute path, a drive, or a step upwards.
  static String destination(String target, String name) {
    final parts = name.split('/').where((part) => part.isNotEmpty).toList();
    if (name.startsWith('/') ||
        parts.isEmpty ||
        parts.any(
          (part) => part == '..' || part == '.' || part.contains(':'),
        )) {
      throw FormatException('Zip entry "$name" would leave its folder');
    }
    return '$target/${parts.join('/')}';
  }

  /// Unpacks [archive] into [target], which need not exist. Every file is
  /// checked against the size and the CRC-32 its entry names. [progress]
  /// is told the bytes written so far and their total, about once a
  /// megabyte. [stop] is asked before each piece is read; once it answers
  /// true, unpacking ends with [ZipStopped] and its files closed, so what
  /// was written can be deleted.
  static Future<void> extract(
    String archive,
    String target, {
    void Function(int written, int total)? progress,
    Future<bool> Function()? stop,
  }) async {
    final file = File(archive).openSync();
    try {
      final all = entries(file);
      final total = all.fold<int>(0, (sum, entry) => sum + entry.size);
      var written = 0;
      var reported = 0;
      Directory(target).createSync(recursive: true);
      for (final entry in all) {
        final path = destination(target, entry.name);
        if (entry.isDirectory) {
          Directory(path).createSync(recursive: true);
          continue;
        }
        File(path).parent.createSync(recursive: true);
        file.setPositionSync(entry.offset);
        final header = file.readSync(30);
        if (header.length != 30 ||
            ByteData.sublistView(header).getUint32(0, Endian.little) !=
                0x04034b50) {
          throw FormatException('Zip entry "${entry.name}" has no header');
        }
        final local = ByteData.sublistView(header);
        file.setPositionSync(
          entry.offset +
              30 +
              local.getUint16(26, Endian.little) +
              local.getUint16(28, Endian.little),
        );
        final output = File(path).openSync(mode: FileMode.write);
        var crc = 0xFFFFFFFF;
        var size = 0;
        void write(List<int> bytes) {
          output.writeFromSync(bytes);
          crc = _crc(crc, bytes);
          size += bytes.length;
          written += bytes.length;
          if (written - reported >= _piece) {
            reported = written;
            progress?.call(written, total);
          }
        }

        try {
          final inflate = entry.method == 8
              ? ZLibDecoder(raw: true).startChunkedConversion(_Pieces(write))
              : null;
          for (var left = entry.compressedSize; left > 0;) {
            if (stop != null && await stop()) throw const ZipStopped();
            final piece = file.readSync(min(left, _piece));
            if (piece.isEmpty) {
              throw FormatException('Zip entry "${entry.name}" is cut short');
            }
            left -= piece.length;
            if (inflate == null) {
              write(piece);
            } else {
              inflate.add(piece);
            }
          }
          inflate?.close();
        } finally {
          output.closeSync();
        }
        if (size != entry.size || (crc ^ 0xFFFFFFFF) != entry.crc) {
          throw FormatException('Zip entry "${entry.name}" is damaged');
        }
      }
      progress?.call(written, total);
    } finally {
      file.closeSync();
    }
  }

  static final Uint32List _crcTable = () {
    final table = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = c & 1 != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      table[n] = c;
    }
    return table;
  }();

  static int _crc(int crc, List<int> bytes) {
    final table = _crcTable;
    for (var i = 0; i < bytes.length; i++) {
      crc = table[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8);
    }
    return crc;
  }
}

/// Hands each inflated piece on as it is produced.
class _Pieces implements Sink<List<int>> {
  _Pieces(this.write);
  final void Function(List<int> bytes) write;
  @override
  void add(List<int> data) => write(data);
  @override
  void close() {}
}
