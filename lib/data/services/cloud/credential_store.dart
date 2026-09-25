import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:altranscribe/data/services/cloud/cloud_provider.dart';

abstract class CredentialStore {
  Future<String> read(CloudProvider provider) => readNamed(provider.name);
  Future<void> write(CloudProvider provider, String key) =>
      writeNamed(provider.name, key);

  /// Secrets that belong to no fixed provider, such as the OpenAI-compatible
  /// key or a host token, are stored under a plain name.
  Future<String> readNamed(String name);
  Future<void> writeNamed(String name, String key);
}

/// Windows uses DPAPI; Android uses an app-bound Keystore AES-GCM key.
/// No keys are included in settings, transcript records, or diagnostic output.
class WindowsCredentialStore extends CredentialStore {
  WindowsCredentialStore(this.directory);
  final Directory directory;
  static const channel = MethodChannel('altranscribe/audio');
  File _file(String name) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(name)) {
      throw ArgumentError('Invalid credential name');
    }
    return File('${directory.path}/$name.credential');
  }

  @override
  Future<String> readNamed(String name) async {
    final file = _file(name);
    if (!await file.exists()) return '';
    final bytes = await channel.invokeMethod<Uint8List>('unprotectSecret', {
      'bytes': await file.readAsBytes(),
    });
    if (bytes == null) throw StateError('cloudKeyReadFailed');
    return utf8.decode(bytes);
  }

  @override
  Future<void> writeNamed(String name, String key) async {
    final file = _file(name);
    if (key.trim().isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    final bytes = await channel.invokeMethod<Uint8List>('protectSecret', {
      'bytes': Uint8List.fromList(utf8.encode(key.trim())),
    });
    if (bytes == null) throw StateError('cloudKeySaveFailed');
    await directory.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }
}
