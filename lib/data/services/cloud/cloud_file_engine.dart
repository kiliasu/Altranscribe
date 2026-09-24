import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/transcription/chinese_script.dart';
import 'package:altranscribe/data/services/cloud/cloud_api.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';

/// Full, non-streaming requests. File decoding groups up to ten minutes of
/// lossless PCM (19.2 MB), below OpenAI's 25 MB upload and Gemini's one-hour limit.
class CloudFileEngine implements SpeechEngine {
  CloudFileEngine(this.api, this.provider);
  final CloudApi api;
  final CloudProvider provider;
  bool _cancelled = false;
  String? cleanupWarning;
  @override
  String get backend => '${provider.label} · $model';
  String get model => provider == CloudProvider.openAI
      ? 'gpt-transcribe'
      : 'gemini-3.5-transcribe';

  @override
  Future<void> start(
    String executable,
    String model,
    Directory directory, {
    ComputeMode compute = ComputeMode.automatic,
  }) async {
    _cancelled = false;
    cleanupWarning = null;
    await api.prepare(provider);
  }

  @override
  Future<String> transcribe(Uint8List wave, String language) async {
    if (_cancelled) throw StateError('cloudCancelled');
    if (wave.length > 24 * 1000 * 1000) throw StateError('cloudFileTooLarge');
    if (provider == CloudProvider.openAI) {
      final boundary = 'altranscribe-${DateTime.now().microsecondsSinceEpoch}';
      final body = BytesBuilder(copy: false);
      void field(String name, String value) => body.add(
        utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; name="$name"\r\n\r\n$value\r\n',
        ),
      );
      field('model', model);
      field('response_format', 'json');
      if (language != 'auto') field('languages[]', language);
      body.add(
        utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; '
          'name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n',
        ),
      );
      body.add(wave);
      body.add(utf8.encode('\r\n--$boundary--\r\n'));
      final result = await api.json(
        'POST',
        '/v1/audio/transcriptions',
        bytes: body.takeBytes(),
        headers: {'Content-Type': 'multipart/form-data; boundary=$boundary'},
      );
      if (result['text'] is! String) throw StateError('cloudInvalidResponse');
      return normalizeChineseScript(
        (result['text'] as String).trim(),
        language,
      );
    }
    String? name;
    try {
      final start = await api.send(
        'POST',
        '/upload/v1beta/files',
        body: {
          'file': {'display_name': 'Altranscribe audio'},
        },
        headers: {
          'X-Goog-Upload-Protocol': 'resumable',
          'X-Goog-Upload-Command': 'start',
          'X-Goog-Upload-Header-Content-Length': '${wave.length}',
          'X-Goog-Upload-Header-Content-Type': 'audio/wav',
        },
      );
      final upload = start.headers.value('x-goog-upload-url');
      await start.drain<void>();
      if (upload == null) throw StateError('cloudInvalidResponse');
      final result = await api.json(
        'POST',
        upload,
        bytes: wave,
        headers: {
          'Content-Type': 'audio/wav',
          'X-Goog-Upload-Offset': '0',
          'X-Goog-Upload-Command': 'upload, finalize',
        },
      );
      var file = result['file'] as Map;
      name = file['name'] as String;
      if (!RegExp(r'^files/[a-zA-Z0-9_-]+$').hasMatch(name)) {
        name = null;
        throw StateError('cloudInvalidResponse');
      }
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (file['state'] == 'PROCESSING' && !_cancelled) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('cloudFileProcessing');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        file = await api.json('GET', '/v1beta/$name');
      }
      if (_cancelled) throw StateError('cloudCancelled');
      if (file['state'] != 'ACTIVE') throw StateError('cloudFileProcessing');
      final response = await api.json(
        'POST',
        '/v1beta/interactions',
        body: {
          'model': model,
          'input': [
            {'type': 'audio', 'uri': file['uri'], 'mime_type': 'audio/wav'},
          ],
          'generation_config': {
            'transcription_config': {
              'language_codes': [
                if (language != 'auto') geminiLanguage(language),
              ],
            },
          },
        },
      );
      return normalizeChineseScript(interactionText(response), language);
    } finally {
      if (name != null) {
        // A cancelled inference client is closed. Cleanup uses a fresh client.
        final cleanup = CloudApi(
          api.credentials,
          clientFactory: api.clientFactory,
        );
        try {
          await cleanup.prepare(provider);
          final response = await cleanup.send(
            'DELETE',
            '/v1beta/$name',
            timeout: const Duration(seconds: 10),
          );
          await response.drain<void>();
        } catch (_) {
          cleanupWarning = 'cloudFileCleanupFailed';
        } finally {
          cleanup.close();
        }
      }
    }
  }

  @override
  Future<void> stop() async {
    _cancelled = true;
    api.close();
  }
}
