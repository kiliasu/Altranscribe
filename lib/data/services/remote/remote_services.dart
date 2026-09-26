import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';

class RemoteSpeechEngine implements SpeechEngine {
  RemoteSpeechEngine(RemoteConnection connection)
    : client = RemoteClient(connection);
  final RemoteClient client;
  @override
  String backend = 'Whisper Remote';
  @override
  Future<void> start(
    String executable,
    String model,
    Directory directory, {
    ComputeMode compute = ComputeMode.automatic,
  }) async {
    final info = await client.connect();
    backend = 'Whisper Remote · ${info['name']} · ${info['backend']}';
  }

  @override
  Future<String> transcribe(Uint8List wave, String language) async =>
      (await client.request(
            'transcribe',
            wave: wave,
            language: language,
            timeout: const Duration(minutes: 3),
          ))['text']
          as String;
  @override
  Future<void> stop() async => client.close();
}

class RemoteTranslationService implements TranslationService {
  RemoteTranslationService(RemoteConnection connection)
    : client = RemoteClient(connection);
  final RemoteClient client;

  /// One of the models the host lists; empty means the host's default.
  String model = '';
  @override
  String backend = 'LLM · Remote';
  @override
  Future<List<String>> models(
    String address, {
    LlmProvider provider = LlmProvider.ollama,
  }) async {
    final info = await client.connect();
    return info['llmModel'] is String ? [info['llmModel'] as String] : [];
  }

  @override
  Future<void> prepare(
    String address,
    String model, {
    LlmProvider provider = LlmProvider.ollama,
  }) async {
    final info = await client.connect();
    if (info['llmModel'] == null) {
      stop();
      throw const FormatException('remoteLlmUnavailable');
    }
    final listed =
        (info['llmModels'] as List?)?.cast<String>() ??
        [info['llmModel'] as String];
    if (model.isNotEmpty && !listed.contains(model)) {
      stop();
      throw const FormatException('remoteLlmModelMissing');
    }
    this.model = model;
    backend =
        'Remote · ${info['llmProvider']} · ${model.isEmpty ? info['llmModel'] : model}';
  }

  @override
  Future<String> translate(
    String text,
    String source,
    String target, {
    List<TranslationContext> context = const [],
  }) async =>
      (await client.request(
            'translate',
            json: {
              'text': text,
              'source': source,
              'target': target,
              'context': TranslationContextPolicy.bound(context)
                  .map((item) => item.toJson())
                  .toList(),
              if (model.isNotEmpty) 'model': model,
            },
          ))['text']
          as String;
  @override
  Future<RecordSummary> summarize(List<String> texts, String language) async {
    final result = await client.request(
      'summarize',
      json: {
        'texts': texts,
        'language': language,
        if (model.isNotEmpty) 'model': model,
      },
    );
    return RecordSummary(
      result['title'] as String,
      result['summary'] as String,
    );
  }

  @override
  Future<CleanupResult> cleanUp(
    List<String> texts,
    CleanupOptions options,
  ) async {
    final result = await client.request(
      'cleanup',
      json: {
        'texts': texts,
        'options': options.toJson(),
        if (model.isNotEmpty) 'model': model,
      },
    );
    // The client repeats the same evidence checks; it never blindly replaces
    // the source document with a host-provided edited document.
    return CleanupResult.validate(texts, options, result['edits'] as List);
  }

  @override
  void stop() => client.close();
}
