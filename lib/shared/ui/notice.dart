import 'package:material_ui/material_ui.dart';

import 'alt_icons.dart';

enum NoticeTone { info, warning, error }

/// Something to know about where the user is looking: a failure, a warning
/// or a remark. One shape in three tones, wherever it appears, so a problem
/// is never a loose line of coloured text.
class AltNotice extends StatelessWidget {
  const AltNotice(
    this.message, {
    super.key,
    this.tone = NoticeTone.info,
    this.action,
    this.selectable = false,
  });
  const AltNotice.warning(
    this.message, {
    super.key,
    this.action,
    this.selectable = false,
  }) : tone = NoticeTone.warning;
  const AltNotice.error(
    this.message, {
    super.key,
    this.action,
    this.selectable = false,
  }) : tone = NoticeTone.error;
  final String message;
  final NoticeTone tone;

  /// The text can be selected, for a service's own error message that is
  /// worth copying.
  final bool selectable;

  /// What can be done about it, at the trailing edge.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (fill, ink, icon) = switch (tone) {
      NoticeTone.error => (
        colors.errorContainer,
        colors.onErrorContainer,
        AltIcons.error,
      ),
      NoticeTone.warning => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
        AltIcons.warning,
      ),
      NoticeTone.info => (
        colors.surfaceContainerHigh,
        colors.onSurfaceVariant,
        AltIcons.info,
      ),
    };
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(color: ink);
    return Semantics(
      container: true,
      // A problem that appears is announced; a remark is not.
      liveRegion: tone != NoticeTone.info,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 10, action == null ? 16 : 6, 10),
          child: Row(
            children: [
              Icon(icon, size: 20, color: ink),
              const SizedBox(width: 10),
              Expanded(
                child: selectable
                    ? SelectableText(message, style: style)
                    : Text(message, style: style),
              ),
              if (action != null) ...[
                const SizedBox(width: 8),
                // The action reads in the notice's own ink.
                TextButtonTheme(
                  data: TextButtonThemeData(
                    style: TextButton.styleFrom(
                      foregroundColor: ink,
                      minimumSize: const Size(32, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  child: action!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
