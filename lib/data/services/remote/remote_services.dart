import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_terms.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';

class RemoteSpeechEngine implements SpeechEngine {
  RemoteSpeechEngine(RemoteConnection connection)
    : client = RemoteClient(connection);
  final RemoteClient client;
  @override
  String backend = 'Whisper · Remote';
  @override
  Future<void> start(
    String executable,
    String model,
    Directory directory, {
    ComputeMode compute = ComputeMode.automatic,
  }) async {
    final info = await client.connect();
    backend = 'Whisper · Remote · ${info['name']} · ${info['backend']}';
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
  bool _textPreparation = false;
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
    _textPreparation = info['textPreparation'] == true;
    backend =
        'Remote · ${info['llmProvider']} · ${model.isEmpty ? info['llmModel'] : model}';
  }

  @override
  Future<String> translate(
    String text,
    String source,
    String target, {
    List<TranslationContext> context = const [],
    String rules = defaultTranslationRules,
    List<TranslationTerm> terms = const [],
  }) async {
    return (await client.request(
          'translate',
          json: {
            'text': text,
            'source': source,
            'target': target,
            if (rules.trim().isNotEmpty) 'rules': rules,
            if (terms.isNotEmpty)
              'terms': terms.map((term) => term.toJson()).toList(),
            'context': TranslationContextPolicy.bound(context)
                .map((item) => item.toJson())
                .toList(),
            if (model.isNotEmpty) 'model': model,
          },
        ))['text']
        as String;
  }

  @override
  Future<TextPreparation> prepareText(
    List<String> texts,
    String source,
    String? target, {
    List<TranslationTerm> terms = const [],
    bool mergeSentences = false,
    String rules = defaultTranslationRules,
  }) async {
    // A host from before file preparation translates without it.
    if (!_textPreparation) return TextPreparation(terms: terms);
    final result = await client.request(
      'prepare-text',
      json: {
        'texts': texts,
        'source': source,
        'target': target,
        'terms': terms.map((term) => term.toJson()).toList(),
        'mergeSentences': mergeSentences,
        'rules': rules,
        if (model.isNotEmpty) 'model': model,
      },
    );
    return TextPreparation(
      terms: TranslationTerm.accept(
        terms,
        result['terms'] as List,
        texts.join('\n'),
      ),
      joins: (result['joins'] as List)
          .whereType<int>()
          .where((index) => index > 0 && index < texts.length)
          .toList(),
    );
  }

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
    CleanupOptions options, {
    String language = 'auto',
  }) async {
    final result = await client.request(
      'cleanup',
      json: {
        'texts': texts,
        'options': options.toJson(),
        'language': language,
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
