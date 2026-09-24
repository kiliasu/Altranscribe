import 'dart:convert';
import 'dart:io';

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
    final override = Platform.environment['ALTRANSCRIBE_DATA_DIR'];
    final local = Platform.environment['LOCALAPPDATA'];
    if (override == null && local == null) {
      throw UnsupportedError('Windows is required');
    }
    return RecordStore(Directory(override ?? '$local/Altranscribe'));
  }
  Future<void> initialize() => directory.create(recursive: true);
  Future<Map<String, dynamic>> loadSettings() async {
    final file = File('${directory.path}/settings.json');
    return await file.exists()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
  }

  Future<void> saveSettings(Map<String, Object?> value) =>
      _write('settings.json', value);
  Future<void> save(TranscriptRecord record) =>
      _write('${record.id}.json', record.toJson());
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

  Future<void> _write(String name, Object value) {
    final snapshot = const JsonEncoder.withIndent('  ').convert(value);
    // ASR and translation finish independently. Serialize snapshots so their
    // temporary files cannot collide or overwrite newer results out of order.
    final write = _writes
        .catchError((Object _) {})
        .then((_) => _writeSnapshot(name, snapshot));
    _writes = write;
    return write;
  }

  Future<void> _writeSnapshot(String name, String snapshot) async {
    final file = File('${directory.path}/$name.tmp');
    await file.writeAsString(snapshot, flush: true);
    // A completed snapshot replaces the preceding one; readers never see partial JSON.
    await file.rename('${directory.path}/$name');
  }

  Future<List<TranscriptRecord>> loadRecords() async {
    final records = <TranscriptRecord>[];
    await for (final file in directory.list()) {
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
  }
}
