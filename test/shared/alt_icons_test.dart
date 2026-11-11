import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The code points a TrueType font gives a glyph, from its cmap subtables of
/// format 4 and 12.
Set<int> codePoints(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final tables = data.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < tables; i++) {
    final entry = 12 + 16 * i;
    if (String.fromCharCodes(bytes.sublist(entry, entry + 4)) == 'cmap') {
      cmap = data.getUint32(entry + 8);
    }
  }
  if (cmap < 0) throw const FormatException('The font has no cmap table');
  final found = <int>{};
  for (var i = 0; i < data.getUint16(cmap + 2); i++) {
    final table = cmap + data.getUint32(cmap + 8 + 8 * i);
    final format = data.getUint16(table);
    if (format == 4) {
      final segments = data.getUint16(table + 6) ~/ 2;
      final ends = table + 14;
      final starts = ends + 2 + 2 * segments;
      final deltas = starts + 2 * segments;
      final ranges = deltas + 2 * segments;
      for (var s = 0; s < segments; s++) {
        final start = data.getUint16(starts + 2 * s);
        final end = data.getUint16(ends + 2 * s);
        if (start == 0xFFFF) continue;
        final delta = data.getInt16(deltas + 2 * s);
        final range = data.getUint16(ranges + 2 * s);
        for (var code = start; code <= end; code++) {
          var glyph = range == 0
              ? (code + delta) & 0xFFFF
              : data.getUint16(ranges + 2 * s + range + 2 * (code - start));
          if (range != 0 && glyph != 0) glyph = (glyph + delta) & 0xFFFF;
          if (glyph != 0) found.add(code);
        }
      }
    } else if (format == 12) {
      for (var g = 0; g < data.getUint32(table + 12); g++) {
        final group = table + 16 + 12 * g;
        for (
          var code = data.getUint32(group);
          code <= data.getUint32(group + 4);
          code++
        ) {
          found.add(code);
        }
      }
    }
  }
  return found;
}

void main() {
  test('every icon the app names is a glyph in the bundled font', () {
    final glyphs = codePoints(
      File('assets/fonts/MaterialSymbolsRounded.ttf').readAsBytesSync(),
    );
    final named = RegExp(r'static const (\w+) = IconData\(\s*(0x[0-9a-fA-F]+)')
        .allMatches(File('lib/shared/ui/alt_icons.dart').readAsStringSync());
    expect(named.length, 65);
    // A name without a glyph would draw as an empty box.
    expect([
      for (final icon in named)
        if (!glyphs.contains(int.parse(icon[2]!))) icon[1],
    ], isEmpty);
  });

  test('the screens take their icons from that one set', () {
    // The classic Material icons are drawn heavier; one among the others
    // shows. The framework's own widgets may still use them.
    final classic = RegExp(r'(?<![A-Za-z])Icons\.\w+');
    final found = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File && file.path.endsWith('.dart'))
          for (final match in classic.allMatches(file.readAsStringSync()))
            '${file.path}: ${match[0]}',
    ];
    expect(found, isEmpty);
  });
}
