import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/files/media_paths.dart';

const audioFileExtensions = [
  'wav',
  'mp3',
  'm4a',
  'flac',
  'ogg',
  'opus',
  'aac',
  'wma',
  'mp4',
  'mkv',
  'webm',
  'mov',
];

bool isSupportedAudioFile(String path) => audioFileExtensions.contains(
  mediaFileName(path).split('.').last.toLowerCase(),
);

class FileAudioChunk {
  const FileAudioChunk(this.pcm, this.startMs, this.endMs);
  final Uint8List pcm;
  final int startMs;
  final int endMs;
}

abstract class AudioFileDecoder {
  Stream<FileAudioChunk> decode(String path, {int chunkSeconds = 20});
  Future<void> cancel();
}

/// Streams local media through FFmpeg; pipe backpressure bounds decoded audio
/// memory even when the model is much slower than decoding.
class FfmpegAudioDecoder implements AudioFileDecoder {
  FfmpegAudioDecoder({this.executable = 'ffmpeg'});
  final String executable;
  Process? _process;
  int _generation = 0;

  @override
  Stream<FileAudioChunk> decode(String path, {int chunkSeconds = 20}) async* {
    final generation = _generation;
    if (!isSupportedAudioFile(path)) {
      throw const FormatException('unsupportedFile');
    }
    if (!await File(path).exists()) throw const FormatException('fileMissing');
    if (generation != _generation) return;
    final Process process;
    try {
      process = await Process.start(executable, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-i',
        File(path).absolute.path,
        '-map',
        '0:a:0',
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-f',
        's16le',
        'pipe:1',
      ]);
    } on ProcessException {
      throw const FormatException('ffmpegMissing');
    }
    _process = process;
    var diagnostics = '';
    final errors = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) {
          diagnostics += text;
          if (diagnostics.length > 4000) {
            diagnostics = diagnostics.substring(diagnostics.length - 4000);
          }
        });
    final buffer = BytesBuilder(copy: false);
    var consumed = 0;
    var decoded = false;
    final chunkBytes = chunkSeconds * 32000;
    try {
      if (generation != _generation) return;
      await for (final bytes in process.stdout) {
        if (generation != _generation) return;
        buffer.add(bytes);
        while (buffer.length >= chunkBytes) {
          final available = buffer.takeBytes();
          // Prefer the quietest 100 ms boundary near the end of the window.
          var end = chunkBytes;
          var quietest = 0.003 * 32768;
          final samples = ByteData.sublistView(available);
          for (
            var offset = chunkBytes - 2 * 32000;
            offset < chunkBytes;
            offset += 3200
          ) {
            var level = 0.0;
            for (var i = offset; i < offset + 3200; i += 2) {
              level += samples.getInt16(i, Endian.little).abs();
            }
            level /= 1600;
            if (level <= quietest) {
              quietest = level;
              end = offset + 1600;
            }
          }
          buffer.add(Uint8List.sublistView(available, end));
          decoded = true;
          yield FileAudioChunk(
            Uint8List.sublistView(available, 0, end),
            consumed ~/ 32,
            (consumed + end) ~/ 32,
          );
          consumed += end;
          if (generation != _generation) return;
        }
      }
      final code = await process.exitCode;
      if (generation != _generation) return;
      if (code != 0) throw FormatException('fileDecodeFailed: $diagnostics');
      if (buffer.length >= 2) {
        final remaining = buffer.takeBytes();
        decoded = true;
        yield FileAudioChunk(
          remaining,
          consumed ~/ 32,
          (consumed + remaining.length) ~/ 32,
        );
      }
      if (!decoded) throw const FormatException('fileNoAudio');
    } finally {
      process.kill();
      await process.exitCode;
      await errors.cancel();
      if (identical(_process, process)) _process = null;
    }
  }

  @override
  Future<void> cancel() async {
    _generation++;
    final process = _process;
    process?.kill();
    await process?.exitCode;
  }
}
