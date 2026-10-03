import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/transcription/transcript_assembler.dart';

/// Join only model-selected adjacent fragments. Original segments retain their
/// exact text, timings and spelling edits for inspection and future exports.
void mergeTranscriptFragments(TranscriptRecord record, List<int> boundaries) {
  final selected = boundaries.toSet();
  final result = <TranscriptLine>[];
  for (var i = 0; i < record.lines.length; i++) {
    final next = record.lines[i];
    final previous = result.lastOrNull;
    if (i == 0 ||
        !selected.contains(i) ||
        previous == null ||
        previous.source != next.source ||
        previous.transcriptionStatus != 'done' ||
        next.transcriptionStatus != 'done' ||
        previous.translation != null ||
        next.translation != null ||
        next.startMs < previous.endMs ||
        next.startMs - previous.endMs > 1500 ||
        previous.displayText.runes.length + next.displayText.runes.length >
            600) {
      result.add(next);
      continue;
    }
    final left = previous.displayText.trimRight().replaceFirst(
      RegExp(r'[.。]+$'),
      '',
    );
    final right = next.displayText.trimLeft();
    final separator = joinSeparator(left, right);
    result[result.length - 1] = TranscriptLine(
      source: previous.source,
      startMs: previous.startMs,
      endMs: next.endMs,
      text: '${previous.text}\n${next.text}',
      revisedText: '$left$separator$right',
      timingEstimated: previous.timingEstimated || next.timingEstimated,
      textEdits: [...previous.textEdits, ...next.textEdits],
      originalSegments: [
        if (previous.originalSegments.isEmpty)
          previous
        else
          ...previous.originalSegments,
        if (next.originalSegments.isEmpty) next else ...next.originalSegments,
      ],
    );
  }
  record.lines
    ..clear()
    ..addAll(result);
}
