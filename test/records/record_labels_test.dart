import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/features/records/record_labels.dart';
import 'package:flutter_test/flutter_test.dart';

TranscriptRecord record({
  String? title,
  String? inputFile,
  String status = 'completed',
  int lines = 2,
  DateTime? at,
}) => TranscriptRecord(
  id: 'r',
  createdAt: at ?? DateTime(2026, 11, 10, 22, 3, 6),
  language: 'en',
  sources: ['microphone'],
  title: title,
  inputFile: inputFile,
  status: status,
  lines: [
    for (var i = 0; i < lines; i++)
      TranscriptLine(
        source: 'microphone',
        startMs: i * 60000,
        endMs: i * 60000 + 35000,
        text: 'line $i',
      ),
  ],
);

void main() {
  final now = DateTime(2026, 11, 11, 0, 30);

  test('a date reads the way one would say it', () {
    expect(
      recordDate(DateTime(2026, 11, 11, 0, 5), false, now: now),
      '今天 00:05',
    );
    expect(
      recordDate(DateTime(2026, 11, 11, 0, 5), true, now: now),
      'Today 00:05',
    );
    // Half an hour ago was yesterday: days are the calendar's, not 24 hours.
    expect(
      recordDate(DateTime(2026, 11, 10, 23, 59), false, now: now),
      '昨天 23:59',
    );
    expect(
      recordDate(DateTime(2026, 11, 10, 9, 7), true, now: now),
      'Yesterday 09:07',
    );
    expect(
      recordDate(DateTime(2026, 9, 12, 10, 20), false, now: now),
      '9月12日 10:20',
    );
    expect(
      recordDate(DateTime(2026, 9, 12, 10, 20), true, now: now),
      'Sep 12, 10:20',
    );
    expect(
      recordDate(DateTime(2025, 12, 31, 8), false, now: now),
      '2025年12月31日',
    );
    expect(
      recordDate(DateTime(2025, 12, 31, 8), true, now: now),
      'Dec 31, 2025',
    );
  });

  test('a transcript is summed up in one line', () {
    // Titled: its day, how long it runs and its lines. Saved goes unsaid.
    expect(
      recordLine(record(title: 'Interview'), false, now: now),
      '昨天 22:03 · 1:35 · 2 段',
    );
    expect(
      recordLine(record(inputFile: r'C:\a\talk.m4a'), true, now: now),
      'Yesterday 22:03 · 1:35 · 2 segments',
    );
    // Untitled, the title is the date already.
    expect(recordLine(record(), false, now: now), '1:35 · 2 段');
    // Nothing recognized: no length to give.
    expect(
      recordLine(record(title: 'Empty', lines: 0), false, now: now),
      '昨天 22:03 · 0 段',
    );
    // Any other state is named.
    expect(
      recordLine(
        record(title: 'Cut short', status: 'interrupted'),
        false,
        now: now,
      ),
      '昨天 22:03 · 1:35 · 2 段 · 上次意外中断 · 已恢复结果',
    );
  });
}
