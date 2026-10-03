import 'package:altranscribe/data/models/transcript_record.dart';

class TranslationContext {
  const TranslationContext(this.text, this.translation);
  final String text;
  final String? translation;
  Map<String, Object?> toJson() => {
    'original': text,
    if (translation != null) 'translation': translation,
  };
}

class TranslationContextPolicy {
  const TranslationContextPolicy({this.automatic = true, this.count = 6});
  final bool automatic;
  final int count;

  factory TranslationContextPolicy.fromJson(Map value) =>
      TranslationContextPolicy(
        automatic: value['automatic'] as bool? ?? true,
        count: (value['count'] as int? ?? 6).clamp(0, 20),
      );

  Map<String, Object?> toJson() => {'automatic': automatic, 'count': count};

  List<TranslationContext> select(
    TranscriptRecord record,
    TranscriptLine current,
  ) {
    final earlier = record.lines
        .takeWhile((line) => line != current)
        .where(
          (line) =>
              line.source == current.source &&
              line.endMs <= current.startMs &&
              line.transcriptionStatus == 'done' &&
              line.displayText.trim().isNotEmpty,
        )
        .toList();
    final eligible = earlier.where(
      (line) => !automatic || current.startMs - line.endMs <= 90000,
    );
    final recent = eligible
        .toList()
        .reversed
        .take(automatic ? 6 : count.clamp(0, 20))
        .toList()
        .reversed
        .toList();
    // An earlier line outside that window that names the same person, place
    // or term shows how it was translated, which keeps the name consistent
    // without another model call.
    final references = <TranscriptLine>[];
    final names = automatic || count > 0
        ? nameTokens(current.displayText)
        : const <String>{};
    for (final line in earlier.reversed) {
      if (names.isEmpty || references.length == 2) break;
      final translation = line.displayTranslation;
      if (recent.contains(line) ||
          line.translationStatus != 'done' ||
          translation == null ||
          translation.trim().isEmpty) {
        continue;
      }
      if (names.any((name) => mentions(line.displayText, name))) {
        references.add(line);
      }
    }
    return bound([
      for (final line in references.reversed)
        TranslationContext(line.displayText, line.displayTranslation),
      for (final line in recent)
        TranslationContext(
          line.displayText,
          line.translationStatus == 'done' ? line.displayTranslation : null,
        ),
    ]);
  }

  static final _pronouns = RegExp(
    r"^(I|I'm|I'll|I've|I'd|OK|Okay|Yes|No|Oh|Um|Uh|Hmm)$",
  );

  /// Common words that are capitalized only because they open a sentence.
  static final _starters = [
    'A An The This That These Those There Here It Its He She We You They Me',
    'Him Us My His Her Our Your Their What Why How Where Who Which When While',
    "If And But Or So Then Now Well Also Just Let Let's In On At For To From",
    'With After Before As Because Maybe Please Thanks Thank Do Does Did Is',
    'Are Was Were Can Could Will Would Should All Some Not One Actually',
    'Really Right Sure',
  ].join(' ').split(' ').toSet();

  /// Words that look like names or terms: capitalized or all-caps Latin words
  /// that are not common sentence openers, Latin words inside Chinese,
  /// Japanese or Korean text, and katakana runs.
  static Set<String> nameTokens(String text) {
    final tokens = <String>{};
    final cjk = RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]');
    final amongCjk = cjk.hasMatch(text);
    for (final match in RegExp(r"[A-Za-z][A-Za-z0-9'’-]*").allMatches(text)) {
      final word = match[0]!.replaceAll(RegExp(r"['’-]+$"), '');
      if (word.length < 2 || _pronouns.hasMatch(word)) continue;
      if (amongCjk) {
        tokens.add(word);
        continue;
      }
      if (!RegExp(r'^[A-Z]').hasMatch(word)) continue;
      final before = text.substring(0, match.start).trimRight();
      final opensSentence =
          before.isEmpty || RegExp(r'[.!?。！？:;]$').hasMatch(before);
      if (!opensSentence || !_starters.contains(word.replaceAll('’', "'"))) {
        tokens.add(word);
      }
    }
    for (final match in RegExp(r'[\u30a1-\u30fa\u30fc]{2,}').allMatches(text)) {
      final run = match[0]!;
      if (run.replaceAll('ー', '').runes.length >= 2) tokens.add(run);
    }
    return tokens;
  }

  static bool mentions(String text, String name) =>
      RegExp(r'[A-Za-z]').hasMatch(name)
      ? RegExp('(?<![A-Za-z0-9])${RegExp.escape(name)}(?![A-Za-z0-9])')
            .hasMatch(text)
      : text.contains(name);

  // Bound every provider's prompt, including a single long cloud/file segment.
  static List<TranslationContext> bound(List<TranslationContext> items) {
    var remaining = 2400;
    final result = <TranslationContext>[];
    for (final item in items.reversed) {
      if (remaining == 0) break;
      final original = item.text.runes.toList();
      final translated = item.translation?.runes.toList() ?? <int>[];
      final originalBudget = translated.isEmpty ? remaining : remaining ~/ 2;
      final text = String.fromCharCodes(
        original.skip(
          (original.length - originalBudget).clamp(0, original.length),
        ),
      );
      remaining -= text.runes.length;
      final translation = String.fromCharCodes(
        translated.skip(
          (translated.length - remaining).clamp(0, translated.length),
        ),
      );
      remaining -= translation.runes.length;
      result.add(
        TranslationContext(text, translation.isEmpty ? null : translation),
      );
    }
    return result.reversed.toList();
  }
}
