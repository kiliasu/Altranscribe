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

  /// While a host recognizes speech, its shared text model is the default and
  /// the user's own service is an explicit alternative.
  late bool fromHost = controller.useRemoteLlm;
  bool get hostMode => controller.remoteProcessing;
  bool get usingHost => hostMode && fromHost;
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
    // The host's model needs no lookup, and a key check would only confuse.
    if (usingHost) {
      if (controller.remoteConnection.info == null) {
        await controller.probeHost(discover: false);
      }
      return;
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

  String get hostLlmText {
    final info = controller.remoteConnection.info;
    final model = controller.hostLlmModel;
    if (info == null) return t('hostLlmUnknown');
    if (model == null) return t('hostLlmNone');
    final name = controller.remoteConnection.name;
    return '${name.isEmpty ? t('noRemote') : name} · ${info['llmProvider']} · $model';
  }

  List<Widget> sourceSection() => [
    Text(t('llmSourceHint')),
    gap(),
    RadioGroup<bool>(
      groupValue: fromHost,
      onChanged: (value) {
        if (value == null || !editable || value == fromHost) return;
        setState(() => fromHost = value);
        run(load);
      },
      child: choices([
        RadioListTile<bool>(
          key: const Key('llm-source-host'),
          value: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(t('llmFromHost')),
          subtitle: Text(hostLlmText),
          enabled: editable,
        ),
        RadioListTile<bool>(
          key: const Key('llm-source-own'),
          value: false,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(t('llmOwnService')),
          subtitle: Text(t('llmOwnServiceHint')),
          enabled: editable,
        ),
      ]),
    ),
  ];

  List<Widget> ownServiceSection() => [
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
  List<Widget> contents() => [
    if (hostMode) ...[...sourceSection(), gap()],
    if (!usingHost) ...ownServiceSection(),
  ];

  @override
  Future<void> save() async {
    if (usingHost) {
      controller.useRemoteLlm = true;
      await controller.saveSettings();
      return;
    }
    final currentModels = await controller.localTranslator.models(
      address.text,
      provider: provider,
    );
    if (!currentModels.contains(selected)) {
      throw const FormatException('translationModelMissing');
    }
    controller.useRemoteLlm = fromHost;
    controller.llmProvider = provider;
    controller.translationAddress = address.text.trim();
    controller.translationModel = selected;
    await controller.saveSettings();
  }
}
