import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/transcription/transcript_assembler.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';

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
    TranslationContextPolicy translationContext =
        const TranslationContextPolicy(),
  }) async {
    final sentences = TranscriptAssembler();
    Future<void> save() async {
      await store.save(record);
      onChanged();
    }

    try {
      await save();
      await for (final chunk in decoder.decode(
        record.inputFile!,
        chunkSeconds: chunkSeconds,
      )) {
        if (cancelled) break;
        final text = await engine.transcribe(
          pcmToWave(chunk.pcm),
          record.language,
        );
        if (cancelled) break;
        processedMs = chunk.endMs;
        sentences.accept(
          record,
          source: 'file',
          startMs: chunk.startMs,
          endMs: chunk.endMs,
          text: text,
          continues: true,
        );
        await save();
      }
      if (cancelled) return;

      Future<void> clean(bool translation) async {
        if (!options.enabled || cancelled) return;
        stage = translation ? 'fileCleaningTranslation' : 'fileCleaning';
        onChanged();
        final lines = record.lines
            .where((line) => !translation || line.translation != null)
            .toList();
        final originals = lines
            .map((line) => translation ? line.translation! : line.text)
            .toList();
        try {
          final result = await translator.cleanUp(originals, options);
          if (cancelled) return;
          for (var i = 0; i < lines.length; i++) {
            if (result.edits[i].isEmpty) continue;
            if (translation) {
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
      await save();
    }
  }
}
