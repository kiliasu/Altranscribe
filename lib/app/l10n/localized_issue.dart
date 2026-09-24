import 'strings.dart';

String localizedIssue(String value, bool english) {
  String t(String key) => strings[key]![english ? 1 : 0];
  final platformCode = RegExp(r'^PlatformException\(([^,]+),')
      .firstMatch(value)
      ?.group(1);
  final key =
      platformCode ??
      value.replaceFirst(RegExp(r'^(FormatException|Bad state):\s*'), '');
  if (key.startsWith('fileDecodeFailed:')) {
    return '${t('fileDecodeFailed')}\n${key.substring('fileDecodeFailed:'.length).trim()}';
  }
  return strings.containsKey(key) ? t(key) : value;
}
