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
  // Free and needed gigabytes follow the key.
  final memory = RegExp(r'^transcribeMemory: (\S+) (\S+)$').firstMatch(key);
  if (memory != null) {
    return t('transcribeMemory')
        .replaceFirst('{free}', memory[1]!)
        .replaceFirst('{needed}', memory[2]!);
  }
  // Needed and total gigabytes follow the key.
  final short = RegExp(r'^gpuMemoryShort: (\S+) (\S+)$').firstMatch(key);
  if (short != null) {
    return t('gpuMemoryShort')
        .replaceFirst('{need}', short[1]!)
        .replaceFirst('{total}', short[2]!);
  }
  return strings.containsKey(key) ? t(key) : value;
}
