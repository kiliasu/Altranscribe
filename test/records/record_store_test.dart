import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late RecordStore store;
  setUp(() async {
    final root = await Directory('build/test-data').create(recursive: true);
    directory = await root.createTemp('record-store-');
    store = RecordStore(directory);
  });
  tearDown(() => directory.delete(recursive: true));

  TranscriptRecord record(String id, int count) => TranscriptRecord(
    id: id,
    createdAt: DateTime(2026),
    language: 'en',
    sources: ['microphone'],
    lines: List.generate(
      count,
      (i) => TranscriptLine(
        source: 'microphone',
        startMs: i * 2000,
        endMs: i * 2000 + 1000,
        text: 'Sentence $i.',
      ),
    ),
  );

  test(
    'queued long snapshots retain call-time values and write in order',
    () async {
      final item = record('session-1', 20000);
      final first = store.save(item);
      item.lines.first.text = 'Changed after the first save.';
      final copy = record('session-2', 1)..lines.first.text = 'Original.';
      final second = store.save(copy);
      copy.lines.first.text = 'Changed after the second save.';
      await Future.wait([first, second]);
      final saved = await store.loadRecords();
      expect(
        saved.firstWhere((record) => record.id == item.id).lines.first.text,
        'Sentence 0.',
      );
      expect(
        saved.firstWhere((record) => record.id == copy.id).lines.first.text,
        'Original.',
      );
      final older = store.save(item);
      item.lines.last.translation = '最后一句';
      item.lines.last.translationStatus = 'done';
      item.status = 'completed';
      final newer = store.save(item);
      await Future.wait([older, newer]);
      final latest = (await store.loadRecords()).firstWhere(
        (r) => r.id == item.id,
      );
      expect(latest.lines, hasLength(20000));
      expect(latest.lines.last.translation, '最后一句');
      expect(latest.status, 'completed');
    },
  );

  test(
    'delete waits for pending encoding and cannot resurrect a record',
    () async {
      final item = record('session-1', 20000);
      await Future.wait([store.save(item), store.delete(item.id)]);
      expect(await store.loadRecords(), isEmpty);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('a failed write does not poison later saves or settings', () async {
    final blocked = await Directory('${directory.path}/session-1.json.tmp')
        .create();
    await expectLater(
      store.save(record('session-1', 1)),
      throwsA(isA<FileSystemException>()),
    );
    await blocked.delete();
    await store.save(record('session-1', 1));
    await store.saveSettings({'language': 'zh'});
    expect((await store.loadRecords()).single.lines.single.text, 'Sentence 0.');
    expect(await store.loadSettings(), {'language': 'zh'});
    expect(
      jsonDecode(await File('${directory.path}/session-1.json').readAsString()),
      containsPair('version', 6),
    );
  });
}
