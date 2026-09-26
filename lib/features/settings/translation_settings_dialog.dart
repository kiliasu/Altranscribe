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

  /// With a host saved, its shared text model and the user's own service
  /// are the two sources, whichever engine recognizes speech.
  late bool fromHost = controller.hostLlm;

  /// One of the host's listed models; empty follows the host's default.
  late String hostModel = controller.remoteLlmModel;
  bool get hostMode => controller.remoteConnection.address.isNotEmpty;
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

  /// A running summary task keeps its service; changing sources must wait.
  @override
  bool get canSave => editable && controller.updatingRecordId == null;
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
    return '${name.isEmpty ? t('noRemote') : name} · ${info['llmProvider']}';
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
    if (usingHost && controller.hostLlmModels.isNotEmpty) ...[
      gap(),
      Row(
        children: [
          Expanded(
            child: Text(
              t('hostModels'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          TextButton.icon(
            key: const Key('refresh-host-models'),
            onPressed: busy
                ? null
                : () => run(() => controller.probeHost(discover: false)),
            icon: const Icon(AltIcons.refresh, size: 18),
            label: Text(t('refreshHostModels')),
          ),
        ],
      ),
      RadioGroup<String>(
        groupValue: hostModel.isEmpty
            ? controller.hostLlmModel ?? ''
            : hostModel,
        onChanged: (value) {
          if (value == null || !editable) return;
          setState(
            () => hostModel = value == controller.hostLlmModel ? '' : value,
          );
        },
        child: choices([
          for (final name in controller.hostLlmModels)
            RadioListTile<String>(
              key: ValueKey('host-model-$name'),
              value: name,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              minTileHeight: 56,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                name,
                style: const TextStyle(fontSize: 16, letterSpacing: .5),
              ),
              subtitle: name == controller.hostLlmModel
                  ? Text(t('hostDefaultModel'))
                  : null,
              enabled: editable,
            ),
        ]),
      ),
    ],
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
      if (hostModel.isNotEmpty &&
          !controller.hostLlmModels.contains(hostModel)) {
        throw const FormatException('remoteLlmModelMissing');
      }
      controller.hostLlm = true;
      controller.remoteLlmModel = hostModel;
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
    controller.hostLlm = fromHost;
    controller.llmProvider = provider;
    controller.translationAddress = address.text.trim();
    controller.translationModel = selected;
    await controller.saveSettings();
  }
}
