import 'package:altranscribe/data/services/files/text_cleanup.dart';

/// The user's own translation requirements; empty means none. The core
/// translation instructions stay fixed, so these can only add to them.
const defaultTranslationRules = '';

/// Requirements saved by an earlier build began with this sentence and were a
/// full default prompt rather than the user's own wording; they count as none.
String normalizeTranslationRules(String? value) {
  final text = value?.trim() ?? '';
  return text.startsWith('Preserve meaning, tone, numbers and negations.')
      ? ''
      : text;
}

/// A line that is one sound, word or short phrase said three or more times
/// with only punctuation around it, such as 啊啊啊啊啊啊, "ha ha ha" or a
/// recognition loop. Such a line is translated as said, never shortened.
final _repetition = RegExp(
  r'(\p{L}.{0,39}?)(?:[\s,.!?;:…、，。！？~～-]*\1){2,}',
  caseSensitive: false,
  unicode: true,
);
bool isRepetition(String text) =>
    _repetition.hasMatch(text) &&
    !RegExp(
      r'[\p{L}\p{N}]',
      unicode: true,
    ).hasMatch(text.replaceAll(_repetition, ''));

class TranslationTerm {
  const TranslationTerm({
    required this.source,
    required this.translation,
    required this.type,
    this.aliases = const [],
  });
  final String source, translation, type;
  final List<String> aliases;
  Iterable<String> get names => [source, ...aliases];
  bool occursIn(String text) =>
      names.any((name) => CleanupEdit.pattern(name).hasMatch(text));
  bool isTranslatedIn(String text) =>
      CleanupEdit.pattern(translation).hasMatch(text);
  bool usesTargetScript(String? target) =>
      target != 'zh' ||
      type != 'person' ||
      (RegExp(r'[\u3400-\u9fff]').hasMatch(translation) &&
          !RegExp(r'[A-Za-z]').hasMatch(translation));
  Map<String, Object?> toJson() => {
    'source': source,
    'translation': translation,
    'type': type,
    'aliases': aliases,
  };
  factory TranslationTerm.fromJson(Map value) => TranslationTerm(
    source: value['source'] as String,
    translation: value['translation'] as String,
    type: value['type'] as String,
    aliases: (value['aliases'] as List? ?? []).cast<String>(),
  );

  /// Prefer a whole name over another entity matching only part of that name.
  static List<TranslationTerm> relevant(
    List<TranslationTerm> terms,
    String text,
  ) {
    final matches = [
      for (final term in terms)
        for (final name in term.names)
          for (final match in CleanupEdit.pattern(name).allMatches(text))
            (term, match.start, match.end),
    ];
    return {
      for (final match in matches)
        if (!matches.any(
          (other) =>
              other.$1 != match.$1 &&
              other.$2 <= match.$2 &&
              other.$3 >= match.$3 &&
              other.$3 - other.$2 > match.$3 - match.$2,
        ))
          match.$1,
    }.toList();
  }

  /// Only accept names found in the input. Existing translations are immutable.
  static List<TranslationTerm> accept(
    List<TranslationTerm> known,
    List<dynamic> proposals,
    String text,
  ) {
    final result = [...known];
    bool valid(Object? value) =>
        value is String &&
        value.trim() == value &&
        value.isNotEmpty &&
        value.runes.length <= 120 &&
        !value.contains('\n');
    for (final value in proposals.take(64)) {
      if (value is! Map ||
          !valid(value['source']) ||
          !valid(value['translation']) ||
          value['aliases'] is! List ||
          ![
            'person',
            'place',
            'building',
            'organization',
            'term',
          ].contains(value['type'])) {
        continue;
      }
      final source = value['source'] as String;
      final aliases = (value['aliases'] as List)
          .whereType<String>()
          .where(
            (name) => valid(name) && CleanupEdit.pattern(name).hasMatch(text),
          )
          .take(12)
          .toSet();
      if (!CleanupEdit.pattern(source).hasMatch(text) && aliases.isEmpty) {
        continue;
      }
      final names = {source, ...aliases};
      final existing = result
          .where((term) => term.names.any(names.contains))
          .toList();
      // A proposal may not collapse two previously distinct entities.
      if (existing.length > 1) continue;
      if (existing.isNotEmpty) {
        final old = existing.single;
        result[result.indexOf(old)] = TranslationTerm(
          source: old.source,
          translation: old.translation,
          type: old.type,
          aliases: {...old.aliases, ...names}.difference({old.source}).toList(),
        );
      } else {
        result.add(
          TranslationTerm(
            source: source,
            translation: value['translation'] as String,
            type: value['type'] as String,
            aliases: aliases.difference({source}).toList(),
          ),
        );
      }
    }
    return result;
  }
}

class TextPreparation {
  const TextPreparation({this.terms = const [], this.joins = const []});
  final List<TranslationTerm> terms;

  /// Index of the second segment at a boundary the model wants to join.
  final List<int> joins;
}
