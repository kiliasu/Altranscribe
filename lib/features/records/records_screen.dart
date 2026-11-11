import 'record_actions.dart';

import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:altranscribe/shared/ui/motion.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';

import 'package:altranscribe/shared/ui/page_layout.dart';
import 'package:altranscribe/app/l10n/localized_issue.dart';
import 'package:altranscribe/shared/ui/confirmation_dialog.dart';

import 'record_detail_dialog.dart';
import 'record_labels.dart';

class RecordsScreen extends StatefulWidget {
  const RecordsScreen({
    super.key,
    required this.controller,
    required this.english,
    required this.query,
    required this.onQueryChanged,
    required this.onTranscribe,
    this.searchFocus,
  });
  final RealtimeController controller;
  final bool english;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onTranscribe;

  /// Lets a keyboard shortcut put the cursor in the search field.
  final FocusNode? searchFocus;
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

  Future<void> showRecord(TranscriptRecord record) => showAltDialog<void>(
    context: context,
    builder: (_) => RecordDetailDialog(
      live: live,
      initial: record,
      english: widget.english,
    ),
  );

  /// The transcripts found for [shownQuery] among [searched]. Reading every
  /// line of every transcript is done once per search and library: a
  /// running session rebuilds this page several times a second.
  List<TranscriptRecord>? found;
  List<TranscriptRecord>? searched;
  int searchedCount = 0;
  String foundQuery = '';

  /// The search the list was last built for; rows move only when the
  /// library itself changes, not at every keystroke.
  String shownQuery = '';

  List<TranscriptRecord> matching(String query) {
    final all = live.records;
    if (query.isEmpty) return all;
    if (found != null &&
        foundQuery == query &&
        identical(searched, all) &&
        searchedCount == all.length) {
      return found!;
    }
    foundQuery = query;
    searched = all;
    searchedCount = all.length;
    return found = all
        .where(
          (record) =>
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
  }

  /// One transcript: the whole row opens it, and what else can be done
  /// with it sits at its end, behind one button where the row is narrow.
  Widget recordRow(TranscriptRecord record, bool compact) {
    final editable = live.canEditRecord(record);
    final summarizing = live.updatingRecordId == record.id;
    return InkWell(
      onTap: () => showRecord(record),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 10, compact ? 4 : 8, 10),
        child: Row(
          children: [
            record.summary != null
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
            const SizedBox(width: 16),
            Expanded(
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
                    recordLine(record, widget.english),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (compact)
              summarizing
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: AltLoading(size: 20),
                    )
                  : PopupMenuButton<String>(
                      key: ValueKey('more-${record.id}'),
                      tooltip: t('moreActions'),
                      enabled: editable,
                      icon: const Icon(AltIcons.moreVert),
                      onSelected: (action) => switch (action) {
                        'summary' => generateRecordSummary(record),
                        'rename' => renameRecord(record),
                        _ => deleteRecord(record),
                      },
                      itemBuilder: (_) => [
                        if (record.needsSummary && record.lines.isNotEmpty)
                          PopupMenuItem(
                            value: 'summary',
                            child: Text(t('generateSummary')),
                          ),
                        PopupMenuItem(
                          value: 'rename',
                          child: Text(t('renameTitle')),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(t('deleteRecord')),
                        ),
                      ],
                    )
            else ...[
              if (record.needsSummary)
                IconButton.filledTonal(
                  key: ValueKey('summarize-${record.id}'),
                  tooltip: t('generateSummary'),
                  onPressed: editable && record.lines.isNotEmpty
                      ? () => generateRecordSummary(record)
                      : null,
                  icon: summarizing
                      ? const AltLoading(size: 20)
                      : const Icon(AltIcons.autoAwesome, size: 24),
                ),
              IconButton(
                key: ValueKey('rename-${record.id}'),
                tooltip: t('renameTitle'),
                onPressed: editable ? () => renameRecord(record) : null,
                icon: const Icon(AltIcons.edit, size: 24),
              ),
              IconButton(
                key: ValueKey('delete-${record.id}'),
                tooltip: t('deleteRecord'),
                onPressed: editable ? () => deleteRecord(record) : null,
                icon: const Icon(Icons.delete_outline_rounded, size: 24),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget libraryPage() {
    final query = widget.query.trim().toLowerCase();
    final records = matching(query);
    // A phone's row has room for the title and one button.
    final compact = MediaQuery.sizeOf(context).width < 600;
    // A transcript that is saved or deleted makes or gives up its room;
    // while a search narrows the list, rows only come and go.
    final moving = query == shownQuery;
    shownQuery = query;
    return pageStack([
      if (live.records.isNotEmpty)
        SizedBox(
          height: 56,
          child: TextFormField(
            key: const Key('record-search'),
            focusNode: widget.searchFocus,
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
      if (live.records.isNotEmpty)
        pagePanel(
          context,
          AltFlow(
            animate: moving,
            children: [
              for (final record in records)
                KeyedSubtree(
                  key: ValueKey(record.id),
                  child: recordRow(record, compact),
                ),
            ],
          ),
        ),
      if (live.records.isEmpty)
        pageEmptyState(
          context,
          AltIcons.history,
          t('emptyLibrary'),
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
          child: Text(
            t('noSearchResults'),
            textAlign: TextAlign.center,
            style: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
    ]);
  }
}
