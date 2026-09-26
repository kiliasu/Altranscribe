import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/services/cloud/cloud_live.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/data/services/transcription/nemotron_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// The native library and a downloaded model are only present on a developer
/// machine; elsewhere these tests are skipped rather than failed.
String? sherpaLibrary() {
  final dir = Directory(
    '.tools/pub-cache/hosted/pub.dev/sherpa_onnx_windows-1.13.8/windows',
  );
  return Platform.isWindows && dir.existsSync() ? dir.absolute.path : null;
}

String? englishModel() {
  final folder = Directory(
    '.tools/sherpa-onnx/models/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25',
  );
  return folder.existsSync() ? folder.absolute.path : null;
}

Uint8List pcmSlice(Uint8List wave, int fromMs, int toMs) =>
    Uint8List.sublistView(wave, 44 + fromMs * 32, 44 + toMs * 32);

void main() {
  final library = sherpaLibrary();
  final model = englishModel();
  final clip = File('build/spike/clip.wav');
  final ready = library != null && model != null && clip.existsSync();

  test(
    'the English model transcribes a window and streams a live source',
    () async {
      final engine = NemotronEngine(libraryPath: library);
      addTearDown(engine.stop);
      await engine.start('', model!, Directory('unused'));
      // The spike folder keeps the release name, so it is not a catalog entry.
      expect(engine.backend, startsWith('CPU · Nemotron · '));
      expect(engine.running, isTrue);
      final wave = await clip.readAsBytes();

      // Chunk mode, on the very quiet recording, relies on the built-in gain.
      final text = await engine.transcribe(
        pcmToWave(pcmSlice(wave, 13000, 30000)),
        'en',
      );
      expect(text.toLowerCase(), contains('amplifier'));

      // Streaming mode: frames of 100 ms, an endpoint at the pause after
      // "amplifier", and everything else at finish.
      final updates = <CloudLiveText>[];
      final live = await engine.openLive(
        source: 'microphone',
        language: 'en',
        onText: updates.add,
      );
      for (var ms = 13000; ms < 30000; ms += 100) {
        live.add(pcmSlice(wave, ms, ms + 100), ms, ms + 100);
        // Paced like capture: let each half second be decoded before more arrives.
        if (ms % 500 == 0) await live.idle;
      }
      await live.finish();
      expect(updates.any((update) => !update.finalized), isTrue);
      final finals = updates.where((update) => update.finalized).toList();
      expect(finals, isNotEmpty);
      expect(
        finals.map((update) => update.text.toLowerCase()).join(' '),
        contains('amplifier'),
      );
      for (final update in finals) {
        expect(update.startMs, lessThan(update.endMs));
        expect(update.startMs, greaterThanOrEqualTo(12400));
        expect(update.endMs, lessThanOrEqualTo(30000));
        expect(update.source, 'microphone');
      }
      final ids = finals.map((update) => update.id).toSet();
      expect(ids.length, finals.length, reason: 'each segment has its own id');
    },
    skip: ready
        ? false
        : 'needs the sherpa-onnx library, a model and build/spike/clip.wav',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a missing model folder is reported before any library is loaded',
    () async {
      final engine = NemotronEngine(libraryPath: library);
      await expectLater(
        engine.start('', 'build/no-such-model', Directory('unused')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'nemotronModelMissing',
          ),
        ),
      );
      expect(engine.running, isFalse);
      await expectLater(
        engine.transcribe(Uint8List(44), 'en'),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('catalog entries describe both models with pinned sources', () {
    expect(ModelCatalog.nemotronModels.map((m) => m.id), [
      'nemotron-en-0.6b',
      'nemotron-3.5-0.6b',
    ]);
    for (final model in ModelCatalog.nemotronModels) {
      expect(model.files.map((f) => f.name), NemotronModel.fileNames);
      expect(model.bytes, greaterThan(600000000));
      expect(model.size, endsWith('MB'));
      expect(
        model.downloadUri(model.files.first).toString(),
        startsWith('https://huggingface.co/csukuangfj2/'),
      );
      expect(
        model.downloadUri(model.files.first).path,
        contains(model.revision),
      );
      expect(model.licenseUrl, startsWith('https://'));
    }
    expect(ModelCatalog.nemotron('nemotron-3.5-0.6b')?.multilingual, isTrue);
    expect(ModelCatalog.nemotron('nope'), isNull);
  });
}
