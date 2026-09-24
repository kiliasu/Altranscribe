import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';

// Test doubles for audio capture, inference and translation.
class FakeAudio extends AudioService {
  final events = <Map<String, Object?>>[];
  final finalEvents = <Map<String, Object?>>[];
  Map<String, Object?>? options;
  bool paused = false;
  int stops = 0;
  String? failure;
  @override
  Future<List<Map<String, Object?>>> devices() async => [];
  @override
  Future<void> start(Map<String, Object?> options) async {
    this.options = options;
    for (final source in ['microphone', 'system']) {
      if (options[source] == true) {
        events.add({
          'type': failure == null ? 'ready' : 'error',
          'source': source,
          'message': failure,
        });
      }
    }
  }

  @override
  Future<List<Map<String, Object?>>> poll() async {
    final result = List<Map<String, Object?>>.of(events);
    events.clear();
    return result;
  }

  @override
  Future<void> pause(bool paused) async {
    this.paused = paused;
  }

  @override
  Future<List<Map<String, Object?>>> stop() async {
    stops++;
    final result = [...await poll(), ...finalEvents];
    finalEvents.clear();
    return result;
  }

  @override
  Future<void> ownProcess(int pid) async {}
}

class FakeEngine extends SpeechEngine {
  @override
  String backend = 'Test engine';
  Completer<void>? loading;
  Completer<String>? response;
  int starts = 0;
  int stops = 0;
  String? failure;
  final languages = <String>[];
  @override
  Future<void> start(
    String executable,
    String model,
    Directory directory, {
    ComputeMode compute = ComputeMode.automatic,
  }) async {
    starts++;
    await loading?.future;
    if (failure != null) throw StateError(failure!);
  }

  @override
  Future<String> transcribe(Uint8List wave, String language) async {
    languages.add(language);
    if (failure != null) throw StateError(failure!);
    return await response?.future ?? 'A real result would appear here.';
  }

  @override
  Future<void> stop() async {
    stops++;
    if (loading != null && !loading!.isCompleted) loading!.complete();
  }
}

class MemoryStore extends RecordStore {
  MemoryStore() : super(Directory('unused-test-data'));
  final values = <String, Map<String, Object?>>{};
  @override
  Future<void> initialize() async {}
  @override
  Future<Map<String, dynamic>> loadSettings() async => {};
  @override
  Future<void> saveSettings(Map<String, Object?> value) async {}
  @override
  Future<void> save(TranscriptRecord record) async {
    values[record.id] = record.toJson();
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }

  @override
  Future<List<TranscriptRecord>> loadRecords() async =>
      values.values.map(TranscriptRecord.fromJson).toList();
}

RealtimeController fakeController({ModelCatalog? catalog}) =>
    RealtimeController(
      audio: FakeAudio(),
      engine: FakeEngine(),
      store: MemoryStore(),
      translator: FakeTranslator(),
      recordSummarizer: FakeTranslator(),
      catalog: catalog ?? FakeModelCatalog(),
    )..initialized = true;

class FakeModelCatalog extends ModelCatalog {
  FakeModelCatalog() : super(Directory('build/test-models'));
  @override
  Future<Map<String, ModelAvailability>> scan() async => {
    for (final model in ModelCatalog.models)
      model.id: model.id.startsWith('large')
          ? ModelAvailability.available
          : ModelAvailability.missing,
  };
}

class FakeTranslator extends TranslationService {
  @override
  String backend = 'Test translator';
  Completer<String>? response;
  String? failure;
  final calls = <(String, String, String)>[];
  final contexts = <List<TranslationContext>>[];
  String? prepareFailure;
  String? summaryFailure;
  Completer<RecordSummary>? summaryResponse;
  final summaryCalls = <(List<String>, String)>[];
  LlmProvider? provider;
  int prepared = 0;
  @override
  Future<List<String>> models(
    String address, {
    LlmProvider provider = LlmProvider.ollama,
  }) async => ['test-model'];
  @override
  Future<void> prepare(
    String address,
    String model, {
    LlmProvider provider = LlmProvider.ollama,
  }) async {
    prepared++;
    this.provider = provider;
    if (prepareFailure != null) throw StateError(prepareFailure!);
  }

  @override
  Future<String> translate(
    String text,
    String source,
    String target, {
    List<TranslationContext> context = const [],
  }) async {
    calls.add((text, source, target));
    contexts.add(context);
    if (failure != null) throw StateError(failure!);
    return await response?.future ?? '测试译文';
  }

  @override
  Future<RecordSummary> summarize(List<String> texts, String language) async {
    summaryCalls.add((texts, language));
    if (summaryFailure != null) throw StateError(summaryFailure!);
    return await summaryResponse?.future ?? const RecordSummary('测试标题', '测试摘要');
  }

  @override
  Future<CleanupResult> cleanUp(
    List<String> texts,
    CleanupOptions options,
  ) async => CleanupResult(texts, [for (final _ in texts) <CleanupEdit>[]]);

  @override
  void stop() {}
}

Map<String, Object?> chunk(String source, int startMs) => {
  'type': 'chunk',
  'source': source,
  'startMs': startMs,
  'endMs': startMs + 2000,
  'pcm': Uint8List(64000),
};
