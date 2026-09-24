import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/data/services/cloud/cloud_api.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:altranscribe/features/remote/remote_dialogs.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';

import 'settings_dialog.dart';
import 'cloud_key_editor.dart';

class ModelSettingsDialog extends SettingsDialog {
  const ModelSettingsDialog({
    super.key,
    required super.controller,
    required super.english,
  });
  @override
  State<ModelSettingsDialog> createState() => _ModelSettingsState();
}

class _ModelSettingsState extends SettingsDialogState<ModelSettingsDialog> {
  late bool remotePreview = controller.remoteProcessing;
  @override
  bool get canSave =>
      editable &&
      controller.updatingRecordId == null &&
      (!remotePreview || controller.remoteConnection.address.isNotEmpty);
  late SpeechProvider provider = controller.speechProvider;
  late bool direct = controller.cloudDirectTranslation;
  late bool autoLanguage = controller.cloudAutoLanguage;
  List<String>? cloudModels;
  late String? selected = ModelCatalog.models
      .where(
        (item) =>
            item.filename == controller.model.split(RegExp(r'[/\\]')).last,
      )
      .firstOrNull
      ?.id;
  late ComputeMode compute = controller.computeMode;
  late final executable = TextEditingController(text: controller.executable);
  Map<String, ModelAvailability> available = {};
  @override
  String get title => 'modelsEntry';
  @override
  void initState() {
    super.initState();
    controller.catalog.addListener(downloadChanged);
  }

  void downloadChanged() {
    if (!mounted) return;
    setState(() {});
    if (controller.catalog.downloadingModel == null) unawaited(run(load));
  }

  Future<void> download(WhisperModel model) async {
    final success = await controller.catalog.download(model);
    if (success && mounted) {
      setState(() => selected = model.id);
    }
  }

  @override
  void dispose() {
    controller.catalog.removeListener(downloadChanged);
    executable.dispose();
    super.dispose();
  }

  @override
  Future<void> load() async {
    final result = await controller.catalog.scan();
    if (mounted) setState(() => available = result);
  }

  @override
  List<Widget> contents() => [
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in [
          if (controller.localInferenceAllowed) SpeechProvider.whisper,
          null,
          SpeechProvider.openAI,
          SpeechProvider.gemini,
        ])
          ChoiceChip(
            key: Key('speech-provider-${option?.name ?? 'remote'}'),
            visualDensity: altChipDensity,
            label: Text(option?.label ?? 'Whisper Remote'),
            selected: option == null
                ? remotePreview
                : !remotePreview && provider == option,
            onSelected: editable
                ? (_) => setState(() {
                    remotePreview = option == null;
                    if (option != null) provider = option;
                    cloudModels = null;
                  })
                : null,
          ),
      ],
    ),
    gap(),
    if (remotePreview) ...[
      Text(
        t('remoteProcessingHint'),
        key: const Key('remote-connection-summary'),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          controller.remoteConnection.name.isEmpty
              ? t('noRemote')
              : controller.remoteConnection.name,
        ),
        subtitle: Text(controller.remoteConnection.address),
        trailing: const Icon(AltIcons.chevronRight),
        onTap: editable
            ? () async {
                await showDialog<void>(
                  context: context,
                  builder: (_) => RemoteConnectionDialog(
                    controller: controller,
                    english: widget.english,
                  ),
                );
                if (mounted) setState(() {});
              }
            : null,
      ),
    ] else if (provider != SpeechProvider.whisper) ...[
      Text(t('cloudAudioNotice')),
      CloudKeyEditor(
        key: ValueKey(provider.cloud),
        provider: provider.cloud,
        credentials: controller.credentials,
        english: widget.english,
        enabled: editable,
      ),
      Text(t('cloudLiveMode')),
      for (final translate in [false, true])
        CheckboxListTile(
          key: Key('cloud-live-$translate'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: direct == translate,
          title: Text(t(translate ? 'cloudDirect' : 'cloudAsr')),
          subtitle: Text(provider.liveModel(translate)),
          onChanged: editable
              ? (_) => setState(() => direct = translate)
              : null,
        ),
      Text(t('cloudDirectHint')),
      gap(),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: true,
        onChanged: null,
        title: Text(t('cloudFileModel')),
        subtitle: Text(provider.fileModel),
      ),
      Text(t('cloudFileHint')),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(t('cloudAutoLanguage')),
        subtitle: Text(t('cloudLanguageHint')),
        value: autoLanguage,
        onChanged: editable
            ? (value) => setState(() => autoLanguage = value!)
            : null,
      ),
      TextButton.icon(
        onPressed: editable
            ? () => run(() async {
                final api = CloudApi(controller.credentials);
                try {
                  final values = await api.models(provider.cloud);
                  if (mounted) setState(() => cloudModels = values);
                } finally {
                  api.close();
                }
              })
            : null,
        icon: const Icon(Icons.refresh_rounded),
        label: Text(t('cloudCheckModels')),
      ),
      if (cloudModels != null)
        for (final name in [
          provider.liveModel(false),
          provider.liveModel(true),
          provider.fileModel,
        ])
          Text(
            '$name · ${t(cloudModels!.contains(name) ? 'cloudListed' : 'cloudNotListed')}',
          ),
      Text(t('cloudAvailabilityHint')),
    ] else ...[
      Text(t('modelCatalogHint')),
      gap(),
      RadioGroup<String>(
        groupValue: selected,
        onChanged: (value) => setState(() => selected = value),
        child: choices([
          for (final model in ModelCatalog.models)
            RadioListTile<String>(
              key: Key('whisper-${model.id}'),
              contentPadding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
              minTileHeight: 56,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                model.label,
                style: const TextStyle(fontSize: 16, letterSpacing: .5),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${model.size} · ${t(controller.catalog.downloadingModel == model ? 'modelDownloading' : 'model_${(available[model.id] ?? ModelAvailability.missing).name}')}',
                    style: const TextStyle(fontSize: 14, letterSpacing: .25),
                  ),
                  if (controller.catalog.downloadingModel == model) ...[
                    LinearProgressIndicator(
                      key: const Key('model-download-progress'),
                      value: controller.catalog.receivedBytes / model.bytes,
                    ),
                    Text(
                      '${(controller.catalog.receivedBytes / 1000000).toStringAsFixed(1)} MB / ${model.size}',
                    ),
                  ],
                ],
              ),
              secondary: controller.catalog.downloadingModel == model
                  ? IconButton(
                      key: const Key('cancel-model-download'),
                      tooltip: t('cancelDownload'),
                      onPressed: controller.catalog.cancelDownload,
                      icon: const Icon(Icons.close_rounded),
                    )
                  : available[model.id] == ModelAvailability.available
                  ? null
                  : TextButton(
                      key: Key('download-${model.id}'),
                      onPressed:
                          editable &&
                              controller.catalog.downloadingModel == null
                          ? () => download(model)
                          : null,
                      child: Text(t('downloadModel')),
                    ),
              value: model.id,
              enabled:
                  editable &&
                  available[model.id] == ModelAvailability.available,
            ),
        ]),
      ),
      if (controller.catalog.downloadingModel != null)
        Text(t('modelDownloadBackground')),
      if (controller.catalog.downloadError case final downloadError?)
        Text(
          t(downloadError),
          key: const Key('model-download-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: () => run(() async {
              await Process.start('rundll32.exe', [
                'url.dll,FileProtocolHandler',
                ModelCatalog.sourceUrl,
              ]);
            }),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(t('modelSource')),
          ),
          TextButton.icon(
            onPressed: busy ? null : () => run(load),
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t('refreshModels')),
          ),
          TextButton.icon(
            onPressed: busy
                ? null
                : () => run(() async {
                    await controller.catalog.directory.create(recursive: true);
                    await Process.start('explorer.exe', [
                      controller.catalog.directory.absolute.path,
                    ]);
                  }),
            icon: const Icon(Icons.folder_open_rounded),
            label: Text(t('openModelsFolder')),
          ),
        ],
      ),
      SelectableText(
        controller.catalog.directory.path,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      gap(),
      Text(t('computeBackend')),
      const SizedBox(height: 8),
      AltButtonGroup(
        height: 32,
        items: [
          AltGroupItem(t('automatic')),
          const AltGroupItem('GPU'),
          const AltGroupItem('CPU'),
        ],
        selected: {
          [
            ComputeMode.automatic,
            ComputeMode.gpu,
            ComputeMode.cpu,
          ].indexOf(compute),
        },
        onPressed: editable
            ? (i) => setState(
                () => compute = [
                  ComputeMode.automatic,
                  ComputeMode.gpu,
                  ComputeMode.cpu,
                ][i],
              )
            : null,
      ),
      gap(),
      Text(t('gpuHint')),
      ExpansionTile(
        title: Text(t('whisperProgram')),
        children: [
          TextField(
            controller: executable,
            enabled: editable,
            decoration: const InputDecoration(labelText: 'whisper-server.exe'),
          ),
        ],
      ),
    ],
  ];
  @override
  Future<void> save() async {
    if (remotePreview) {
      final client = RemoteClient(controller.remoteConnection);
      try {
        await client.connect();
      } finally {
        client.close();
      }
      controller.useRemote = true;
      controller.speechProvider = SpeechProvider.whisper;
      await controller.saveSettings();
      return;
    }
    if (provider != SpeechProvider.whisper) {
      controller.useRemote = false;
      controller.speechProvider = provider;
      controller.cloudDirectTranslation = direct;
      controller.cloudAutoLanguage = autoLanguage;
      await controller.saveSettings();
      return;
    }
    final result = await controller.catalog.scan();
    if (selected == null || result[selected] != ModelAvailability.available) {
      throw const FormatException('whisperModelMissing');
    }
    controller.model = controller.catalog.path(
      ModelCatalog.models.firstWhere((item) => item.id == selected),
    );
    controller.useRemote = false;
    controller.computeMode = compute;
    controller.speechProvider = provider;
    controller.executable = executable.text.trim();
    await controller.saveSettings();
  }
}
