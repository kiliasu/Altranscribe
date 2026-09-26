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
    this.awaitingTranslation = false,
  });
  final TranscriptLine line;
  final bool english;
  final bool compact;
  final double captionSize;
  final bool highlight;

  /// The session will translate this line once its text is final. Its
  /// translation space is held from the first word, so the tile does not
  /// grow and shrink as the line moves from recognition to translation.
  final bool awaitingTranslation;
  String t(String key) => strings[key]![english ? 1 : 0];
  String issue(String value) => localizedIssue(value, english);
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final body = text.bodyLarge!.copyWith(
      fontSize: compact ? 16 : captionSize,
      height: compact ? 1.5 : 1.45,
      letterSpacing: compact ? .5 : .2,
    );
    final status = line.transcriptionStatus;
    // Passing states are shown in the header, where they take no extra room.
    final settling = status == 'partial' || status == 'streamed';
    final translated = line.displayTranslation?.trim().isNotEmpty == true;
    final translating =
        !translated &&
        (line.translationStatus == 'pending' || awaitingTranslation);
    final tag = status == 'partial'
        ? t('tagRecognizing')
        : status == 'streamed'
        ? t('tagUnconfirmed')
        : translating
        ? t('tagTranslating')
        : null;
    final label = text.labelMedium?.copyWith(color: colors.onSurfaceVariant);
    final Widget translation = translated
        ? SelectableText(
            key: const ValueKey('translation'),
            readableTranscript(line.displayTranslation!),
            style: body.copyWith(
              fontWeight: FontWeight.w500,
              color: colors.primary,
            ),
          )
        : TranslationPlaceholder(
            key: const Key('translation-placeholder'),
            source: readableTranscript(line.displayText),
            style: body,
            color: colors.primary.withValues(alpha: .12),
            label: t('translating'),
          );
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
                child: Text.rich(
                  TextSpan(
                    text:
                        '${t(line.source == 'file'
                            ? 'file'
                            : line.source == 'system'
                            ? 'systemAudio'
                            : 'microphone')} · ${line.timingEstimated ? '≈ ' : ''}${Duration(milliseconds: line.startMs).toString().split('.').first}',
                    children: [
                      if (tag != null)
                        TextSpan(
                          text: ' · $tag',
                          style: TextStyle(color: colors.primary),
                        ),
                    ],
                  ),
                  key: const Key('transcript-status'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: label,
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
          if (status != 'done' && !settling)
            pageHint(context, t('cloudPartialSaved')),
          SelectableText(readableTranscript(line.displayText), style: body),
          if (translated || translating) ...[
            SizedBox(height: compact ? 4 : 8),
            // The placeholder is sized like the text that replaces it; any
            // difference that remains is animated rather than jumped. With
            // reduced motion the switch is immediate.
            if (motion == Duration.zero)
              translation
            else
              AnimatedSize(
                duration: motion,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topLeft,
                child: AnimatedSwitcher(
                  duration: motion,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topLeft,
                    children: [...previous, ?current],
                  ),
                  child: translation,
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

/// Rounded bars standing in for a translation, one per line the source takes
/// at this width, so the translation usually replaces them without resizing.
class TranslationPlaceholder extends StatelessWidget {
  const TranslationPlaceholder({
    super.key,
    required this.source,
    required this.style,
    required this.color,
    required this.label,
  });
  final String source;
  final TextStyle style;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: source, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final lines = painter.computeLineMetrics().length.clamp(1, 4);
      final lineHeight = painter.preferredLineHeight;
      painter.dispose();
      return Semantics(
        label: label,
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines; i++)
              SizedBox(
                height: lineHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: i == lines - 1 ? .55 : .92,
                    child: Container(
                      height: lineHeight * .5,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
