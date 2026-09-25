import 'record_actions.dart';
import 'record_export.dart';

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';

import 'package:altranscribe/shared/ui/page_layout.dart';
import 'package:altranscribe/app/l10n/localized_issue.dart';
import 'package:altranscribe/shared/ui/transcript_tile.dart';

class RecordDetailDialog extends StatelessWidget {
  const RecordDetailDialog({
    super.key,
    required this.live,
    required this.initial,
    required this.english,
  });
  final RealtimeController live;
  final TranscriptRecord initial;
  final bool english;
  String t(String key) => strings[key]![english ? 1 : 0];
  String issue(String value) => localizedIssue(value, english);
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: live,
      builder: (context, _) {
        final record =
            live.records.where((item) => item.id == initial.id).firstOrNull ??
            initial;
        return AlertDialog(
          insetPadding: EdgeInsets.symmetric(
            horizontal: MediaQuery.sizeOf(context).width * .05,
            vertical: 24,
          ),
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          actionsPadding: const EdgeInsets.all(24),
          title: Text(record.displayTitle),
          content: SizedBox(
            width: 512,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        visualDensity: altChipDensity,
                        avatarBoxConstraints: altChipIconBounds,
                        avatar: const Icon(AltIcons.check, size: 18),
                        label: Text(t('recordStatus_${record.status}')),
                      ),
                      Chip(
                        visualDensity: altChipDensity,
                        avatarBoxConstraints: altChipIconBounds,
                        avatar: const Icon(AltIcons.schedule, size: 18),
                        label: Text(record.dateTimeLabel),
                      ),
                      Chip(
                        visualDensity: altChipDensity,
                        avatarBoxConstraints: altChipIconBounds,
                        avatar: const Icon(AltIcons.segment, size: 18),
                        label: Text('${record.lines.length} ${t('segments')}'),
                      ),
                    ],
                  ),
                  if (record.cleanupStatus != 'none') ...[
                    const SizedBox(height: 12),
                    Text(t('cleanup_${record.cleanupStatus}')),
                    if (record.cleanupError != null)
                      Text(issue(record.cleanupError!)),
                  ],
                  if (record.summary != null) ...[
                    const SizedBox(height: 16),
                    pagePanel(
                      context,
                      pageStack([
                        Row(
                          children: [
                            Icon(
                              AltIcons.autoAwesome,
                              size: 18,
                              color: colors.onTertiaryContainer,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              t('generatedSummary'),
                              style: text.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: colors.onTertiaryContainer,
                              ),
                            ),
                          ],
                        ),
                        SelectableText(
                          record.summary!,
                          style: text.bodyMedium?.copyWith(
                            color: colors.onTertiaryContainer,
                          ),
                        ),
                      ], gap: 6),
                      radius: 16,
                      padding: const EdgeInsets.all(16),
                      color: colors.tertiaryContainer,
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (record.summaryStatus != 'none' &&
                      record.summaryStatus != 'done') ...[
                    const SizedBox(height: 12),
                    Text(t('summary_${record.summaryStatus}')),
                    if (record.summaryError != null)
                      Text(issue(record.summaryError!)),
                  ],
                  if (record.error != null)
                    Text(
                      issue(record.error!),
                      style: TextStyle(color: colors.error),
                    ),
                  if (record.lines.isEmpty) Text(t('noSpeechRecorded')),
                  pageStack([
                    for (final line in record.lines)
                      TranscriptTile(
                        line: line,
                        english: english,
                        compact: true,
                      ),
                  ], gap: 12),
                  const SizedBox(height: 16),
                  Tooltip(
                    message: '${live.store.directory.path}/${record.id}.json',
                    child: Text(
                      t('storedLocally'),
                      style: text.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (record.inputFile != null)
              TextButton.icon(
                key: const Key('open-record-file'),
                onPressed: () => openRecordFile(context, record, english),
                icon: const Icon(AltIcons.folderOpen),
                label: Text(
                  t(MobilePlatform.android ? 'openFile' : 'openFileLocation'),
                ),
              ),
            TextButton.icon(
              key: const Key('export-record'),
              onPressed: record.lines.isEmpty
                  ? null
                  : () => showExportDialog(context, record, english),
              icon: const Icon(AltIcons.download),
              label: Text(t('exportRecord')),
            ),
            TextButton.icon(
              onPressed: live.canEditRecord(record)
                  ? () => showRenameRecordDialog(context, live, record, english)
                  : null,
              icon: const Icon(Icons.edit_outlined),
              label: Text(t('renameTitle')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('done')),
            ),
          ],
        );
      },
    );
  }
}
