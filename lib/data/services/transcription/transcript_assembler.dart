import 'package:altranscribe/data/models/transcript_record.dart';

final _ends = RegExp(
  r'''[。！？!?]+[”’"）)\]」』》】]*|\.+[”’"）)\]」』》】]*(?=\s|$)|\n+''',
);
final _abbreviation = RegExp(
  r'(?:\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|e\.g|i\.e)|\b[A-Z])$',
  caseSensitive: false,
);
final _cjk = RegExp(r'[\u2e80-\u9fff\uac00-\ud7af\uf900-\ufaff]');
final _complete = RegExp(r'''[。！？.!?][”’"）)\]」』》】]*$''');

/// Something a reader can see: a piece made only of invisible characters,
/// such as zero-width marks from a model, is not a sentence.
final _visible = RegExp(r'[\p{L}\p{N}\p{P}\p{S}]', unicode: true);

/// Punctuation boundaries, with a soft reading limit for unpunctuated speech.
/// No words/punctuation are invented and decimal points/abbreviations stay intact.
List<String> transcriptSentences(String text) {
  final result = <String>[];
  void add(String value) {
    var rest = value.trim();
    final limit = _cjk.hasMatch(rest) ? 100 : 240;
    while (rest.runes.length > limit) {
      final runes = rest.runes.toList();
      var cut = -1;
      for (var i = limit ~/ 2; i < limit; i++) {
        if (RegExp(r'[\s，,；;：:]').hasMatch(String.fromCharCode(runes[i]))) {
          cut = i + 1;
        }
      }
      if (cut < 0) {
        for (var i = limit; i >= limit ~/ 2; i--) {
          if (_cjk.hasMatch(String.fromCharCode(runes[i - 1])) ||
              _cjk.hasMatch(String.fromCharCode(runes[i]))) {
            cut = i;
            break;
          }
        }
        if (cut < 0) {
          // Keep long identifiers/URLs/words whole, even past the soft limit.
          cut = runes.indexWhere((rune) => rune == 32, limit);
          if (cut < 0) break;
        }
      }
      result.add(String.fromCharCodes(runes.take(cut)).trim());
      rest = String.fromCharCodes(runes.skip(cut)).trim();
    }
    if (_visible.hasMatch(rest)) result.add(rest);
  }

  var start = 0;
  for (final end in _ends.allMatches(text)) {
    if (end[0]!.startsWith('.') &&
        end.end < text.length &&
        _abbreviation.hasMatch(text.substring(start, end.start))) {
      continue;
    }
    add(text.substring(start, end.end));
    start = end.end;
  }
  add(text.substring(start));
  return result;
}

String readableTranscript(String text) =>
    transcriptSentences(text).join('\n\n');

/// Audio windows are replaceable hypotheses; reading rows are sentences.
/// Only the unfinished tail of an adjacent window from the same source can join.
class TranscriptAssembler {
  final _previews = <(String, int), List<TranscriptLine>>{};
  final _tails = <String, TranscriptLine>{};

  List<TranscriptLine> accept(
    TranscriptRecord record, {
    required String source,
    required int startMs,
    required int endMs,
    required String text,
    bool partial = false,
    bool continues = false,
  }) {
    final key = (source, startMs);
    // A temporarily empty hypothesis should not flicker the previous preview.
    if (partial && text.trim().isEmpty) return const [];
    for (final old in _previews.remove(key) ?? <TranscriptLine>[]) {
      record.lines.remove(old);
    }
    final parts = transcriptSentences(text);
    final lines = <TranscriptLine>[];
    final total = parts.fold<int>(0, (sum, part) => sum + part.runes.length);
    var consumed = 0;
    for (final part in parts) {
      final from = startMs + (endMs - startMs) * consumed ~/ total;
      consumed += part.runes.length;
      lines.add(
        TranscriptLine(
          source: source,
          startMs: from,
          endMs: startMs + (endMs - startMs) * consumed ~/ total,
          text: part,
          transcriptionStatus: partial ? 'partial' : 'done',
          timingEstimated: parts.length > 1,
        ),
      );
    }
    if (!partial) {
      final tail = _tails.remove(source);
      if (tail != null &&
          record.lines.contains(tail) &&
          lines.isNotEmpty &&
          startMs >= tail.endMs &&
          startMs - tail.endMs <= 1200 &&
          !_complete.hasMatch(tail.text) &&
          tail.text.runes.length + lines.first.text.runes.length <=
              (_cjk.hasMatch(tail.text + lines.first.text) ? 100 : 240)) {
        final first = lines.first;
        final separator =
            _cjk.hasMatch(tail.text.substring(tail.text.length - 1)) ||
                _cjk.hasMatch(first.text.substring(0, 1))
            ? ''
            : ' ';
        record.lines.remove(tail);
        lines[0] = TranscriptLine(
          source: source,
          startMs: tail.startMs,
          endMs: first.endMs,
          text: '${tail.text}$separator${first.text}',
          timingEstimated: tail.timingEstimated || first.timingEstimated,
        );
      }
      if (continues && lines.isNotEmpty) _tails[source] = lines.last;
    } else {
      _previews[key] = lines;
    }
    record.lines.addAll(lines);
    record.lines.sort((a, b) => a.startMs.compareTo(b.startMs));
    return lines;
  }
}
