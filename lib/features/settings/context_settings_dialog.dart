import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';

import 'settings_dialog.dart';

class ContextSettingsDialog extends SettingsDialog {
  const ContextSettingsDialog({
    super.key,
    required super.controller,
    required super.english,
  });
  @override
  State<ContextSettingsDialog> createState() => _ContextSettingsState();
}

class _ContextSettingsState extends SettingsDialogState<ContextSettingsDialog> {
  late bool automaticContext = controller.translationContext.automatic;
  late int contextCount = controller.translationContext.count;
  @override
  String get title => 'contextSettings';
  @override
  Future<void> load() async {}
  @override
  List<Widget> contents() => [
    Text(
      t('translationContext'),
      style: Theme.of(context).textTheme.titleMedium,
    ),
    Text(t('translationContextHint')),
    SwitchListTile(
      key: const Key('context-auto'),
      contentPadding: EdgeInsets.zero,
      title: Text(t('contextAuto')),
      subtitle: Text(t('contextAutoHint')),
      value: automaticContext,
      onChanged: editable
          ? (value) => setState(() => automaticContext = value)
          : null,
    ),
    if (!automaticContext) ...[
      Text('${t('contextCount')}: $contextCount'),
      sliderWithLocalOverlay(
        Slider(
          key: const Key('context-count'),
          value: contextCount.toDouble(),
          min: 0,
          max: 20,
          divisions: 20,
          label: '$contextCount',
          onChanged: editable
              ? (value) => setState(() => contextCount = value.round())
              : null,
        ),
      ),
    ],
  ];
  @override
  Future<void> save() async {
    controller.translationContext = TranslationContextPolicy(
      automatic: automaticContext,
      count: contextCount,
    );
    await controller.saveSettings();
  }
}
