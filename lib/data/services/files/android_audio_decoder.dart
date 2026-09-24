import 'package:flutter/services.dart';

import 'package:altranscribe/data/services/files/audio_file_decoder.dart';

/// Pulls bounded decoded PCM windows. Android retains only the current decoder
/// window, and the document stays with its original content provider.
class AndroidAudioDecoder implements AudioFileDecoder {
  static const channel = MethodChannel('altranscribe/files');
  int _generation = 0;

  @override
  Stream<FileAudioChunk> decode(String path, {int chunkSeconds = 20}) async* {
    final generation = _generation;
    try {
      await channel.invokeMethod<void>('open', {
        'path': path,
        'chunkSeconds': chunkSeconds,
      });
      while (generation == _generation) {
        final result = await channel.invokeMapMethod<String, Object?>('next');
        if (generation != _generation || result == null) break;
        yield FileAudioChunk(
          result['pcm'] as Uint8List,
          result['startMs'] as int,
          result['endMs'] as int,
        );
      }
    } finally {
      await channel.invokeMethod<void>('close');
    }
  }

  @override
  Future<void> cancel() async {
    _generation++;
    await channel.invokeMethod<void>('cancel');
  }
}
