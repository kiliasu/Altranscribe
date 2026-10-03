import 'dart:convert';

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/files/sentence_merger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TranscriptLine line(
    String text,
    int start, {
    String source = 'file',
    int? end,
  }) => TranscriptLine(
    source: source,
    startMs: start,
    endMs: end ?? start + 1000,
    text: text,
  );
  TranscriptRecord record(List<TranscriptLine> lines) => TranscriptRecord(
    id: 'session-1',
    createdAt: DateTime(2026),
    language: 'en',
    sources: ['file'],
    lines: lines,
  );

  test('joins selected fragments without losing raw text, timing or later sentence boundaries', () {
    final input = record([
      line('We need to.', 0),
      line('finish the work.', 1000),
      line('Tomorrow is Friday.', 2000),
    ]);
    mergeTranscriptFragments(input, [1]);
    expect(input.lines, hasLength(2));
    expect(input.lines.first.displayText, 'We need to finish the work.');
    expect(input.lines.first.startMs, 0);
    expect(input.lines.first.endMs, 2000);
    expect(input.lines.last.text, 'Tomorrow is Friday.');
    final restored = TranscriptRecord.fromJson(
      jsonDecode(jsonEncode(input.toJson())) as Map<String, dynamic>,
    );
    expect(restored.lines.first.originalSegments.map((s) => s.text), [
      'We need to.',
      'finish the work.',
    ]);
    expect(restored.lines.first.originalSegments.last.startMs, 1000);
  });

  test('Chinese and Japanese join without a space; Korean keeps it', () {
    for (final (left, right, joined) in [
      ('我们明天', '再讨论。', '我们明天再讨论。'),
      ('今日は', '雨です。', '今日は雨です。'),
      ('오늘은.', '날씨가 좋아요.', '오늘은 날씨가 좋아요.'),
      ('We met', 'yesterday.', 'We met yesterday.'),
    ]) {
      final transcript = record([line(left, 0), line(right, 1000)]);
      mergeTranscriptFragments(transcript, [1]);
      expect(transcript.lines.single.displayText, joined);
    }
  });

  test('rejects nonadjacent timing, overlaps, other sources and excessive merged passages', () {
    final input = record([
      line('One', 0),
      line('Two', 900),
      line('Three', 5000),
      line('Four', 6000, source: 'system'),
      line('Long ' * 140, 7000, source: 'system'),
    ]);
    mergeTranscriptFragments(input, [-1, 1, 2, 3, 4, 100]);
    expect(input.lines, hasLength(5));
    expect(input.lines.every((s) => s.originalSegments.isEmpty), true);
  });
}
