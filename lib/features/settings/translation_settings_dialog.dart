import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';

import 'settings_dialog.dart';
import 'cloud_key_editor.dart';

class TranslationSettingsDialog extends SettingsDialog {
  const TranslationSettingsDialog({
    super.key,
    required super.controller,
    required super.english,
  });
  @override
  State<TranslationSettingsDialog> createState() => _TranslationSettingsState();
}

class _TranslationSettingsState
    extends SettingsDialogState<TranslationSettingsDialog> {
  late LlmProvider provider = controller.llmProvider;
  // Phones can still reach online OpenAI-compatible services over HTTPS.
  List<LlmProvider> get providers => LlmProvider.values
      .where(
        (item) =>
            controller.localInferenceAllowed ||
            item.isCloud ||
            item == LlmProvider.openAICompatible,
      )
      .toList();
  late final address = TextEditingController(
    text: controller.translationAddress,
  );
  late String selected = controller.translationModel;
  List<String> models = [];
  bool connected = false;
  @override
  String get title => 'translationSettings';
  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  @override
  Future<void> load() async {
    if (mounted) {
      setState(() {
        connected = false;
        models = [];
      });
    }
    try {
      final result = await controller.localTranslator.models(
        address.text,
        provider: provider,
      );
      if (mounted) {
        setState(() {
          models = result;
          connected = true;
        });
      }
    } on SocketException {
      throw const FormatException('llmUnavailable');
    }
  }

  @override
  List<Widget> contents() => [
    Text(t('llmPanelHint')),
    gap(),
    AltButtonGroup(
      height: 32,
      stretch: true,
      items: [
        for (final option in providers)
          AltGroupItem(option.label, key: Key('provider-${option.name}')),
      ],
      selected: {providers.indexOf(provider)},
      onPressed: editable
          ? (i) {
              final option = providers[i];
              if (provider == option) return;
              setState(() {
                provider = option;
                address.text = option == LlmProvider.ollama
                    ? 'http://127.0.0.1:11434'
                    : 'http://127.0.0.1:1234/v1';
                selected = '';
              });
              run(load);
            }
          : null,
    ),
    if (provider == LlmProvider.openAICompatible) Text(t('compatibleProvider')),
    gap(),
    if (provider.isCloud) ...[
      Text(t('cloudTextNotice')),
      CloudKeyEditor(
        key: ValueKey(provider.cloud),
        provider: provider.cloud,
        credentials: controller.credentials,
        english: widget.english,
        enabled: editable,
        onSaved: () => run(load),
      ),
    ] else ...[
      TextField(
        key: const Key('llm-address'),
        controller: address,
        enabled: editable,
        decoration: InputDecoration(labelText: t('llmAddress')),
        onChanged: (_) => setState(() {
          connected = false;
          models = [];
        }),
      ),
      if (provider == LlmProvider.openAICompatible) ...[
        gap(),
        Text(t('compatibleKeyHint')),
        CloudKeyEditor(
          key: const ValueKey('compatible-key'),
          name: compatibleKeyName,
          label: t('compatibleKeyLabel'),
          credentials: controller.credentials,
          english: widget.english,
          enabled: editable,
          onSaved: () => run(load),
        ),
      ],
    ],
    gap(),
    Row(
      children: [
        Expanded(
          child: connected
              ? Text(
                  t(models.isEmpty ? 'llmNoModels' : 'llmConnected'),
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: Theme.of(context).colorScheme.primary),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(width: 12),
        TextButton.icon(
          onPressed: busy ? null : () => run(load),
          icon: const Icon(AltIcons.refresh, size: 18),
          label: Text(
            t(provider.isCloud ? 'cloudCheckModels' : 'loadLocalModels'),
          ),
        ),
      ],
    ),
    gap(),
    RadioGroup<String>(
      groupValue: selected,
      onChanged: (value) {
        if (value != null) setState(() => selected = value);
      },
      child: choices([
        for (final name in models)
          RadioListTile<String>(
            key: ValueKey('llm-model-$name'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            minTileHeight: 56,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              name,
              style: const TextStyle(fontSize: 16, letterSpacing: .5),
            ),
            value: name,
            enabled: editable,
          ),
      ]),
    ),
    if (connected && selected.isNotEmpty && !models.contains(selected))
      Text(t('translationModelMissing')),
  ];
  @override
  Future<void> save() async {
    final currentModels = await controller.localTranslator.models(
      address.text,
      provider: provider,
    );
    if (!currentModels.contains(selected)) {
      throw const FormatException('translationModelMissing');
    }
    controller.llmProvider = provider;
    controller.translationAddress = address.text.trim();
    controller.translationModel = selected;
    await controller.saveSettings();
  }
}
