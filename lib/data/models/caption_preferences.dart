import 'package:altranscribe/data/models/transcript_record.dart';

class CaptionPreferences {
  const CaptionPreferences({
    this.sentences = 2,
    this.original = true,
    this.translation = true,
    this.opacity = .94,
    this.fontSize = 24,
    this.font = 'RobotoFlex',
  });
  static const fonts = ['RobotoFlex', 'NotoSansSC', 'Segoe UI'];
  final int sentences;
  final bool original, translation;
  final double opacity, fontSize;
  final String font;

  factory CaptionPreferences.fromJson(Map value) {
    final original = value['original'] as bool? ?? true;
    final translation = value['translation'] as bool? ?? true;
    return CaptionPreferences(
      sentences: (value['sentences'] as int? ?? 2).clamp(1, 8),
      original: original || !translation,
      translation: translation,
      opacity: (value['opacity'] as num? ?? .94).toDouble().clamp(.4, 1),
      fontSize: (value['fontSize'] as num? ?? 24).toDouble().clamp(14, 48),
      font: fonts.contains(value['font'])
          ? value['font'] as String
          : fonts.first,
    );
  }
  Map<String, Object?> toJson() => {
    'sentences': sentences,
    'original': original,
    'translation': translation,
    'opacity': opacity,
    'fontSize': fontSize,
    'font': font,
  };
  CaptionPreferences copyWith({
    int? sentences,
    bool? original,
    bool? translation,
    double? opacity,
    double? fontSize,
    String? font,
  }) => CaptionPreferences.fromJson({
    ...toJson(),
    'sentences': ?sentences,
    'original': ?original,
    'translation': ?translation,
    'opacity': ?opacity,
    'fontSize': ?fontSize,
    'font': ?font,
  });
}

List<String> captionSentences(String text) =>
    RegExp(r'.+?(?:[。！？]+[”’"\x27]*|[.!?]+[”’"\x27]*(?=\s|$)|\n|$)')
        .allMatches(text)
        .map((match) => match[0]!.trim())
        .where((s) => s.isNotEmpty)
        .toList();

/// Caption-only slicing; saved transcripts and streaming results stay intact.
/// Providers need not align sentence boundaries across the two languages.
List<Map<String, Object?>> captionRows(TranscriptRecord? record, int count) {
  final rows = <Map<String, Object?>>[];
  var remaining = count;
  for (final line in (record?.lines ?? <TranscriptLine>[]).reversed) {
    if (remaining <= 0) break;
    final original = captionSentences(line.displayText);
    final translation = captionSentences(line.displayTranslation ?? '');
    if (original.isEmpty && translation.isEmpty) continue;
    final used =
        (original.length > translation.length
                ? original.length
                : translation.length)
            .clamp(1, remaining);
    String tail(List<String> sentences) => sentences
        .skip((sentences.length - used).clamp(0, sentences.length))
        .join(' ');
    rows.add({
      'original': tail(original),
      'translation': tail(translation),
      'status': line.translationStatus,
      'source': line.source,
    });
    remaining -= used;
  }
  return rows.reversed.toList();
}
