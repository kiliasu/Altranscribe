import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/data/models/caption_preferences.dart';

import 'settings_dialog.dart';

class CaptionSettingsDialog extends SettingsDialog {
  const CaptionSettingsDialog({
    super.key,
    required super.controller,
    required super.english,
  });
  @override
  State<CaptionSettingsDialog> createState() => _CaptionSettingsState();
}

class _CaptionSettingsState extends SettingsDialogState<CaptionSettingsDialog> {
  late CaptionPreferences value = controller.captionPreferences;
  @override
  bool get allowDuringSession => true;
  @override
  String get title => 'floatingCaptions';
  @override
  Future<void> load() async {}
  @override
  Future<void> save() => controller.setCaptionPreferences(value);
  @override
  List<Widget> contents() => [
    Text(t('captionSettingsHint')),
    gap(),
    Text('${t('captionSentences')}: ${value.sentences}'),
    sliderWithLocalOverlay(
      Slider(
        key: const Key('caption-sentences'),
        value: value.sentences.toDouble(),
        min: 1,
        max: 8,
        divisions: 7,
        label: '${value.sentences}',
        onChanged: editable
            ? (n) =>
                  setState(() => value = value.copyWith(sentences: n.round()))
            : null,
      ),
    ),
    CheckboxListTile(
      key: const Key('caption-original'),
      contentPadding: EdgeInsets.zero,
      title: Text(t('captionOriginal')),
      value: value.original,
      onChanged: editable && (!value.original || value.translation)
          ? (on) => setState(() => value = value.copyWith(original: on))
          : null,
    ),
    CheckboxListTile(
      key: const Key('caption-translation'),
      contentPadding: EdgeInsets.zero,
      title: Text(t('captionTranslation')),
      value: value.translation,
      onChanged: editable && (!value.translation || value.original)
          ? (on) => setState(() => value = value.copyWith(translation: on))
          : null,
    ),
    gap(),
    Text('${t('captionOpacity')}: ${(value.opacity * 100).round()}%'),
    sliderWithLocalOverlay(
      Slider(
        key: const Key('caption-opacity'),
        value: value.opacity,
        min: .4,
        max: 1,
        label: '${(value.opacity * 100).round()}%',
        onChanged: editable
            ? (n) => setState(() => value = value.copyWith(opacity: n))
            : null,
      ),
    ),
    Text('${t('subtitleSize')}: ${value.fontSize.round()}'),
    sliderWithLocalOverlay(
      Slider(
        key: const Key('caption-font-size'),
        value: value.fontSize,
        min: 14,
        max: 48,
        divisions: 17,
        label: '${value.fontSize.round()}',
        onChanged: editable
            ? (n) => setState(() => value = value.copyWith(fontSize: n))
            : null,
      ),
    ),
    DropdownButtonFormField<String>(
      key: const Key('caption-font'),
      initialValue: value.font,
      decoration: InputDecoration(labelText: t('captionFont')),
      items: [
        for (final font in CaptionPreferences.fonts)
          DropdownMenuItem(
            value: font,
            child: Text(switch (font) {
              'RobotoFlex' => 'Roboto Flex',
              'NotoSansSC' => 'Noto Sans SC',
              _ => font,
            }),
          ),
      ],
      onChanged: editable
          ? (font) => setState(() => value = value.copyWith(font: font))
          : null,
    ),
    gap(),
    Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        t('captionSample'),
        style: TextStyle(
          fontFamily: value.font,
          fontFamilyFallback: const ['NotoSansSC'],
          fontSize: value.fontSize,
          height: 1.4,
        ),
      ),
    ),
  ];
}
