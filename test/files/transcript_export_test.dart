import 'dart:typed_data';

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/files/transcript_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final record = TranscriptRecord(
    id: 'r1',
    createdAt: DateTime(2026, 9, 24, 12, 14, 3),
    language: 'en',
    targetLanguage: 'zh',
    sources: ['microphone', 'system'],
    inputFile: r'C:\audio\lecture <1>.wav',
    title: 'Solar / panels: intro?',
    summary: 'Sun & silicon.\nTwo lines.',
    lines: [
      TranscriptLine(
        source: 'system',
        startMs: 0,
        endMs: 2000,
        text: 'Good <morning>',
        translation: '大家早上好。',
      ),
      TranscriptLine(
        source: 'microphone',
        startMs: 3725000,
        endMs: 3730000,
        text: 'Later',
        timingEstimated: true,
      ),
    ],
  );
  const exporter = TranscriptExporter(ExportLabels());

  test('file names drop characters Windows rejects and keep the extension', () {
    expect(
      TranscriptExporter.fileName(record, ExportFormat.html),
      'Solar panels intro.html',
    );
    final untitled = TranscriptRecord(
      id: 'r2',
      createdAt: DateTime(2026, 1, 1),
      language: 'en',
      sources: ['microphone'],
      lines: [],
    );
    expect(
      TranscriptExporter.fileName(untitled, ExportFormat.text),
      '2026-01-01 00 00 00.txt',
    );
  });

  test('timestamps show hours only when needed and mark estimates', () {
    expect(TranscriptExporter.timestamp(0), '0:00');
    expect(TranscriptExporter.timestamp(65000), '1:05');
    expect(TranscriptExporter.timestamp(3725000), '1:02:05');
  });

  test('plain text lists summary, sources and translations', () {
    final text = exporter.text(record);
    expect(text, startsWith('Solar / panels: intro?\n'));
    expect(text, contains('2 segments · lecture <1>.wav'));
    expect(text, contains('Summary\nSun & silicon.\nTwo lines.'));
    expect(text, contains('[0:00] System audio: Good <morning>\n'));
    expect(text, contains('\n                     大家早上好。\n'));
    expect(text, contains('[≈1:02:05] Microphone: Later'));
  });

  test('markdown keeps hard line breaks between original and translation', () {
    final markdown = exporter.markdown(record);
    expect(markdown, startsWith('# Solar / panels: intro?\n'));
    expect(markdown, contains('## Summary\n\nSun & silicon.\nTwo lines.\n'));
    expect(
      markdown,
      contains('**0:00** System audio · Good <morning>  \n大家早上好。  \n'),
    );
    expect(markdown, contains('**≈1:02:05** Microphone · Later  \n'));
  });

  test('html escapes content and only adds a player when media is given', () {
    final plain = exporter.html(record);
    expect(plain, contains('<title>Solar / panels: intro?</title>'));
    expect(plain, contains('Good &lt;morning&gt;'));
    expect(plain, contains('data-start="3725000"'));
    expect(plain, contains('Sun &amp; silicon.<br>Two lines.'));
    expect(plain, isNot(contains('<audio')));
    expect(plain, isNot(contains('<script>')));

    final audio = exporter.html(
      record,
      mediaSource: 'file:///C:/audio/lecture%20%3C1%3E.wav',
      mediaMime: 'audio/wav',
    );
    expect(audio, contains('<audio id="player" controls'));
    expect(audio, contains('src="file:///C:/audio/lecture%20%3C1%3E.wav"'));
    expect(audio, contains('<script>'));

    final video = exporter.html(
      record,
      mediaSource: TranscriptExporter.dataUri(
        Uint8List.fromList([1, 2, 3]),
        'video/mp4',
      ),
      mediaMime: 'video/mp4',
    );
    expect(video, contains('<video id="player" controls'));
    expect(video, contains('src="data:video/mp4;base64,AQID"'));
  });

  test('media types come from the file extension', () {
    expect(mediaMimeType('talk.M4A'), 'audio/mp4');
    expect(mediaMimeType('clip.webm'), 'video/webm');
    expect(mediaMimeType('unknown.bin'), 'application/octet-stream');
    expect(isVideoMimeType('video/quicktime'), isTrue);
  });

  test('single-source records omit the source label', () {
    final single = TranscriptRecord(
      id: 'r3',
      createdAt: DateTime(2026, 1, 1),
      language: 'en',
      sources: ['file'],
      lines: [
        TranscriptLine(source: 'file', startMs: 500, endMs: 900, text: 'Hi'),
      ],
    );
    expect(exporter.text(single), contains('[0:00] Hi'));
    expect(exporter.markdown(single), contains('**0:00** Hi  '));
    expect(exporter.html(single), isNot(contains('class="source"')));
  });
}
