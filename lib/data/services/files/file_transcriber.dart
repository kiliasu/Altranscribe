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
  String stage = 'fileTranscribing';
  int processedMs = 0;

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
    final sentences = TranscriptAssembler();
    try {
      await _save(record, store, onChanged);
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
        await _save(record, store, onChanged);
      }
      if (!cancelled) return true;
    } catch (e) {
      if (!cancelled) {
        record.status = 'error';
        record.error = e.toString();
      }
    }
    await _finish(record, store, onChanged);
    return false;
  }

  /// Cleans up, translates and summarizes a transcribed [record] as its
  /// options ask, then saves it as final.
  Future<void> process({
    required TranscriptRecord record,
    required TranslationService translator,
    required RecordStore store,
    required CleanupOptions options,
    required void Function() onChanged,
    TranslationContextPolicy translationContext =
        const TranslationContextPolicy(),
  }) async {
    Future<void> save() => _save(record, store, onChanged);
    try {
      if (cancelled) return;

      Future<void> clean(bool translation) async {
        if (!options.spellingEnabled || cancelled) return;
        stage = translation ? 'fileCleaningTranslation' : 'fileCleaning';
        onChanged();
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
        await save();
      }

      await clean(false);
      final prepareNames =
          record.targetLanguage != null &&
          record.targetLanguage != record.language;
      if (!cancelled &&
          (prepareNames || options.mergeSentences) &&
          record.lines.isNotEmpty) {
        stage = 'filePreparingText';
        onChanged();
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
          await save();
        }
      }
      if (record.targetLanguage != null && !cancelled) {
        stage = 'fileTranslating';
        onChanged();
        for (final line in record.lines) {
          if (cancelled) break;
          line.translationStatus = 'pending';
          await save();
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
              break;
            }
            line.translation = translation;
            line.translationStatus = 'done';
          } catch (e) {
            line.translationStatus = cancelled ? 'interrupted' : 'failed';
            if (!cancelled) line.translationError = e.toString();
          }
          await save();
        }
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
          onChanged();
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
      await _finish(record, store, onChanged);
    }
  }

  Future<void> _save(
    TranscriptRecord record,
    RecordStore store,
    void Function() onChanged,
  ) async {
    await store.save(record);
    onChanged();
  }

  /// Settles what is still open: a cancelled step reads as interrupted.
  Future<void> _finish(
    TranscriptRecord record,
    RecordStore store,
    void Function() onChanged,
  ) async {
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
    await _save(record, store, onChanged);
  }
}
