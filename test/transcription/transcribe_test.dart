import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/app/l10n/localized_issue.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/pause_cutter.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/data/services/transcription/transcribe_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/translation/translation_terms.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// What happened, in order, across the speech engine and the text model.
final events = <String>[];

class OrderedEngine extends FakeEngine implements TimedSpeechEngine {
  @override
  Future<void> start(
    String executable,
    String model,
    Directory directory, {
    ComputeMode compute = ComputeMode.automatic,
  }) async {
    events.add('start $executable');
    await super.start(executable, model, directory);
  }

  @override
  Future<String> transcribe(Uint8List wave, String language) async {
    events.add('transcribe');
    return 'Live sentence.';
  }

  @override
  Future<TimedTranscript> transcribeTimed(
    Uint8List wave,
    String language,
  ) async {
    events.add('transcribe');
    return const TimedTranscript('One sentence here.', [
      TimedWord('one', 100, 300),
      TimedWord('sentence', 350, 800),
      TimedWord('here', 850, 1000),
    ]);
  }

  @override
  Future<void> stop() async {
    events.add('stop');
    await super.stop();
  }
}

class OrderedTranslator extends FakeTranslator {
  @override
  Future<void> prepare(
    String address,
    String model, {
    LlmProvider provider = LlmProvider.ollama,
  }) async {
    events.add('prepare ${provider.name} $model');
    await super.prepare(address, model, provider: provider);
  }

  @override
  Future<void> release(
    String address,
    String model, {
    LlmProvider provider = LlmProvider.ollama,
  }) async => events.add('release $model');

  @override
  Future<String> translate(
    String text,
    String source,
    String target, {
    List<TranslationContext> context = const [],
    String rules = defaultTranslationRules,
    List<TranslationTerm> terms = const [],
  }) async {
    events.add('translate');
    return super.translate(text, source, target);
  }
}

class SizedTranslator extends OrderedTranslator {
  int? size;
  @override
  Future<int?> modelBytes(
    String address,
    String model, {
    LlmProvider provider = LlmProvider.ollama,
  }) async => size;
}

class TwoFiles extends AudioFileDecoder {
  @override
  Stream<FileAudioChunk> decode(
    String path, {
    int chunkSeconds = 20,
    PauseCutter? cutter,
  }) async* {
    yield FileAudioChunk(Uint8List(32000), 0, 1000);
  }

  @override
  Future<void> cancel() async {}
}

RealtimeController transcribeController(OrderedTranslator translator) =>
    RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        transcribe: OrderedEngine(),
        store: MemoryStore(),
        translator: translator,
        recordSummarizer: FakeTranslator(),
        catalog: FakeModelCatalog(),
        fileDecoder: TwoFiles(),
      )
      ..initialized = true
      ..generateSummary = false
      ..translationModel = 'test-model'
      ..transcribeExecutable = 'nemo-speech.exe'
      ..speechProvider = SpeechProvider.transcribe
      ..gpuTotalMemory = (() async => null);

Directory modelFolder(int files) {
  final folder = Directory.systemTemp.createTempSync('transcribe-model');
  for (var i = 0; i < files; i++) {
    File('${folder.path}/part-$i.gguf').writeAsBytesSync(Uint8List(1000));
  }
  return folder;
}

void main() {
  setUp(events.clear);

  test('the server\'s words become milliseconds beside the text', () {
    final transcript = TranscribeService.decodeTranscript({
      'text': ' Hello John, how are you? ',
      'words': [
        {'word': 'Hello', 'start': 0.555, 'end': 0.713},
        {'word': 'John', 'start': 0.8, 'end': 1.1},
        {'start': 2.0},
      ],
    }, 'en');
    expect(transcript.text, 'Hello John, how are you?');
    expect(
      transcript.words.map((word) => [word.text, word.startMs, word.endMs]),
      [
        ['Hello', 555, 713],
        ['John', 800, 1100],
      ],
    );
    expect(
      TranscribeService.decodeTranscript({'text': 'Hi.'}, 'en').words,
      isEmpty,
    );
    expect(
      () => TranscribeService.decodeTranscript({'words': []}, 'en'),
      throwsFormatException,
    );
  });

  test(
    'the server does not start without its program, model or memory',
    () async {
      final service = TranscribeService(
        FakeAudio(),
        freeGpuMemory: () async => 1000000000,
      );
      final complete = modelFolder(2);
      final missing = modelFolder(1);
      final program = File('${complete.path}/nemo-speech.exe')
        ..writeAsStringSync('');
      addTearDown(() {
        complete.deleteSync(recursive: true);
        missing.deleteSync(recursive: true);
      });
      Future<String> failure(String executable, String model) async {
        try {
          await service.start(executable, model, complete);
        } on FormatException catch (error) {
          return error.message;
        }
        return '';
      }

      expect(
        await failure(
          '${complete.path}/none.exe',
          '${complete.path}/part-0.gguf',
        ),
        'transcribeProgramMissing',
      );
      expect(
        await failure(program.path, '${missing.path}/part-0.gguf'),
        'transcribeModelMissing',
      );
      // One gigabyte free is less than the files plus their working memory.
      final memory = await failure(
        program.path,
        '${complete.path}/part-0.gguf',
      );
      expect(memory, 'transcribeMemory: 1.0 8');
      expect(
        localizedIssue('FormatException: $memory', false),
        contains('需要约 8 GB 空闲显存，现在只有 1.0 GB'),
      );
    },
  );

  test('files are transcribed first, then the speech model leaves before the text model loads', () async {
    final translator = OrderedTranslator();
    final controller = transcribeController(translator);
    addTearDown(controller.dispose);
    await controller.startFiles(
      paths: ['one.wav', 'two.wav'],
      language: 'en',
      targetLanguage: 'zh',
      summaryLanguage: 'zh',
      options: const CleanupOptions(),
    );
    expect(events, [
      // A model prepared earlier would hold the GPU memory Transcribe needs.
      'release test-model',
      'start nemo-speech.exe',
      'transcribe',
      'transcribe',
      'stop',
      'prepare ollama test-model',
      'translate',
      'translate',
      // Stopping again at the end changes nothing.
      'stop',
    ]);
    final records = await controller.store.loadRecords();
    expect(records, hasLength(2));
    for (final record in records) {
      expect(record.status, 'completed');
      expect(record.speechProvider, 'transcribe');
      expect(record.lines.single.startMs, 100);
      expect(record.lines.single.translation, '测试译文');
    }
    expect(controller.error, isNull);
  });

  test('a text model that cannot load keeps the transcripts', () async {
    final translator = OrderedTranslator()..prepareFailure = 'llmUnavailable';
    final controller = transcribeController(translator);
    addTearDown(controller.dispose);
    await controller.startFiles(
      paths: ['one.wav'],
      language: 'en',
      targetLanguage: 'zh',
      summaryLanguage: 'zh',
      options: const CleanupOptions(),
    );
    final record = (await controller.store.loadRecords()).single;
    expect(record.status, 'completed');
    expect(record.lines.single.text, 'One sentence here.');
    expect(controller.error, contains('llmUnavailable'));
  });

  Future<RealtimeController> liveSession(
    void Function(RealtimeController) configure,
  ) async {
    final controller = transcribeController(OrderedTranslator());
    configure(controller);
    await controller.start(
      microphone: true,
      system: false,
      language: 'en',
      targetLanguage: 'zh',
    );
    (controller.audio as FakeAudio).events.add(chunk('microphone', 0));
    for (var i = 0; i < 200 && controller.record!.lines.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return controller;
  }

  test(
    'a cloud model as the main one translates live sessions as they go',
    () async {
      final controller = await liveSession(
        (controller) => controller
          ..llmProvider = LlmProvider.gemini
          ..translationModel = 'cloud-model',
      );
      addTearDown(controller.dispose);
      await controller.stop();
      // Nothing local to unload, and the cloud model is ready before speech.
      expect(events.take(2), [
        'prepare gemini cloud-model',
        'start nemo-speech.exe',
      ]);
      final record = controller.records.single;
      expect(record.llmProvider, 'gemini');
      expect(record.translationModel, 'cloud-model');
      expect(record.lines.single.translation, '测试译文');
    },
  );

  test(
    'with the local model, a live session is translated once it stops',
    () async {
      final controller = await liveSession((_) {});
      addTearDown(controller.dispose);
      expect(controller.warning, 'llmTranslateAfterStop');
      expect(controller.record!.lines.single.translation, isNull);
      await controller.stop();
      expect(events, [
        'release test-model',
        'start nemo-speech.exe',
        'transcribe',
        'stop',
        'prepare ollama test-model',
        'translate',
      ]);
      final record = controller.records.single;
      expect(record.status, 'completed');
      expect(record.lines.single.translation, '测试译文');
    },
  );

  test(
    'a local model the user keeps for live sessions loads after Transcribe',
    () async {
      final controller = await liveSession(
        (controller) => controller.liveLocalLlm = true,
      );
      addTearDown(controller.dispose);
      expect(controller.warning, 'llmSharesGpu');
      await controller.stop();
      expect(events.take(3), [
        'release test-model',
        'start nemo-speech.exe',
        'prepare ollama test-model',
      ]);
      expect(controller.records.single.lines.single.translation, '测试译文');
    },
  );

  test(
    'the estimate of a local model beside Transcribe says when it fits',
    () async {
      final translator = SizedTranslator();
      final controller = transcribeController(translator)
        ..liveLocalLlm = true
        ..gpuTotalMemory = (() async => 32 << 30);
      addTearDown(controller.dispose);
      translator.size = 20000000000;
      await controller.estimateSharedGpu();
      expect(controller.sharedGpuFits, isFalse);
      expect(controller.sharedGpuWarning, 'gpuMemoryShort: 42 32');
      translator.size = 4000000000;
      await controller.estimateSharedGpu();
      expect(controller.sharedGpuFits, isTrue);
    },
  );

  test('the Transcribe model is a folder of its two files', () {
    final catalog = ModelCatalog(Directory('build/test-models'));
    final model = ModelCatalog.transcribeModels.single;
    expect(model.files, hasLength(2));
    expect(
      catalog.decoderPath(model),
      endsWith('/nemotron-transcribe-nvfp4/${model.files.first.name}'),
    );
    expect(model.bytes, 21349066496);
    expect(SpeechProvider.transcribe.isCloud, isFalse);
  });
}
