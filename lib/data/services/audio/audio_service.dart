import 'dart:typed_data';

import 'package:flutter/services.dart';

abstract class AudioService {
  Future<List<Map<String, Object?>>> devices();
  Future<void> start(Map<String, Object?> options);
  Future<List<Map<String, Object?>>> poll();
  Future<void> pause(bool paused);
  Future<List<Map<String, Object?>>> stop();
  Future<void> ownProcess(int pid);
}

class PlatformAudioService implements AudioService {
  static const _channel = MethodChannel('altranscribe/audio');

  Future<List<Map<String, Object?>>> _list(String method) async =>
      (await _channel.invokeListMethod<Object?>(method) ?? [])
          .map((value) => Map<String, Object?>.from(value! as Map))
          .toList();

  @override
  Future<List<Map<String, Object?>>> devices() => _list('devices');
  @override
  Future<void> start(Map<String, Object?> options) =>
      _channel.invokeMethod<void>('start', options);
  @override
  Future<List<Map<String, Object?>>> poll() => _list('poll');
  @override
  Future<void> pause(bool paused) =>
      _channel.invokeMethod<void>('pause', {'paused': paused});
  @override
  Future<List<Map<String, Object?>>> stop() => _list('stop');
  @override
  Future<void> ownProcess(int pid) =>
      _channel.invokeMethod<void>('ownProcess', {'pid': pid});
}

// Name used by the Windows integration tests.
class WindowsAudioService extends PlatformAudioService {}

/// The native bridge supplies 16 kHz, mono, signed little-endian PCM16.
Uint8List pcmToWave(Uint8List pcm) {
  final result = Uint8List(44 + pcm.length);
  final data = ByteData.sublistView(result);
  result.setRange(0, 4, 'RIFF'.codeUnits);
  data.setUint32(4, pcm.length + 36, Endian.little);
  result.setRange(8, 16, 'WAVEfmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  result.setRange(36, 40, 'data'.codeUnits);
  data.setUint32(40, pcm.length, Endian.little);
  result.setRange(44, result.length, pcm);
  return result;
}
