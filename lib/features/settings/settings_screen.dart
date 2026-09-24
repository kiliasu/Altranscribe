import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/app/theme/app_theme.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/features/settings/audio_settings_dialog.dart';
import 'package:altranscribe/features/settings/model_settings_dialog.dart';
import 'package:altranscribe/features/settings/translation_settings_dialog.dart';
import 'package:altranscribe/features/settings/context_settings_dialog.dart';
import 'package:altranscribe/features/settings/caption_settings_dialog.dart';

import 'package:altranscribe/shared/ui/page_layout.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.live,
    required this.english,
    required this.themeMode,
    required this.palette,
    required this.reduceMotion,
    required this.onLocale,
    required this.onTheme,
    required this.onPalette,
    required this.onMotion,
    required this.captionSize,
    required this.onCaptionSize,
    required this.modelSummary,
    required this.llmSummary,
    required this.audioSummary,
  });
  final RealtimeController live;
  final bool english;
  final ThemeMode themeMode;
  final AppPalette palette;
  final bool reduceMotion;
  final ValueChanged<bool> onLocale;
  final ValueChanged<ThemeMode> onTheme;
  final ValueChanged<AppPalette> onPalette;
  final ValueChanged<bool> onMotion;
  final double captionSize;
  final ValueChanged<double> onCaptionSize;
  final String modelSummary;
  final String llmSummary;
  final String audioSummary;

  String t(String key) => strings[key]![english ? 1 : 0];
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    Future<void> audioSettings() => showDialog<void>(
      context: context,
      builder: (_) => AudioSettingsDialog(controller: live, english: english),
    );

    Future<void> modelSettings() => showDialog<void>(
      context: context,
      builder: (_) => ModelSettingsDialog(controller: live, english: english),
    );

    Future<void> translationSettings() => showDialog<void>(
      context: context,
      builder: (_) =>
          TranslationSettingsDialog(controller: live, english: english),
    );

    Future<void> captionSettings() => showDialog<void>(
      context: context,
      builder: (_) => CaptionSettingsDialog(controller: live, english: english),
    );

    Future<void> contextSettings() => showDialog<void>(
      context: context,
      builder: (_) => ContextSettingsDialog(controller: live, english: english),
    );

    Future<void> privacyDialog() => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(AltIcons.shield),
        title: Text(t('privacy')),
        content: Text('${t('storedLocally')}\n\n${t('processingPrivacy')}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('done')),
          ),
        ],
      ),
    );

    return pageStack([
      pageColumns(
        context,
        pagePanel(
          context,
          pageStack([
            Text(t('appearance'), style: text.titleMedium),
            pageStack([
              Text(
                t('interfaceLanguage'),
                style: text.labelLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              AltButtonGroup(
                items: const [
                  AltGroupItem('简体中文', key: Key('interface-zh')),
                  AltGroupItem('English', key: Key('interface-en')),
                ],
                selected: {english ? 1 : 0},
                onPressed: (i) => onLocale(i == 1),
              ),
              Text(
                t('interfaceHint'),
                style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ], gap: 8),
            pageStack([
              Text(
                t('themeLabel'),
                style: text.labelLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              AltButtonGroup(
                items: [
                  AltGroupItem(t('light'), icon: AltIcons.lightMode),
                  AltGroupItem(t('dark'), icon: AltIcons.darkMode),
                  AltGroupItem(t('system'), icon: AltIcons.brightnessAuto),
                ],
                selected: {
                  themeMode == ThemeMode.light
                      ? 0
                      : themeMode == ThemeMode.dark
                      ? 1
                      : 2,
                },
                onPressed: (i) => onTheme(
                  [ThemeMode.light, ThemeMode.dark, ThemeMode.system][i],
                ),
              ),
            ], gap: 8),
            pageStack([
              Text(
                t('palette'),
                style: text.labelLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              AltButtonGroup(
                items: [
                  AltGroupItem(t('amber'), key: const Key('palette-amber')),
                  AltGroupItem(
                    t('baseline'),
                    key: const Key('palette-baseline'),
                  ),
                ],
                selected: {palette.index},
                onPressed: (i) => onPalette(AppPalette.values[i]),
              ),
            ], gap: 8),
            Row(
              children: [
                Expanded(child: Text(t('reduceMotion'), style: text.bodyLarge)),
                const SizedBox(width: 16),
                Switch(
                  key: const Key('reduce-motion'),
                  value: reduceMotion,
                  onChanged: onMotion,
                ),
              ],
            ),
          ]),
          padding: const EdgeInsets.all(16),
        ),
        pagePanel(
          context,
          pageStack([
            Text(t('subtitleSize'), style: text.titleMedium),
            pagePanel(
              context,
              pageStack([
                Text(
                  t('captionPreview'),
                  style: text.bodyLarge?.copyWith(
                    fontSize: captionSize,
                    height: 1.45,
                    letterSpacing: .2,
                  ),
                ),
                Text(
                  'Make the conversation clear.',
                  style: text.bodyLarge?.copyWith(
                    fontSize: captionSize,
                    height: 1.45,
                    letterSpacing: .2,
                    fontWeight: FontWeight.w500,
                    color: colors.primary,
                  ),
                ),
              ], gap: 6),
              radius: 16,
              padding: const EdgeInsets.all(20),
              color: colors.surfaceContainerHighest,
            ),
            Row(
              children: [
                Icon(
                  AltIcons.textDecrease,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: sliderWithLocalOverlay(
                    Slider(
                      key: const Key('caption-size'),
                      value: captionSize,
                      min: 16,
                      max: 36,
                      divisions: 10,
                      label: '${captionSize.round()}',
                      onChanged: onCaptionSize,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Icon(AltIcons.textIncrease, color: colors.onSurfaceVariant),
                const SizedBox(width: 12),
                SizedBox(
                  width: 40,
                  child: Text(
                    '${captionSize.round()}px',
                    textAlign: TextAlign.right,
                    style: text.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ]),
          padding: const EdgeInsets.all(16),
        ),
      ),
      pagePanel(
        context,
        pageStack([
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(t('modelSettings'), style: text.titleMedium),
          ),
          for (final entry in [
            ('audioSettings', AltIcons.graphicEq, audioSummary, audioSettings),
            ('modelsEntry', AltIcons.memory, modelSummary, modelSettings),
            (
              'translationSettings',
              AltIcons.translate,
              llmSummary,
              translationSettings,
            ),
            (
              'contextSettings',
              AltIcons.autoFixHigh,
              live.translationContext.automatic
                  ? t('contextAuto')
                  : '${t('contextCount')}: ${live.translationContext.count}',
              contextSettings,
            ),
            (
              'floatingCaptions',
              AltIcons.subtitles,
              t('captionSettingsSummary'),
              captionSettings,
            ),
            (
              'privacy',
              AltIcons.shield,
              t('storedLocally').split('。').first,
              privacyDialog,
            ),
          ])
            ListTile(
              key: entry.$1 == 'floatingCaptions'
                  ? const Key('caption-settings')
                  : ValueKey('settings-${entry.$1}'),
              minTileHeight: 72,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(entry.$2),
              title: Text(t(entry.$1)),
              subtitle: Text(entry.$3),
              trailing: const Icon(AltIcons.chevronRight),
              onTap: entry.$4,
            ),
        ], gap: 0),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'Flutter · Material 3 Expressive · ${t('appTagline')}',
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ),
    ]);
  }
}
