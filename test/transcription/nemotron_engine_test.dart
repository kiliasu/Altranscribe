import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/services/cloud/cloud_live.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/transcription/nemotron_engine.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

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

/// A catalog whose Nemotron folder is the spike model on this machine.
class SpikeCatalog extends FakeModelCatalog {
  SpikeCatalog(this.modelFolder);
  final String modelFolder;
  @override
  String folder(NemotronModel model) => modelFolder;
}

/// Feeds a stretch of the clip as 100 ms frames placed at [sessionFrom],
/// waiting every [every] ms like capture would.
Future<void> play(
  NemotronLive live,
  Uint8List wave,
  int fromMs,
  int toMs, {
  int sessionFrom = -1,
  int every = 500,
}) async {
  final shift = sessionFrom < 0 ? 0 : sessionFrom - fromMs;
  for (var ms = fromMs; ms < toMs; ms += 100) {
    live.add(pcmSlice(wave, ms, ms + 100), ms + shift, ms + shift + 100);
    if ((ms + 100 - fromMs) % every == 0) await live.idle;
  }
}

Future<NemotronEngine> englishEngine(String library, String model) async {
  final engine = NemotronEngine(libraryPath: library);
  await engine.start('', model, Directory('unused'));
  return engine;
}

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
    'late punctuation joins the line before and batching changes nothing',
    () async {
      final engine = await englishEngine(library!, model!);
      addTearDown(engine.stop);
      final wave = await clip.readAsBytes();
      Future<List<String>> run(int every) async {
        final out = <String>[];
        final live = await engine.openLive(
          source: 'system',
          language: 'en',
          onText: (update) {
            if (update.finalized) out.add(update.text);
          },
          onAmend: (_, text) => out.add('+$text'),
        );
        await play(live, wave, 0, 90000, every: every);
        await live.finish();
        return out;
      }

      final paced = await run(100);
      final bunched = await run(2500);
      expect(bunched, paced, reason: 'grouping of frames must not matter');
      final lines = paced.where((text) => !text.startsWith('+')).toList();
      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(line, isNot(matches(RegExp(r'^[.,!?;:]'))), reason: line);
      }
      expect(paced.where((text) => text.startsWith('+')), isNotEmpty);
    },
    skip: ready
        ? false
        : 'needs the sherpa-onnx library, a model and build/spike/clip.wav',
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'a pause keeps line times on the session clock',
    () async {
      final engine = await englishEngine(library!, model!);
      addTearDown(engine.stop);
      final wave = await clip.readAsBytes();
      Future<List<CloudLiveText>> run(int resumeAt) async {
        final out = <CloudLiveText>[];
        final live = await engine.openLive(
          source: 'system',
          language: 'en',
          onText: (update) {
            if (update.finalized) out.add(update);
          },
        );
        await play(live, wave, 13000, 31000);
        await live.flush();
        await play(live, wave, 31000, 52000, sessionFrom: resumeAt);
        await live.finish();
        return out;
      }

      // Resuming at once or ten seconds later decodes the same audio the
      // same way; only the session times of what follows the pause move.
      final soon = await run(31000);
      final later = await run(41000);
      expect(later.map((line) => line.text), soon.map((line) => line.text));
      for (var i = 0; i < soon.length; i++) {
        final shift = soon[i].startMs >= 31000 ? 10000 : 0;
        expect(
          later[i].startMs,
          soon[i].startMs + shift,
          reason: later[i].text,
        );
        expect(later[i].endMs, soon[i].endMs + shift, reason: later[i].text);
      }
      final resumed = later.where((line) => line.startMs >= 41000).toList();
      expect(resumed, isNotEmpty);
      // "is changing" begins about half a second into the resumed audio; the
      // silence that closes the paused stream must not push it further.
      expect(resumed.first.startMs, lessThan(42500));
      for (final line in later) {
        expect(line.endMs - line.startMs, greaterThan(300), reason: line.text);
        expect(line.endMs, lessThanOrEqualTo(62000));
      }
    },
    skip: ready
        ? false
        : 'needs the sherpa-onnx library, a model and build/spike/clip.wav',
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'a live session through the controller keeps punctuation with its line',
    () async {
      final audio = FakeAudio();
      final live =
          RealtimeController(
              audio: audio,
              engine: FakeEngine(),
              store: MemoryStore(),
              translator: FakeTranslator(),
              recordSummarizer: FakeTranslator(),
              catalog: SpikeCatalog(model!),
              nemotron: NemotronEngine(libraryPath: library),
            )
            ..initialized = true
            ..generateSummary = false
            ..speechProvider = SpeechProvider.nemotron;
      addTearDown(live.dispose);
      await live.start(
        microphone: false,
        system: true,
        language: 'en',
        targetLanguage: 'zh',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (live.phase != SessionPhase.listening) {
        if (DateTime.now().isAfter(deadline)) fail('session did not start');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final wave = await clip.readAsBytes();
      for (var ms = 13000; ms < 56000; ms += 100) {
        audio.events.add({
          'type': 'frame',
          'source': 'system',
          'startMs': ms - 13000,
          'endMs': ms - 12900,
          'pcm': pcmSlice(wave, ms, ms + 100),
        });
        if (ms % 500 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }
      await live.stop();
      final record = live.records.first;
      final texts = record.lines.map((line) => line.text).toList();
      expect(texts, isNotEmpty);
      for (final text in texts) {
        expect(text.trim(), isNot(matches(RegExp(r'^[.,!?;:]+$'))));
      }
      expect(texts.any((text) => RegExp(r'[.,]$').hasMatch(text)), isTrue);
      expect(
        record.lines.every((line) => line.translationStatus == 'done'),
        isTrue,
      );
      expect(record.speechProvider, 'nemotron');
    },
    skip: ready
        ? false
        : 'needs the sherpa-onnx library, a model and build/spike/clip.wav',
    timeout: const Timeout(Duration(minutes: 4)),
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
