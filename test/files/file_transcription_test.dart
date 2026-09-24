import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

Map<String, String> edit(
  String from,
  String to, {
  String category = 'correction',
  String confidence = 'high',
}) => {'category': category, 'from': from, 'to': to, 'confidence': confidence};

class FileDecoderFake extends AudioFileDecoder {
  final paths = <String>[];
  bool cancelled = false;
  @override
  Stream<FileAudioChunk> decode(String path, {int chunkSeconds = 20}) async* {
    paths.add(path);
    if (path == 'bad.mp3') throw const FormatException('fileNoAudio');
    yield FileAudioChunk(Uint8List(64000), 0, 2000);
    if (!cancelled) yield FileAudioChunk(Uint8List(64000), 2000, 4000);
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

class FileTranslatorFake extends FakeTranslator {
  bool cleanupFailure = false;
  final cleanupCalls = <List<String>>[];
  @override
  Future<CleanupResult> cleanUp(
    List<String> texts,
    CleanupOptions options,
  ) async {
    cleanupCalls.add(texts);
    if (cleanupFailure) throw const FormatException('incompleteCleanup');
    return CleanupResult.validate(texts, options, [
      edit('A', 'The'),
      edit('测试', '试验'),
    ]);
  }
}

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 200 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue);
}

void main() {
  test('cleanup requires evidence, enabled category, exact boundaries and high confidence', () {
    const options = CleanupOptions(
      names: true,
      corrections: true,
      spellings: ['Alan', 'CUDA'],
    );
    final original = [
      'Alen met Alena. teh model uses Cuda. Receive receive receive. 12 cats.',
    ];
    final result = CleanupResult.validate(original, options, [
      edit('Alen', 'Alan', category: 'name'),
      edit('Cuda', 'CUDA', category: 'term'), // Disabled category.
      edit('teh', 'the'), // No authoritative spelling or repeated evidence.
      edit('Receive', 'receive', confidence: 'medium'),
      edit('12', '13'),
    ]);
    expect(
      result.texts.single,
      'Alan met Alena. teh model uses Cuda. Receive receive receive. 12 cats.',
    );
    expect(result.edits.single.single.evidence, 'glossary');
    expect(original.single, startsWith('Alen'));
    final supported = CleanupResult.validate(
      ['recieve receive receive'],
      const CleanupOptions(corrections: true),
      [edit('recieve', 'receive')],
    );
    expect(supported.texts.single, 'receive receive receive');
    expect(supported.edits.single.single.evidence, 'repeated');
  });

  test('cleanup rejects conflicting and overlapping edits and never cascades replacements', () {
    final result = CleanupResult.validate(
      ['abc ab x a b'],
      const CleanupOptions(
        terms: true,
        spellings: ['def', 'ghi', 'y', 'z', 'b', 'c'],
      ),
      [
        edit('abc', 'def', category: 'term'),
        edit('abc', 'ghi', category: 'term'),
        edit('ab x', 'y', category: 'term'),
        edit('x', 'z', category: 'term'),
        edit('a', 'b', category: 'term'),
        edit('b', 'c', category: 'term'),
      ],
    );
    expect(result.texts.single, 'abc ab x a c');
  });

  test('offline batch saves raw and refined text, translates refined source, continues after bad file', () async {
    final decoder = FileDecoderFake();
    final translator = FileTranslatorFake();
    final store = MemoryStore();
    final controller =
        RealtimeController(
            audio: FakeAudio(),
            engine: FakeEngine(),
            store: store,
            translator: translator,
            fileDecoder: decoder,
          )
          ..initialized = true
          ..generateSummary = false;
    addTearDown(controller.dispose);
    await controller.startFiles(
      paths: ['one.wav', 'bad.mp3', 'two.mp4'],
      language: 'en',
      targetLanguage: 'zh',
      summaryLanguage: 'zh',
      options: const CleanupOptions(
        corrections: true,
        spellings: ['The', '试验'],
      ),
    );
    expect(controller.active, isFalse);
    expect(decoder.paths, ['one.wav', 'bad.mp3', 'two.mp4']);
    final records = await store.loadRecords();
    expect(records, hasLength(3));
    expect(
      records.where((r) => r.status == 'error').single.inputFile,
      'bad.mp3',
    );
    final line = records
        .firstWhere((r) => r.inputFile == 'one.wav')
        .lines
        .first;
    expect(
      line.text,
      'A real result would appear here.',
    ); // Raw remains untouched.
    expect(line.revisedText, 'The real result would appear here.');
    expect(translator.calls.first.$1, line.revisedText);
    expect(line.translation, '测试译文');
    expect(line.revisedTranslation, '试验译文');
    expect(line.translationEdits.single.from, '测试');
    expect(translator.cleanupCalls, hasLength(4));
    expect((controller.audio as FakeAudio).options, isNull);
    expect((controller.engine as FakeEngine).starts, 1);
    expect(
      records.firstWhere((r) => r.inputFile == 'one.wav').displayTitle,
      'one.wav',
    );
  });

  test(
    'cleanup failure keeps original, continues translation and exposes failure',
    () async {
      final translator = FileTranslatorFake()..cleanupFailure = true;
      final controller = RealtimeController(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: MemoryStore(),
        translator: translator,
        fileDecoder: FileDecoderFake(),
      )..initialized = true;
      addTearDown(controller.dispose);
      await controller.startFiles(
        paths: ['one.wav'],
        language: 'en',
        targetLanguage: 'zh',
        summaryLanguage: 'zh',
        options: const CleanupOptions(names: true),
      );
      expect(controller.record!.cleanupStatus, 'failed');
      expect(controller.record!.lines.first.text, isNotEmpty);
      expect(controller.record!.lines.first.translationStatus, 'done');
      expect(controller.record!.lines.first.revisedText, isNull);
    },
  );

  test('cancelling during translation keeps ASR and prevents remaining files from starting', () async {
    final translator = FileTranslatorFake()..response = Completer<String>();
    final decoder = FileDecoderFake();
    final controller = RealtimeController(
      audio: FakeAudio(),
      engine: FakeEngine(),
      store: MemoryStore(),
      translator: translator,
      fileDecoder: decoder,
    )..initialized = true;
    addTearDown(controller.dispose);
    final run = controller.startFiles(
      paths: ['one.wav', 'two.wav'],
      language: 'en',
      targetLanguage: 'zh',
      summaryLanguage: 'zh',
      options: const CleanupOptions(),
    );
    await until(() => translator.calls.isNotEmpty);
    final stopping = controller.stop();
    translator.response!.complete('late result');
    await stopping;
    await run;
    expect(controller.phase, SessionPhase.idle);
    expect(decoder.paths, ['one.wav']);
    expect(controller.record!.status, 'interrupted');
    expect(controller.record!.lines, hasLength(2));
    expect(
      controller.record!.lines.every(
        (line) => line.translationStatus == 'interrupted',
      ),
      true,
    );
    expect(controller.record!.lines.first.translation, isNull);
  });

  test('offline startup cancellation releases services without starting decoding or capture', () async {
    final engine = FakeEngine()..loading = Completer<void>();
    final decoder = FileDecoderFake();
    final controller = RealtimeController(
      audio: FakeAudio(),
      engine: engine,
      store: MemoryStore(),
      translator: FakeTranslator(),
      fileDecoder: decoder,
    )..initialized = true;
    addTearDown(controller.dispose);
    final running = controller.startFiles(
      paths: ['one.wav'],
      language: 'en',
      summaryLanguage: 'zh',
      options: const CleanupOptions(),
    );
    await until(() => engine.starts == 1);
    await controller.stop();
    await running;
    expect(decoder.paths, isEmpty);
    expect(controller.records, isEmpty);
    expect(controller.active, false);
  });

  test(
    'LLM cleanup processes full long document and validates returned edits',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      final formats = <dynamic>[];
      server.listen((request) async {
        Object result;
        if (request.uri.path == '/api/tags') {
          result = {
            'models': [
              {'name': 'test'},
            ],
          };
        } else if (request.uri.path == '/api/ps') {
          result = {'models': []};
        } else {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          requests.add((body['messages'] as List).last['content'] as String);
          formats.add(body['format']);
          result = {
            'done': true,
            'message': {
              'content': jsonEncode({
                'edits': [
                  edit('recieve', 'receive'),
                  edit('Cuda', 'CUDA', category: 'term'),
                  edit(
                    'Zhang',
                    'Wang',
                    category: 'name',
                  ), // Unsupported evidence.
                ],
              }),
            },
          };
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result));
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final service = LocalLlmService();
      addTearDown(service.stop);
      await service.prepare('http://127.0.0.1:${server.port}', 'test');
      final input = [
        'recieve receive receive Cuda Zhang. ${'字' * 8400} END_TOKEN',
      ];
      final result = await service.cleanUp(
        input,
        const CleanupOptions(
          corrections: true,
          names: true,
          terms: true,
          spellings: ['CUDA'],
        ),
      );
      expect(requests, hasLength(3));
      expect(
        formats.every(
          (schema) =>
              schema is Map && (schema['required'] as List).contains('edits'),
        ),
        true,
      );
      expect(requests.last, contains('END_TOKEN'));
      expect(
        result.texts.single,
        startsWith('receive receive receive CUDA Zhang.'),
      );
      expect(result.edits.single, hasLength(2));
    },
  );
}
