import 'dart:collection';

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/transcription/transcript_assembler.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:flutter_test/flutter_test.dart';

class CountingLines extends ListBase<TranscriptLine> {
  CountingLines(this.values);
  final List<TranscriptLine> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => values.length = value;
  @override
  TranscriptLine operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, TranscriptLine value) => values[index] = value;
  @override
  void add(TranscriptLine value) => values.add(value);
  @override
  void insert(int index, TranscriptLine value) => values.insert(index, value);
  @override
  TranscriptLine removeAt(int index) => values.removeAt(index);
}

TranscriptLine line(int start, String text, {String source = 'microphone'}) =>
    TranscriptLine(
      source: source,
      startMs: start,
      endMs: start + 1000,
      text: text,
      translation: '译文',
      translationStatus: 'done',
    );

TranscriptRecord record(List<TranscriptLine> lines) => TranscriptRecord(
  id: 'session-1',
  createdAt: DateTime(2026),
  language: 'en',
  sources: ['microphone', 'system'],
  lines: lines,
);

void main() {
  test('replacing a preview does not revisit the whole long conversation', () {
    final lines = CountingLines([
      for (var i = 0; i < 20000; i++) line(i * 2000, 'A finished sentence.'),
    ]);
    final item = record(lines);
    final assembler = TranscriptAssembler();
    for (var i = 0; i < 3; i++) {
      assembler.accept(
        item,
        source: 'microphone',
        startMs: 40000000,
        endMs: 40001000,
        text: 'A changing preview $i.',
        partial: true,
      );
    }
    expect(lines.reads, lessThan(200));
    expect(lines.length, 20001);
    expect(lines.last.text, 'A changing preview 2.');
    expect(lines.first.text, 'A finished sentence.');
  });

  test('late and equal-time sources remain ordered when previews finish', () {
    final item = record([]);
    final assembler = TranscriptAssembler();
    void accept(
      String source,
      int start,
      String text, {
      bool partial = false,
    }) => assembler.accept(
      item,
      source: source,
      startMs: start,
      endMs: start + 1000,
      text: text,
      partial: partial,
    );
    accept('system', 4000, 'Later.');
    accept('microphone', 0, 'Old.');
    accept('microphone', 2000, 'Preview.', partial: true);
    accept('system', 2000, 'Other source.');
    accept('microphone', 2000, 'Final.');
    expect(item.lines.map((line) => line.startMs), [0, 2000, 2000, 4000]);
    expect(item.lines.map((line) => line.text), [
      'Old.',
      'Other source.',
      'Final.',
      'Later.',
    ]);
  });

  test('ordinary translation context reads only the recent tail', () {
    final lines = CountingLines([
      for (var i = 0; i < 20000; i++) line(i * 2000, 'This is sentence $i.'),
    ]);
    final current = lines.last;
    final context = const TranslationContextPolicy().select(
      record(lines),
      current,
    );
    expect(lines.reads, lessThan(100));
    expect(context.map((item) => item.text), [
      for (var i = 19993; i < 19999; i++) 'This is sentence $i.',
    ]);
  });

  test(
    'long context retains old name translations and excludes future text',
    () {
      final name = line(0, 'Hinata joined.')..translation = '日向加入了。';
      final current = line(50000000, 'Hinata is ready.');
      final item = record([
        name,
        for (var i = 1; i < 20000; i++) line(i * 2000, 'A finished sentence.'),
        current,
        line(50002000, 'Hinata left.'),
      ]);
      final context = const TranslationContextPolicy().select(item, current);
      expect(context.single.text, name.text);
      expect(context.single.translation, name.translation);
      expect(
        const TranslationContextPolicy(
          automatic: false,
          count: 0,
        ).select(item, current),
        isEmpty,
      );
    },
  );
}
