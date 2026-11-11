import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:altranscribe/shared/ui/motion.dart';
import 'package:altranscribe/shared/ui/notice.dart';

import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/shared/ui/confirmation_dialog.dart';
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
  late String? nemotronSelected = controller.nemotronModel;
  late String? transcribeSelected = controller.transcribeModel;

  /// Run the local text model beside Transcribe in live sessions anyway.
  late bool keepLocal = controller.liveLocalLlm;

  /// The choice that stands for a program of one's own, given by its path.
  static const customProgram = 'custom';

  /// What a program path stands for among the choices: the download it
  /// belongs to, one's own program, or nothing yet.
  String? programChoice(String path) =>
      controller.catalog.programAt(path)?.id ??
      (path.isEmpty ? null : customProgram);

  /// The program each engine runs: a download by its id, or
  /// [customProgram] with the path typed under it.
  late String? whisperProgram = programChoice(controller.executable);
  late String? transcribeChoice = programChoice(
    controller.transcribeExecutable,
  );
  late final transcribeProgram = TextEditingController(
    text: transcribeChoice == customProgram
        ? controller.transcribeExecutable
        : '',
  );
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
  late final executable = TextEditingController(
    text: whisperProgram == customProgram ? controller.executable : '',
  );
  Map<String, ModelAvailability> available = {};
  @override
  String get title => 'modelsEntry';
  @override
  void initState() {
    super.initState();
    controller.catalog.addListener(downloadChanged);
    controller.addListener(programsChanged);
  }

  /// A download that finishes is put to use where its engine had no
  /// program, whichever panel started it. Where nothing was chosen here,
  /// that program becomes the choice.
  void programsChanged() {
    if (!mounted) return;
    final whisper = whisperProgram ?? programChoice(controller.executable);
    final transcribe =
        transcribeChoice ?? programChoice(controller.transcribeExecutable);
    if (whisper != whisperProgram || transcribe != transcribeChoice) {
      setState(() {
        whisperProgram = whisper;
        transcribeChoice = transcribe;
      });
    }
  }

  void downloadChanged() {
    if (!mounted) return;
    setState(() {});
    if (controller.catalog.downloadingModel == null) unawaited(run(load));
  }

  Future<void> download(SpeechModel model) async {
    // A second tap in the same frame finds the first download already running.
    if (controller.catalog.downloadingModel != null) return;
    final success = await controller.downloadModel(
      model,
      english: widget.english,
    );
    if (success && mounted) {
      setState(() {
        if (model is NemotronModel) {
          nemotronSelected = model.id;
        } else if (model is TranscribeModel) {
          transcribeSelected = model.id;
        } else if (model is ProgramPackage) {
          if (model.engine == ProgramEngine.whisper) {
            whisperProgram = model.id;
          } else {
            transcribeChoice = model.id;
          }
        } else {
          selected = model.id;
        }
      });
    }
  }

  Future<void> remove(SpeechModel model) async {
    final program = model is ProgramPackage;
    if (!await confirmRemoval(
      context,
      widget.english,
      program ? 'removeProgram' : 'removeModel',
      '${model.label}\n${model.size}\n\n'
          '${t(program ? 'removeProgramHint' : 'removeModelHint')}',
      'confirm-remove-model',
    )) {
      return;
    }
    await run(() async {
      await controller.removeModel(model);
      await load();
      bool ready(String? id) =>
          id != null && available[id] == ModelAvailability.available;
      if (!mounted) return;
      // A removed choice falls back to what the app now uses, if anything.
      setState(() {
        if (!ready(nemotronSelected)) {
          nemotronSelected = ready(controller.nemotronModel)
              ? controller.nemotronModel
              : null;
        }
        if (!ready(transcribeSelected)) transcribeSelected = null;
        if (!ready(selected)) {
          selected = ModelCatalog.models
              .where(
                (item) =>
                    controller.model == controller.catalog.path(item) &&
                    ready(item.id),
              )
              .firstOrNull
              ?.id;
        }
        // A removed program leaves the choice with what the engine now
        // runs; a path of one's own is not touched.
        if (whisperProgram != customProgram && !ready(whisperProgram)) {
          whisperProgram = programChoice(controller.executable);
        }
        if (transcribeChoice != customProgram && !ready(transcribeChoice)) {
          transcribeChoice = programChoice(controller.transcribeExecutable);
        }
      });
    });
  }

  @override
  void dispose() {
    controller.catalog.removeListener(downloadChanged);
    controller.removeListener(programsChanged);
    executable.dispose();
    transcribeProgram.dispose();
    super.dispose();
  }

  @override
  Future<void> load() async {
    final result = await controller.catalog.scan();
    if (mounted) setState(() => available = result);
  }

  /// One radio tile per model or program with size, state, download
  /// progress and the license it is offered under. [more] are further
  /// choices of the same group, shown after them.
  List<Widget> modelTiles(
    List<SpeechModel> models,
    String keyPrefix,
    String? value,
    ValueChanged<String?> onChanged, {
    List<Widget> more = const [],
  }) {
    final catalog = controller.catalog;
    final waiting =
        catalog.downloadStage == DownloadStage.retrying ||
        (catalog.downloadStage == DownloadStage.connecting &&
            catalog.receivedBytes == 0);
    // A program is unpacked once it has arrived.
    final unpacking = catalog.downloadStage == DownloadStage.installing;
    return [
      RadioGroup<String>(
        groupValue: value,
        onChanged: onChanged,
        child: choices([
          for (final model in models)
            RadioListTile<String>(
              key: Key('$keyPrefix-${model.id}'),
              contentPadding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
              minTileHeight: 56,
              controlAffinity: ListTileControlAffinity.leading,
              // The builds of one program differ in what they run on; the
              // program and its release stand with the license.
              title: Text(
                model is ProgramPackage ? model.variant : model.label,
                style: const TextStyle(fontSize: 16, letterSpacing: .5),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${model.size} · ${t(controller.catalog.downloadingModel == model ? 'modelDownloading' : 'model_${(available[model.id] ?? ModelAvailability.missing).name}')}',
                    style: const TextStyle(fontSize: 14, letterSpacing: .25),
                  ),
                  if (model is FolderModel)
                    Text(
                      '${t('modelLicense')}: ${model.licenseName}',
                      style: const TextStyle(fontSize: 12, letterSpacing: .25),
                    ),
                  if (model is ProgramPackage)
                    Text(
                      '${model.name} ${model.version} · ${model.licenseName}',
                      style: const TextStyle(fontSize: 12, letterSpacing: .25),
                    ),
                  if (catalog.downloadingModel == model) ...[
                    LinearProgressIndicator(
                      key: const Key('model-download-progress'),
                      value: waiting
                          ? null
                          : unpacking
                          ? catalog.installProgress
                          : catalog.receivedBytes / model.bytes,
                    ),
                    Text(
                      catalog.downloadStage == DownloadStage.retrying
                          ? t('modelRetrying')
                          : waiting
                          ? t('modelConnecting')
                          : unpacking
                          ? t('programUnpacking')
                          : '${(catalog.receivedBytes / 1000000).toStringAsFixed(1)} MB / ${model.size}',
                    ),
                  ],
                ],
              ),
              // The tile merges its semantics; the tooltip's overlay has to stay
              // inside the button, or its node is sent detached from the tree.
              secondary: catalog.downloadingModel == model
                  ? withLocalOverlay(
                      IconButton(
                        key: const Key('cancel-model-download'),
                        tooltip: t('cancelDownload'),
                        onPressed: catalog.cancelDownload,
                        icon: const Icon(AltIcons.close),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (available[model.id] != ModelAvailability.available)
                          TextButton(
                            key: Key('download-${model.id}'),
                            onPressed:
                                editable && catalog.downloadingModel == null
                                ? () => download(model)
                                : null,
                            child: Text(t('downloadModel')),
                          ),
                        // Downloaded and partial files can both be removed.
                        if ((available[model.id] ??
                                ModelAvailability.missing) !=
                            ModelAvailability.missing)
                          withLocalOverlay(
                            IconButton(
                              key: Key('remove-${model.id}'),
                              tooltip: t(
                                model is ProgramPackage
                                    ? 'removeProgram'
                                    : 'removeModel',
                              ),
                              onPressed: editable ? () => remove(model) : null,
                              icon: const Icon(AltIcons.delete),
                            ),
                          ),
                      ],
                    ),
              value: model.id,
              enabled:
                  editable &&
                  available[model.id] == ModelAvailability.available,
            ),
          ...more,
        ]),
      ),
      // What a download says is said under the list it belongs to.
      if (models.contains(catalog.downloadingModel)) ...[
        const SizedBox(height: 8),
        Text(t('modelDownloadBackground')),
      ],
      if (catalog.downloadError case final downloadError?
          when models.contains(catalog.lastDownload)) ...[
        const SizedBox(height: 8),
        AltNotice.error(
          t(downloadError),
          key: const Key('model-download-error'),
        ),
      ],
    ];
  }

  /// The programs an engine can run: the published builds, downloaded and
  /// removed like models, and one's own by its path. The path is asked for
  /// while that is the choice.
  List<Widget> programTiles(
    ProgramEngine engine,
    String title,
    String? value,
    ValueChanged<String?> onChanged,
    TextEditingController path,
    String fileName,
  ) {
    final packages = controller.catalog.programsFor(engine);
    return [
      Text(title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      ...modelTiles(
        packages,
        'program',
        value,
        onChanged,
        more: [
          RadioListTile<String>(
            key: const Key('program-custom'),
            contentPadding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
            minTileHeight: 56,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              t('programCustom'),
              style: const TextStyle(fontSize: 16, letterSpacing: .5),
            ),
            value: customProgram,
            enabled: editable,
          ),
          AltReveal(
            child: value == customProgram
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: TextField(
                      key: const Key('program-path'),
                      controller: path,
                      enabled: editable,
                      decoration: InputDecoration(labelText: fileName),
                    ),
                  )
                : null,
          ),
        ],
      ),
      if (packages.isNotEmpty)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const Key('program-source'),
            onPressed: () => run(() async {
              await Process.start('rundll32.exe', [
                'url.dll,FileProtocolHandler',
                packages.first.sourceUrl,
              ]);
            }),
            icon: const Icon(AltIcons.openInNew),
            label: Text(t('modelSource')),
          ),
        ),
    ];
  }

  /// The path of the program chosen for an engine: the executable of the
  /// download, or what was typed. With nothing chosen, the engine keeps
  /// the program it has, [current].
  String chosenProgram(
    String? choice,
    TextEditingController path,
    String current,
  ) => choice == null
      ? current
      : choice == customProgram
      ? path.text.trim()
      : controller.catalog.packages
                .where((package) => package.id == choice)
                .map(controller.catalog.programPath)
                .firstOrNull ??
            '';

  /// Links to the model source, a rescan and the folder on disk.
  Widget folderRow({String? sourceUrl}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        children: [
          if (sourceUrl != null)
            TextButton.icon(
              onPressed: () => run(() async {
                await Process.start('rundll32.exe', [
                  'url.dll,FileProtocolHandler',
                  sourceUrl,
                ]);
              }),
              icon: const Icon(AltIcons.openInNew),
              label: Text(t('modelSource')),
            ),
          TextButton.icon(
            onPressed: busy ? null : () => run(load),
            icon: const Icon(AltIcons.refresh),
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
            icon: const Icon(AltIcons.folderOpen),
            label: Text(t('openModelsFolder')),
          ),
        ],
      ),
      SelectableText(
        controller.catalog.directory.path,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );

  /// Engines in display order; null stands for a remote Windows host.
  List<SpeechProvider?> get speechOptions => [
    if (controller.localInferenceAllowed) SpeechProvider.whisper,
    SpeechProvider.nemotron,
    if (controller.localInferenceAllowed) SpeechProvider.transcribe,
    null,
    SpeechProvider.openAI,
    SpeechProvider.gemini,
  ];

  @override
  List<Widget> contents() => [
    // One engine is chosen, so this is the app's single-choice button group,
    // as in the translation settings, not filter chips whose check mark
    // slides in and reflows the row.
    AltButtonGroup(
      key: const Key('speech-providers'),
      height: 32,
      stretch: true,
      items: [
        for (final option in speechOptions)
          AltGroupItem(
            option?.label ?? 'Whisper · Remote',
            key: Key('speech-provider-${option?.name ?? 'remote'}'),
          ),
      ],
      selected: {speechOptions.indexOf(remotePreview ? null : provider)},
      onPressed: editable
          ? (i) {
              final option = speechOptions[i];
              if (option == null
                  ? remotePreview
                  : !remotePreview && provider == option) {
                return;
              }
              setState(() {
                remotePreview = option == null;
                if (option != null) provider = option;
                cloudModels = null;
              });
            }
          : null,
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
                await showAltDialog<void>(
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
    ] else if (provider == SpeechProvider.nemotron) ...[
      Text(t('nemotronHint')),
      gap(),
      ...modelTiles(
        ModelCatalog.nemotronModels,
        'nemotron',
        nemotronSelected,
        (value) => setState(() => nemotronSelected = value),
      ),
      if (!MobilePlatform.android) ...[gap(), folderRow()],
    ] else if (provider == SpeechProvider.transcribe) ...[
      Text(t('transcribeHint')),
      gap(),
      ...modelTiles(
        ModelCatalog.transcribeModels,
        'transcribe',
        transcribeSelected,
        (value) => setState(() => transcribeSelected = value),
      ),
      folderRow(sourceUrl: ModelCatalog.transcribeModels.first.sourceUrl),
      gap(),
      ...programTiles(
        ProgramEngine.transcribe,
        t('transcribeProgram'),
        transcribeChoice,
        (value) => setState(() => transcribeChoice = value),
        transcribeProgram,
        'nemo-speech.exe',
      ),
      // A local text model and Transcribe do not fit in the GPU together.
      if (controller.llmLocal) ...[
        gap(),
        Text(
          t('transcribeLiveTitle'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        RadioGroup<bool>(
          groupValue: keepLocal,
          onChanged: (value) {
            if (value != null && editable) setState(() => keepLocal = value);
          },
          child: choices([
            RadioListTile<bool>(
              key: const Key('live-llm-after-stop'),
              value: false,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(t('llmTranslateAfterStop')),
              enabled: editable,
            ),
            RadioListTile<bool>(
              key: const Key('live-llm-local'),
              value: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(t('liveRunLocal')),
              subtitle: Text(t('llmSharesGpu')),
              enabled: editable,
            ),
          ]),
        ),
      ],
    ] else if (provider.isCloud) ...[
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
        icon: const Icon(AltIcons.refresh),
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
      ...modelTiles(
        ModelCatalog.models,
        'whisper',
        selected,
        (value) => setState(() => selected = value),
      ),
      folderRow(sourceUrl: ModelCatalog.sourceUrl),
      gap(),
      ...programTiles(
        ProgramEngine.whisper,
        t('whisperProgram'),
        whisperProgram,
        (value) => setState(() => whisperProgram = value),
        executable,
        'whisper-server.exe',
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
    if (provider == SpeechProvider.nemotron) {
      final result = await controller.catalog.scan();
      final chosen = nemotronSelected;
      if (chosen == null || result[chosen] != ModelAvailability.available) {
        throw const FormatException('nemotronModelMissing');
      }
      controller.nemotronModel = chosen;
      controller.useRemote = false;
      controller.speechProvider = provider;
      await controller.saveSettings();
      return;
    }
    if (provider == SpeechProvider.transcribe) {
      final result = await controller.catalog.scan();
      final chosen = transcribeSelected;
      if (chosen == null || result[chosen] != ModelAvailability.available) {
        throw const FormatException('transcribeModelMissing');
      }
      final program = chosenProgram(
        transcribeChoice,
        transcribeProgram,
        controller.transcribeExecutable,
      );
      if (!File(program).existsSync()) {
        throw const FormatException('transcribeProgramMissing');
      }
      controller.transcribeModel = chosen;
      controller.transcribeExecutable = program;
      controller.liveLocalLlm = keepLocal;
      controller.useRemote = false;
      controller.speechProvider = provider;
      await controller.saveSettings();
      return;
    }
    if (provider.isCloud) {
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
    // A path that was typed has to lead somewhere; with no program chosen
    // yet, the start page says so and leads back here.
    final program = chosenProgram(
      whisperProgram,
      executable,
      controller.executable,
    );
    if (whisperProgram == customProgram && !File(program).existsSync()) {
      throw const FormatException('whisperProgramMissing');
    }
    controller.model = controller.catalog.path(
      ModelCatalog.models.firstWhere((item) => item.id == selected),
    );
    controller.useRemote = false;
    controller.computeMode = compute;
    controller.speechProvider = provider;
    controller.executable = program;
    await controller.saveSettings();
  }
}
