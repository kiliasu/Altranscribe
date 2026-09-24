import 'package:altranscribe/data/models/transcript_record.dart';

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/data/services/transcription/transcript_assembler.dart';

import 'package:altranscribe/shared/ui/page_layout.dart';
import 'package:altranscribe/app/l10n/localized_issue.dart';

class TranscriptTile extends StatelessWidget {
  const TranscriptTile({
    super.key,
    required this.line,
    required this.english,
    this.compact = false,
    this.captionSize = 22,
    this.highlight = false,
  });
  final TranscriptLine line;
  final bool english;
  final bool compact;
  final double captionSize;
  final bool highlight;
  String t(String key) => strings[key]![english ? 1 : 0];
  String issue(String value) => localizedIssue(value, english);
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: compact ? EdgeInsets.zero : const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: highlight ? colors.surfaceContainerLow : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (!compact) ...[
                Icon(
                  line.source == 'file'
                      ? AltIcons.audioFile
                      : line.source == 'system'
                      ? AltIcons.volumeUp
                      : AltIcons.mic,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  '${t(line.source == 'file'
                      ? 'file'
                      : line.source == 'system'
                      ? 'systemAudio'
                      : 'microphone')} · ${line.timingEstimated ? '≈ ' : ''}${Duration(milliseconds: line.startMs).toString().split('.').first}',
                  style: text.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 4 : 8),
          if (line.continuous)
            pageHint(
              context,
              t(line.timingEstimated ? 'cloudTimedGroups' : 'cloudContinuous'),
            ),
          if (line.transcriptionStatus != 'done')
            pageHint(
              context,
              t(
                line.transcriptionStatus == 'streamed'
                    ? 'cloudStreamed'
                    : line.transcriptionStatus == 'partial'
                    ? 'cloudPartial'
                    : 'cloudPartialSaved',
              ),
            ),
          SelectableText(
            readableTranscript(line.displayText),
            style: text.bodyLarge?.copyWith(
              fontSize: compact ? 16 : captionSize,
              height: compact ? 1.5 : 1.45,
              letterSpacing: compact ? .5 : .2,
            ),
          ),
          if (line.translation != null) ...[
            SizedBox(height: compact ? 4 : 8),
            SelectableText(
              readableTranscript(line.displayTranslation!),
              style: text.bodyLarge?.copyWith(
                fontSize: compact ? 16 : captionSize,
                height: compact ? 1.5 : 1.45,
                letterSpacing: compact ? .5 : .2,
                fontWeight: FontWeight.w500,
                color: colors.primary,
              ),
            ),
          ],
          if (line.textEdits.isNotEmpty || line.translationEdits.isNotEmpty)
            ExpansionTile(
              key: PageStorageKey(line),
              title: Text(t('viewOriginals')),
              tilePadding: EdgeInsets.zero,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(line.text),
                ),
                if (line.translation != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(line.translation!),
                  ),
                for (final edit in [
                  ...line.textEdits,
                  ...line.translationEdits,
                ])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${edit.from} → ${edit.to}'),
                    subtitle: Text(
                      t(
                        edit.evidence == 'glossary'
                            ? 'glossaryEvidence'
                            : 'repeatedEvidence',
                      ),
                    ),
                  ),
              ],
            ),
          if (line.translationStatus == 'pending') ...[
            const SizedBox(height: 8),
            pageHint(context, t('translating')),
            if (line.displayTranslation?.trim().isNotEmpty != true)
              Padding(
                key: const Key('translation-placeholder'),
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final width in [.78, .48])
                      FractionallySizedBox(
                        widthFactor: width,
                        child: Container(
                          height: (compact ? 16 : captionSize) * .75,
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
          if (line.translationStatus == 'interrupted')
            pageHint(context, t('translationInterrupted')),
          if (line.translationStatus == 'failed') ...[
            const SizedBox(height: 8),
            Text(
              '${t('translationFailed')}${line.translationError == null ? '' : '\n${issue(line.translationError!)}'}',
              style: text.bodySmall?.copyWith(color: colors.error),
            ),
          ],
        ],
      ),
    );
  }
}
