import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Diagnostic log in a folder the user can open. One file per day, older
/// files are removed after [retention]. Callers never pass keys or transcripts.
class AppLog {
  AppLog._();
  static final instance = AppLog._();
  static const retention = Duration(days: 14);
  static const maxFileBytes = 8 * 1024 * 1024;

  Directory? directory;
  IOSink? _sink;
  String? _file;
  int _written = 0;
  Future<void> _writes = Future.value();

  /// `ALTRANSCRIBE_LOG_DIR` overrides the location; Windows otherwise uses the
  /// user's Documents folder, which is visible without showing hidden folders.
  static Directory? defaultDirectory() {
    final override = Platform.environment['ALTRANSCRIBE_LOG_DIR'];
    if (override != null && override.isNotEmpty) return Directory(override);
    if (!Platform.isWindows) return null;
    final profile = Platform.environment['USERPROFILE'];
    if (profile == null || profile.isEmpty) return null;
    return Directory('$profile\\Documents\\Altranscribe\\logs');
  }

  Future<void> initialize(Directory target) async {
    try {
      await target.create(recursive: true);
      directory = target;
      await _prune();
    } catch (_) {
      directory = null;
    }
  }

  void info(String area, String message) => _write('I', area, message);
  void warn(String area, String message) => _write('W', area, message);
  void error(String area, Object error, [StackTrace? stack]) {
    final trace = stack == null
        ? ''
        : '\n${stack.toString().split('\n').take(8).join('\n')}';
    _write('E', area, '$error$trace');
  }

  /// The file currently being written, or null before the first line.
  File? get currentFile => _file == null ? null : File(_file!);

  Future<void> close() async {
    await _writes;
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _file = null;
  }

  void _write(String level, String area, String message) {
    if (directory == null) return;
    final now = DateTime.now();
    final line =
        '${now.toIso8601String()} [$level] $area: ${message.trim().replaceAll('\r', '')}';
    _writes = _writes.then((_) => _append(now, line)).catchError((_) {});
  }

  Future<void> _append(DateTime now, String line) async {
    final dir = directory;
    if (dir == null) return;
    final day = now.toIso8601String().substring(0, 10);
    var path = '${dir.path}${Platform.pathSeparator}altranscribe-$day.log';
    if (_sink != null && _file != null && _file!.startsWith(path)) {
      if (_written + line.length > maxFileBytes) {
        // Keep one bounded file per day; later lines continue in a numbered part.
        await _sink!.flush();
        await _sink!.close();
        _sink = null;
        var part = 2;
        while (await File('$path.$part').exists()) {
          if (await File('$path.$part').length() < maxFileBytes ~/ 2) break;
          part++;
        }
        path = '$path.$part';
      } else {
        path = _file!;
      }
    } else if (_sink != null) {
      await _sink!.flush();
      await _sink!.close();
      _sink = null;
    }
    if (_sink == null) {
      final file = File(path);
      _written = await file.exists() ? await file.length() : 0;
      _sink = file.openWrite(mode: FileMode.append, encoding: utf8);
      _file = path;
    }
    _sink!.writeln(line);
    _written += line.length + 1;
    await _sink!.flush();
  }

  Future<void> _prune() async {
    final dir = directory;
    if (dir == null) return;
    final cutoff = DateTime.now().subtract(retention);
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.contains('altranscribe-')) continue;
      try {
        if ((await entry.lastModified()).isBefore(cutoff)) await entry.delete();
      } catch (_) {
        // A file in use is skipped and pruned on a later start.
      }
    }
  }

  /// Newest log file, for sharing from a phone.
  Future<File?> latest() async {
    final dir = directory;
    if (dir == null) return null;
    await _writes;
    File? newest;
    DateTime? newestTime;
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.contains('altranscribe-')) continue;
      final time = await entry.lastModified();
      if (newestTime == null || time.isAfter(newestTime)) {
        newest = entry;
        newestTime = time;
      }
    }
    return newest;
  }
}
