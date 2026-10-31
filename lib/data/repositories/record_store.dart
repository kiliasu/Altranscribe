import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:altranscribe/shared/platform/mobile_platform.dart';

import '../models/transcript_record.dart';

class RecordStore {
  RecordStore(this.directory);
  final Directory directory;
  Future<void> _writes = Future.value();
  factory RecordStore.local() {
    if (MobilePlatform.android) {
      final path = MobilePlatform.dataDirectory;
      if (path == null) throw StateError('Android bridge is not initialized');
      return RecordStore(Directory(path));
    }
    // An empty override, as left behind by some shells, means "not set".
    final override = Platform.environment['ALTRANSCRIBE_DATA_DIR'];
    final local = Platform.environment['LOCALAPPDATA'];
    if (override?.isNotEmpty == true) return RecordStore(Directory(override!));
    if (local == null || local.isEmpty) {
      throw UnsupportedError('Windows is required');
    }
    return RecordStore(Directory('$local/Altranscribe'));
  }
  Future<void> initialize() => directory.create(recursive: true);
  Future<Map<String, dynamic>> loadSettings() async {
    final file = File('${directory.path}/settings.json');
    return await file.exists()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
  }

  Future<void> saveSettings(Map<String, Object?> value) => _write(
    'settings.json',
    Future.value(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(value)),
    ),
  );
  Future<void> save(TranscriptRecord record) =>
      _write('${record.id}.json', _encodeRecord(record));
  Future<void> delete(String id) {
    if (!RegExp(r'^session-\d+$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid record ID');
    }
    // Wait for existing snapshots so a late write cannot recreate the record.
    final deletion = _writes.catchError((Object _) {}).then((_) async {
      for (final suffix in ['.json.tmp', '.json']) {
        final file = File('${directory.path}/$id$suffix');
        if (await file.exists()) await file.delete();
      }
    });
    _writes = deletion;
    return deletion;
  }

  Future<void> _write(String name, Future<List<int>> snapshot) {
    // ASR and translation finish independently. Serialize snapshots so their
    // temporary files cannot collide or overwrite newer results out of order.
    // Observe encoding failures immediately, even while an earlier write is
    // pending. Disk replacement still follows the order save() was called.
    final write = Future.wait<Object?>([
      _writes.catchError((Object _) {}),
      snapshot,
    ]).then((values) => _writeSnapshot(name, values[1] as List<int>));
    _writes = write;
    return write;
  }

  Future<void> _writeSnapshot(String name, List<int> snapshot) async {
    final file = File('${directory.path}/$name.tmp');
    await file.writeAsBytes(snapshot, flush: true);
    // A completed snapshot replaces the preceding one; readers never see partial JSON.
    await file.rename('${directory.path}/$name');
  }

  Future<List<TranscriptRecord>> loadRecords() => _loadRecords(directory.path);
}

// Only the record crosses the isolate boundary, never the store/write queue.
// The isolate gets a call-time copy before recognition can mutate the next row.
Future<List<int>> _encodeRecord(TranscriptRecord record) => Isolate.run(
  () =>
      utf8.encode(const JsonEncoder.withIndent('  ').convert(record.toJson())),
);

Future<List<TranscriptRecord>> _loadRecords(String path) =>
    Isolate.run(() async {
      final records = <TranscriptRecord>[];
      await for (final file in Directory(path).list()) {
        if (file is File &&
            RegExp(r'[/\\]session-\d+\.json$').hasMatch(file.path)) {
          records.add(
            TranscriptRecord.fromJson(
              jsonDecode(await file.readAsString()) as Map<String, dynamic>,
            ),
          );
        }
      }
      records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return records;
    });
