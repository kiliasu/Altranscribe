import 'dart:async';
import 'dart:math';

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/transcription/transcript_assembler.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/pause_cutter.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/files/sentence_merger.dart';

/// One offline file at a time, using the session's already prepared services.
class FileTranscriber {
  FileTranscriber(this.decoder);
  final AudioFileDecoder decoder;
  bool cancelled = false;

  /// What the file is going through, and when that began and last moved
  /// on: the file screen works out speed and time left from them.
  String get stage => _stage;
  set stage(String value) {
    if (value == _stage) return;
    _stage = value;
    stageStarted = DateTime.now();
    progressAt = null;
  }

  String _stage = 'fileTranscribing';
  DateTime stageStarted = DateTime.now();
  DateTime? progressAt;

  /// Audio transcribed so far, and audio read from the file so far, which
  /// runs ahead while a long piece collects before its request.
  int processedMs = 0;
  int decodedMs = 0;

  /// The file's length, when the decoder can tell it without decoding.
  int? durationMs;

  /// A long file changes many times a second while its lines translate
  /// side by side. The screen hears about it a few times a second and the
  /// disk about once; every stage ends with a save that waits.
  static const changeInterval = Duration(milliseconds: 200);
  static const saveInterval = Duration(seconds: 1);
  TranscriptRecord? _record;
  RecordStore? _store;
  void Function()? _onChanged;
  Timer? _changeTimer;
  Timer? _saveTimer;
  Object? _saveFailure;

  Future<void> cancel() async {
    cancelled = true;
    await decoder.cancel();
  }

  Future<void> run({
    required TranscriptRecord record,
    required SpeechEngine engine,
    required TranslationService translator,
    required RecordStore store,
    required CleanupOptions options,
    required void Function() onChanged,
    int chunkSeconds = 20,
    PauseCutter? cutter,
    int parallel = 1,
    TranslationContextPolicy translationContext =
        const TranslationContextPolicy(),
  }) async {
    if (await transcribe(
      record: record,
      engine: engine,
      store: store,
      onChanged: onChanged,
      chunkSeconds: chunkSeconds,
      cutter: cutter,
    )) {
      await process(
        record: record,
        translator: translator,
        store: store,
        options: options,
        onChanged: onChanged,
        parallel: parallel,
        translationContext: translationContext,
      );
    }
  }

  /// Recognizes the file's speech into [record]: pieces of [chunkSeconds],
  /// or cut at pauses by [cutter]. False when it was cancelled or failed;
  /// the record is then saved as final, and [process] must not follow.
  Future<bool> transcribe({
    required TranscriptRecord record,
    required SpeechEngine engine,
    required RecordStore store,
    required void Function() onChanged,
    int chunkSeconds = 20,
    PauseCutter? cutter,
  }) async {
    _begin(record, store, onChanged);
    stageStarted = DateTime.now();
    final sentences = TranscriptAssembler();
    decoder.onDecoded = (endMs) {
      decodedMs = endMs;
      _changedSoon();
    };
    try {
      durationMs = await decoder.durationMs(record.inputFile!);
      await _saveNow();
      await for (final chunk in decoder.decode(
        record.inputFile!,
        chunkSeconds: chunkSeconds,
        cutter: cutter,
      )) {
        if (cancelled) break;
        final wave = pcmToWave(chunk.pcm);
        if (engine is TimedSpeechEngine) {
          final result = await engine.transcribeTimed(wave, record.language);
          if (cancelled) break;
          final timed = timedSentences(
            result.text,
            result.words,
            chunk.endMs - chunk.startMs,
          );
          for (final (i, sentence) in timed.indexed) {
            sentences.accept(
              record,
              source: 'file',
              startMs: chunk.startMs + sentence.startMs,
              endMs: chunk.startMs + sentence.endMs,
              text: sentence.text,
              continues: i == timed.length - 1,
              estimated: sentence.estimated,
            );
          }
        } else {
          final text = await engine.transcribe(wave, record.language);
          if (cancelled) break;
          sentences.accept(
            record,
            source: 'file',
            startMs: chunk.startMs,
            endMs: chunk.endMs,
            text: text,
            continues: true,
          );
        }
        processedMs = chunk.endMs;
        progressAt = DateTime.now();
        _saveSoon();
        _changedSoon();
      }
      if (!cancelled) {
        await _saveNow();
        return true;
      }
    } catch (e) {
      if (!cancelled) {
        record.status = 'error';
        record.error = e.toString();
      }
    } finally {
      decoder.onDecoded = null;
    }
    await _finish();
    return false;
  }

  /// Cleans up, translates and summarizes a transcribed [record] as its
  /// options ask, then saves it as final. Lines are translated [parallel]
  /// at a time.
  Future<void> process({
    required TranscriptRecord record,
    required TranslationService translator,
    required RecordStore store,
    required CleanupOptions options,
    required void Function() onChanged,
    int parallel = 1,
    TranslationContextPolicy translationContext =
        const TranslationContextPolicy(),
  }) async {
    _begin(record, store, onChanged);
    try {
      if (cancelled) return;

      Future<void> clean(bool translation) async {
        if (!options.spellingEnabled || cancelled) return;
        stage = translation ? 'fileCleaningTranslation' : 'fileCleaning';
        _changedNow();
        final lines = record.lines
            .where((line) => !translation || line.translation != null)
            .toList();
        final originals = lines
            .map((line) => translation ? line.translation! : line.text)
            .toList();
        try {
          final result = await translator.cleanUp(
            originals,
            options,
            language: translation ? record.targetLanguage! : record.language,
          );
          if (cancelled) return;
          for (var i = 0; i < lines.length; i++) {
            if (result.edits[i].isEmpty) continue;
            if (translation) {
              if (record.translationTerms.any(
                (term) =>
                    term.isTranslatedIn(originals[i]) &&
                    !term.isTranslatedIn(result.texts[i]),
              )) {
                continue;
              }
              lines[i].revisedTranslation = result.texts[i];
              lines[i].translationEdits = result.edits[i];
            } else {
              lines[i].revisedText = result.texts[i];
              lines[i].textEdits = result.edits[i];
            }
          }
        } catch (e) {
          if (cancelled) return;
          record.cleanupStatus = 'failed';
          record.cleanupError = e.toString();
        }
        await _saveNow();
      }

      await clean(false);
      final prepareNames =
          record.targetLanguage != null &&
          record.targetLanguage != record.language;
      if (!cancelled &&
          (prepareNames || options.mergeSentences) &&
          record.lines.isNotEmpty) {
        stage = 'filePreparingText';
        _changedNow();
        for (final joining in [
          if (options.mergeSentences) true,
          if (prepareNames) false,
        ]) {
          try {
            final prepared = await translator.prepareText(
              record.lines.map((line) => line.displayText).toList(),
              record.language,
              joining ? null : record.targetLanguage,
              mergeSentences: joining,
              terms: record.translationTerms,
              rules: record.translationRules,
            );
            if (cancelled) return;
            if (joining) {
              mergeTranscriptFragments(record, prepared.joins);
            } else {
              record.translationTerms = prepared.terms;
            }
          } catch (e) {
            if (cancelled) return;
            record.cleanupStatus = 'failed';
            record.cleanupError = e.toString();
          }
          await _saveNow();
        }
      }
      if (record.targetLanguage != null && !cancelled) {
        stage = 'fileTranslating';
        _changedNow();
        await _translateLines(record, translator, translationContext, parallel);
        await clean(true);
      }
      if (cancelled) return;
      if (options.enabled && record.cleanupStatus != 'failed') {
        record.cleanupStatus = 'done';
      }
      if (record.summaryStatus == 'pending') {
        if (record.lines.isEmpty) {
          record.summaryStatus = 'empty';
        } else {
          stage = 'generatingSummary';
          _changedNow();
          try {
            final summary = await translator.summarize(
              record.lines.map((line) => line.displayText).toList(),
              record.summaryLanguage!,
            );
            if (cancelled) return;
            record.title = summary.title;
            record.summary = summary.summary;
            record.summaryStatus = 'done';
          } catch (e) {
            if (cancelled) return;
            record.summaryStatus = 'failed';
            record.summaryError = e.toString();
          }
        }
      }
    } catch (e) {
      if (!cancelled) {
        record.status = 'error';
        record.error = e.toString();
      }
    } finally {
      await _finish();
    }
  }

  /// Translates the lines in order, [parallel] at a time: an online service
  /// answers several requests as fast as one, and a local server queues or
  /// batches them. Each line keeps its own state, so a slow or failed line
  /// holds up none of the others.
  Future<void> _translateLines(
    TranscriptRecord record,
    TranslationService translator,
    TranslationContextPolicy translationContext,
    int parallel,
  ) async {
    final lines = record.lines.toList();
    var next = 0;
    Future<void> worker() async {
      while (!cancelled && next < lines.length) {
        final line = lines[next++];
        line.translationStatus = 'pending';
        _changedSoon();
        try {
          final translation = record.language == record.targetLanguage
              ? line.displayText
              : await translator.translate(
                  line.displayText,
                  record.language,
                  record.targetLanguage!,
                  context: translationContext.select(record, line),
                  rules: record.translationRules,
                  terms: record.translationTerms,
                );
          if (cancelled) {
            line.translationStatus = 'interrupted';
            return;
          }
          line.translation = translation;
          line.translationStatus = 'done';
        } catch (e) {
          line.translationStatus = cancelled ? 'interrupted' : 'failed';
          if (!cancelled) line.translationError = e.toString();
        }
        progressAt = DateTime.now();
        _saveSoon();
        _changedSoon();
      }
    }

    await Future.wait([for (var i = 0; i < max(1, parallel); i++) worker()]);
    await _saveNow();
  }

  void _begin(
    TranscriptRecord record,
    RecordStore store,
    void Function() onChanged,
  ) {
    _record = record;
    _store = store;
    _onChanged = onChanged;
  }

  void _changedNow() {
    _changeTimer?.cancel();
    _changeTimer = null;
    _onChanged?.call();
  }

  void _changedSoon() {
    _changeTimer ??= Timer(changeInterval, _changedNow);
  }

  void _saveSoon() {
    _saveTimer ??= Timer(saveInterval, () {
      _saveTimer = null;
      unawaited(_write());
    });
  }

  /// A write that fails is reported by the next save that waits, so a file
  /// that goes on for a while still learns of a full disk.
  Future<void> _write() async {
    final record = _record;
    final store = _store;
    if (record == null || store == null) return;
    try {
      await store.save(record);
    } catch (e) {
      _saveFailure = e;
    }
  }

  Future<void> _saveNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _write();
    _changedNow();
    if (_saveFailure case final failure?) {
      _saveFailure = null;
      throw failure;
    }
  }

  /// Settles what is still open: a cancelled step reads as interrupted.
  Future<void> _finish() async {
    final record = _record!;
    if (cancelled && record.targetLanguage != null) {
      for (final line in record.lines) {
        if (line.translationStatus == 'none' ||
            line.translationStatus == 'pending') {
          line.translationStatus = 'interrupted';
        }
      }
    }
    if (record.status != 'error') {
      record.status = cancelled ? 'interrupted' : 'completed';
    }
    if (record.cleanupStatus == 'pending') {
      record.cleanupStatus = 'interrupted';
    }
    if (record.summaryStatus == 'pending') {
      record.summaryStatus = 'interrupted';
    }
    await _saveNow();
  }
}
