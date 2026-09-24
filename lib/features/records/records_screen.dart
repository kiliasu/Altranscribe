import 'record_actions.dart';

import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';

import 'package:altranscribe/shared/ui/page_layout.dart';
import 'package:altranscribe/app/l10n/localized_issue.dart';
import 'package:altranscribe/shared/ui/confirmation_dialog.dart';

import 'record_detail_dialog.dart';

class RecordsScreen extends StatefulWidget {
  const RecordsScreen({
    super.key,
    required this.controller,
    required this.english,
    required this.query,
    required this.onQueryChanged,
    required this.onTranscribe,
  });
  final RealtimeController controller;
  final bool english;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onTranscribe;
  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends State<RecordsScreen> {
  RealtimeController get live => widget.controller;
  ColorScheme get colors => Theme.of(context).colorScheme;
  TextTheme get text => Theme.of(context).textTheme;
  String t(String key) => strings[key]![widget.english ? 1 : 0];
  String issue(String value) => localizedIssue(value, widget.english);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: live,
    builder: (context, _) => libraryPage(),
  );
  Future<void> generateRecordSummary(TranscriptRecord record) async {
    try {
      await live.generateRecordSummary(record.id, widget.english ? 'en' : 'zh');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t('recordSummaryReady'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(issue(e.toString()))));
    }
  }

  Future<void> deleteRecord(TranscriptRecord record) async {
    if (!await confirmRemoval(
          context,
          widget.english,
          'deleteRecord',
          '${record.displayTitle}\n${record.dateTimeLabel}\n\n${t('deleteRecordHint')}',
          'confirm-delete',
        ) ||
        !mounted) {
      return;
    }
    try {
      await live.deleteRecord(record.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(issue(e.toString()))));
      }
    }
  }

  Future<void> renameRecord(TranscriptRecord record) =>
      showRenameRecordDialog(context, live, record, widget.english);

  Future<void> showRecord(TranscriptRecord record) => showDialog<void>(
    context: context,
    builder: (_) => RecordDetailDialog(
      live: live,
      initial: record,
      english: widget.english,
    ),
  );

  Widget libraryPage() {
    final query = widget.query.trim().toLowerCase();
    final records = live.records
        .where(
          (record) =>
              query.isEmpty ||
              '${record.displayTitle} ${record.dateTimeLabel} ${record.summary ?? ''}'
                  .toLowerCase()
                  .contains(query) ||
              record.lines.any(
                (line) => '${line.displayText} ${line.displayTranslation ?? ''}'
                    .toLowerCase()
                    .contains(query),
              ),
        )
        .toList();
    return pageStack([
      SizedBox(
        height: 56,
        child: TextFormField(
          key: const Key('record-search'),
          initialValue: widget.query,
          onChanged: widget.onQueryChanged,
          decoration: InputDecoration(
            hintText: t('searchRecords'),
            prefixIcon: const Icon(AltIcons.search),
            fillColor: colors.surfaceContainerHigh,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: BorderSide(color: colors.primary),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
        ),
      ),
      if (records.isNotEmpty)
        pagePanel(
          context,
          Column(
            children: [
              for (final record in records)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      InkWell(
                        onTap: () => showRecord(record),
                        child: record.summary != null
                            ? const AltBlob(
                                icon: AltIcons.autoAwesome,
                                size: 40,
                                iconSize: 22,
                              )
                            : Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: colors.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(
                                    record.inputFile == null ? 999 : 12,
                                  ),
                                ),
                                child: Icon(
                                  record.inputFile == null
                                      ? AltIcons.description
                                      : AltIcons.audioFile,
                                  size: 22,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: InkWell(
                          onTap: () => showRecord(record),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                record.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodyLarge,
                              ),
                              Text(
                                '${record.dateTimeLabel} · ${record.lines.length} ${t('segments')} · ${t('recordStatus_${record.status}')}',
                                style: text.bodyMedium?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (record.needsSummary)
                        IconButton.filledTonal(
                          key: ValueKey('summarize-${record.id}'),
                          tooltip: t('generateSummary'),
                          onPressed:
                              live.canEditRecord(record) &&
                                  record.lines.isNotEmpty
                              ? () => generateRecordSummary(record)
                              : null,
                          icon: live.updatingRecordId == record.id
                              ? const AltLoading(size: 20)
                              : const Icon(AltIcons.autoAwesome, size: 24),
                        ),
                      IconButton(
                        key: ValueKey('rename-${record.id}'),
                        tooltip: t('renameTitle'),
                        onPressed: live.canEditRecord(record)
                            ? () => renameRecord(record)
                            : null,
                        icon: const Icon(AltIcons.edit, size: 24),
                      ),
                      IconButton(
                        key: ValueKey('delete-${record.id}'),
                        tooltip: t('deleteRecord'),
                        onPressed: live.canEditRecord(record)
                            ? () => deleteRecord(record)
                            : null,
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 24,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      if (live.records.isEmpty)
        pageEmptyState(
          context,
          AltIcons.history,
          t('emptyLibrary'),
          t('emptyLibraryHint'),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: const Size(160, 56)),
            onPressed: widget.onTranscribe,
            icon: const Icon(AltIcons.add),
            label: Text(t('transcribe')),
          ),
        ),
      if (live.records.isNotEmpty && records.isEmpty)
        Padding(
          padding: const EdgeInsets.all(32),
          child: Text(t('noSearchResults'), textAlign: TextAlign.center),
        ),
      if (live.records.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            t('storedLocally'),
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
    ]);
  }
}
