import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/localized_issue.dart';
import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/files/media_paths.dart';
import 'package:altranscribe/data/services/files/transcript_export.dart';
import 'package:altranscribe/data/services/logging/app_log.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/shared/ui/expressive.dart';

enum ExportMedia { none, link, embed }

ExportLabels exportLabels(bool english) {
  String t(String key) => strings[key]![english ? 1 : 0];
  return ExportLabels(
    summary: t('exportSummaryHeading'),
    transcript: t('exportTranscriptHeading'),
    segments: t('segments'),
    sourceFile: t('exportSourceFile'),
    sources: {
      'microphone': t('microphone'),
      'system': t('systemAudio'),
      'file': t('file'),
    },
    generatedBy: t('exportedFrom'),
  );
}

/// Reveals the record's source file: Explorer on Windows, a viewer on Android.
Future<void> openRecordFile(
  BuildContext context,
  TranscriptRecord record,
  bool english,
) async {
  final path = record.inputFile;
  if (path == null) return;
  try {
    if (MobilePlatform.android) {
      await MobilePlatform.openDocument(path);
    } else {
      if (!await File(path).exists()) {
        throw const FormatException('sourceFileMissing');
      }
      await Process.start('explorer.exe', [
        '/select,',
        path,
      ], mode: ProcessStartMode.detached);
    }
  } catch (e) {
    AppLog.instance.warn('records', 'Opening the source file failed: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedIssue(e.toString(), english))),
      );
    }
  }
}

/// Builds the document and lets the user choose where to save it. Returns the
/// saved location, or null when they cancel.
Future<String?> exportRecord(
  TranscriptRecord record,
  ExportFormat format,
  ExportMedia media,
  bool english,
) async {
  final exporter = TranscriptExporter(exportLabels(english));
  final name = TranscriptExporter.fileName(record, format);
  final String content;
  switch (format) {
    case ExportFormat.text:
      content = exporter.text(record);
    case ExportFormat.markdown:
      content = exporter.markdown(record);
    case ExportFormat.html:
      String? source;
      var mime = 'audio/mpeg';
      final input = record.inputFile;
      if (input != null && media != ExportMedia.none) {
        mime = mediaMimeType(mediaFileName(input));
        if (media == ExportMedia.link) {
          source = Uri.file(input, windows: Platform.isWindows).toString();
        } else {
          final bytes = MobilePlatform.android
              ? await MobilePlatform.readDocument(input)
              : await File(input).readAsBytes();
          if (bytes.length > 256 * 1024 * 1024) {
            throw const FormatException('fileTooLarge');
          }
          source = TranscriptExporter.dataUri(bytes, mime);
        }
      }
      content = exporter.html(record, mediaSource: source, mediaMime: mime);
  }
  final bytes = Uint8List.fromList(utf8.encode(content));
  if (MobilePlatform.android) {
    final saved = await MobilePlatform.saveDocument(
      name,
      format.mimeType,
      bytes,
    );
    if (saved) AppLog.instance.info('records', 'Exported ${format.name}');
    return saved ? name : null;
  }
  final location = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: [
      XTypeGroup(
        label: format.extension.toUpperCase(),
        extensions: [format.extension],
      ),
    ],
  );
  if (location == null) return null;
  var path = location.path;
  if (!path.toLowerCase().endsWith('.${format.extension}')) {
    path = '$path.${format.extension}';
  }
  await File(path).writeAsBytes(bytes, flush: true);
  AppLog.instance.info('records', 'Exported ${format.name} to $path');
  return path;
}

Future<void> showExportDialog(
  BuildContext context,
  TranscriptRecord record,
  bool english,
) {
  String t(String key) => strings[key]![english ? 1 : 0];
  var format = ExportFormat.text;
  var media = ExportMedia.none;
  var busy = false;
  final hasFile = record.inputFile != null;
  // A content URI means nothing to a browser, so phones can only embed.
  final canLink =
      hasFile && !MobilePlatform.android && !isDocumentUri(record.inputFile!);
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        Future<void> export() async {
          update(() => busy = true);
          try {
            final saved = await exportRecord(record, format, media, english);
            if (!context.mounted) return;
            Navigator.pop(context);
            if (saved != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${t('exportSaved')} $saved')),
              );
            }
          } catch (e) {
            AppLog.instance.warn('records', 'Export failed: $e');
            if (!context.mounted) return;
            update(() => busy = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${t('exportFailed')}: ${localizedIssue(e.toString(), english)}',
                ),
              ),
            );
          }
        }

        final text = Theme.of(context).textTheme;
        return AlertDialog(
          title: Text(t('exportRecord')),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t('exportFormat'), style: text.labelLarge),
                  RadioGroup<ExportFormat>(
                    groupValue: format,
                    onChanged: (value) {
                      if (!busy && value != null) update(() => format = value);
                    },
                    child: Column(
                      children: [
                        for (final (option, label) in [
                          (ExportFormat.text, 'exportText'),
                          (ExportFormat.markdown, 'exportMarkdown'),
                          (ExportFormat.html, 'exportHtml'),
                        ])
                          RadioListTile<ExportFormat>(
                            key: ValueKey('export-${option.name}'),
                            value: option,
                            contentPadding: EdgeInsets.zero,
                            title: Text(t(label)),
                          ),
                      ],
                    ),
                  ),
                  if (format == ExportFormat.html && hasFile) ...[
                    const SizedBox(height: 12),
                    Text(t('exportAudio'), style: text.labelLarge),
                    RadioGroup<ExportMedia>(
                      groupValue: media,
                      onChanged: (value) {
                        if (!busy && value != null) update(() => media = value);
                      },
                      child: Column(
                        children: [
                          for (final (option, label) in [
                            (ExportMedia.none, 'exportAudioNone'),
                            if (canLink) (ExportMedia.link, 'exportAudioLink'),
                            (ExportMedia.embed, 'exportAudioEmbed'),
                          ])
                            RadioListTile<ExportMedia>(
                              key: ValueKey('export-media-${option.name}'),
                              value: option,
                              contentPadding: EdgeInsets.zero,
                              title: Text(t(label)),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: Text(t('cancel')),
            ),
            FilledButton(
              key: const Key('export-confirm'),
              onPressed: busy ? null : export,
              child: busy
                  ? const AltLoading(size: 20)
                  : Text(t('exportRecord')),
            ),
          ],
        );
      },
    ),
  );
}
