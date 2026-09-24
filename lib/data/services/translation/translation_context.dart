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
    final previous = record.lines.takeWhile((line) => line != current);
    final eligible = previous
        .where(
          (line) =>
              line.source == current.source &&
              line.endMs <= current.startMs &&
              line.transcriptionStatus == 'done' &&
              line.displayText.trim().isNotEmpty &&
              (!automatic || current.startMs - line.endMs <= 90000),
        )
        .toList();
    return bound([
      for (final line
          in eligible.reversed
              .take(automatic ? 6 : count.clamp(0, 20))
              .toList()
              .reversed)
        TranslationContext(
          line.displayText,
          line.translationStatus == 'done' ? line.displayTranslation : null,
        ),
    ]);
  }

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
