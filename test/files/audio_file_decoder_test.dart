import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

/// FFmpeg on PATH, as the Windows app finds it by default.
final bool _ffmpeg = () {
  try {
    return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

void main() {
  test('a soundtrack that starts after the video keeps its time', () async {
    final folder = await Directory.systemTemp.createTemp('decoder');
    addTearDown(() => folder.delete(recursive: true));
    final video = '${folder.path}/late.mp4';
    // The picture starts at 0 s, the sound 1.936 s in.
    final made = await Process.run('ffmpeg', [
      ...['-hide_banner', '-loglevel', 'error', '-y'],
      ...['-f', 'lavfi', '-i', 'testsrc=duration=4:size=64x48:rate=10'],
      ...['-itsoffset', '1.936'],
      ...['-f', 'lavfi', '-i', 'sine=frequency=440:duration=2'],
      ...['-map', '0:v', '-map', '1:a', '-c:v', 'mpeg4', '-c:a', 'aac'],
      video,
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    final pcm = BytesBuilder();
    var end = 0;
    await for (final chunk in FfmpegAudioDecoder().decode(video)) {
      expect(chunk.startMs, end);
      pcm.add(chunk.pcm);
      end = chunk.endMs;
    }
    final samples = ByteData.sublistView(pcm.takeBytes());
    var first = 0;
    while (samples.getInt16(first * 2, Endian.little).abs() < 300) {
      first++;
    }
    expect(first / 16, closeTo(1936, 40));
    expect(end, closeTo(3936, 100));
  }, skip: _ffmpeg ? false : 'FFmpeg is not installed');
}
