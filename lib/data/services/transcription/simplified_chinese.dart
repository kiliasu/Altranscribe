/// Longest dictionary match, phrases taking precedence over single characters.
/// Uses OpenCC's t2s dictionaries, without regional wording or an inference model.
class SimplifiedChinese {
  SimplifiedChinese(Iterable<String> tables) {
    for (final table in tables) {
      for (final line in table.split('\n')) {
        final fields = line.trim().split('\t');
        if (fields.length != 2 || fields.first.startsWith('#')) continue;
        _dictionary[fields.first] = fields.last.split(' ').first;
        final first = fields.first.codeUnitAt(0);
        final length = fields.first.length;
        if (length > (_lengths[first] ?? 0)) _lengths[first] = length;
      }
    }
  }
  final _dictionary = <String, String>{};
  final _lengths = <int, int>{};

  String convert(String text) {
    final result = StringBuffer();
    var index = 0;
    while (index < text.length) {
      var length = (_lengths[text.codeUnitAt(index)] ?? 1).clamp(
        1,
        text.length - index,
      );
      String? replacement;
      while (length > 0) {
        replacement = _dictionary[text.substring(index, index + length)];
        if (replacement != null) break;
        length--;
      }
      result.write(replacement ?? text[index]);
      index += length == 0 ? 1 : length;
    }
    return result.toString();
  }
}
