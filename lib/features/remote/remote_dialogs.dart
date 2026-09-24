import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:altranscribe/data/services/remote/shared_host.dart';

String remoteIssue(Object error, bool english) {
  final key = error.toString().replaceFirst(
    RegExp(r'^(FormatException|Bad state):\s*'),
    '',
  );
  return strings[key]?[english ? 1 : 0] ??
      strings['remoteUnavailable']![english ? 1 : 0];
}

class RemoteConnectionDialog extends StatefulWidget {
  const RemoteConnectionDialog({
    super.key,
    required this.controller,
    required this.english,
  });
  final RealtimeController controller;
  final bool english;
  @override
  State<RemoteConnectionDialog> createState() => _RemoteConnectionState();
}

class _RemoteConnectionState extends State<RemoteConnectionDialog> {
  late final name = TextEditingController(
    text: widget.controller.remoteConnection.name,
  );
  late final address = TextEditingController(
    text: widget.controller.remoteConnection.address,
  );
  late final token = TextEditingController(
    text: widget.controller.remoteConnection.token,
  );
  bool busy = false;
  String? error;
  String t(String key) => strings[key]![widget.english ? 1 : 0];
  bool get editable =>
      !busy &&
      !widget.controller.active &&
      widget.controller.updatingRecordId == null;
  Future<void> connect() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.controller.connectRemote(
        address.text,
        token.text,
        name.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = remoteIssue(e, widget.english));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    name.dispose();
    address.dispose();
    token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('connectHost')),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('remoteProcessingHint')),
            const SizedBox(height: 16),
            TextField(
              key: const Key('remote-name'),
              controller: name,
              enabled: editable,
              maxLength: 80,
              decoration: InputDecoration(labelText: t('deviceName')),
            ),
            TextField(
              key: const Key('remote-address'),
              controller: address,
              enabled: editable,
              decoration: InputDecoration(
                labelText: t('remoteAddress'),
                hintText: 'http://192.168.1.20:8178',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('remote-token'),
              controller: token,
              enabled: editable,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: t('pairingToken')),
            ),
            const SizedBox(height: 16),
            Text(t('remoteNetworkHint')),
            if (!editable && !busy) Text(t('settingsLocked')),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(t('cancel')),
      ),
      FilledButton(
        key: const Key('connect-remote'),
        onPressed: editable ? connect : null,
        child: Text(t('connectAndUse')),
      ),
    ],
  );
}

class SharedHostDialog extends StatefulWidget {
  const SharedHostDialog({
    super.key,
    required this.controller,
    required this.english,
  });
  final RealtimeController controller;
  final bool english;
  @override
  State<SharedHostDialog> createState() => _SharedHostState();
}

class _SharedHostState extends State<SharedHostDialog> {
  final name = TextEditingController(text: Platform.localHostname);
  final port = TextEditingController(text: '8178');
  List<(String, InternetAddress)> addresses = [];
  String? selectedAddress;
  String? model;
  List<WhisperModel> models = [];
  late ComputeMode compute = widget.controller.computeMode;
  late bool translation =
      !widget.controller.llmProvider.isCloud &&
      widget.controller.translationModel.isNotEmpty;
  bool loading = true;
  String? error;
  SharedHost get host => widget.controller.sharedHost;
  String t(String key) => strings[key]![widget.english ? 1 : 0];
  @override
  void initState() {
    super.initState();
    host.addListener(refresh);
    load();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> load() async {
    try {
      final found = await sharingAddresses();
      final available = await widget.controller.catalog.scan();
      if (!mounted) return;
      setState(() {
        addresses = found;
        selectedAddress = found.firstOrNull?.$2.address;
        models = ModelCatalog.models
            .where((item) => available[item.id] == ModelAvailability.available)
            .toList();
        model =
            models
                .where(
                  (item) => widget.controller.model.endsWith(item.filename),
                )
                .firstOrNull
                ?.id ??
            models.firstOrNull?.id;
      });
    } catch (e) {
      if (mounted) setState(() => error = remoteIssue(e, widget.english));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> start() async {
    final selectedPort = int.tryParse(port.text);
    if (selectedPort == null || selectedPort < 1 || selectedPort > 65535) {
      setState(() => error = t('remotePortInvalid'));
      return;
    }
    setState(() => error = null);
    try {
      final controller = widget.controller;
      await host.start(
        bindAddress: addresses
            .firstWhere((item) => item.$2.address == selectedAddress)
            .$2,
        port: selectedPort,
        name: name.text,
        executable: controller.executable,
        model: controller.catalog.path(
          models.firstWhere((item) => item.id == model),
        ),
        compute: compute,
        directory: controller.store.directory,
        shareTranslation: translation,
        llmProvider: controller.llmProvider,
        llmAddress: controller.translationAddress,
        llmModel: controller.translationModel,
      );
    } catch (_) {
      if (mounted) setState(() => error = t('remoteHostFailed'));
    }
  }

  @override
  void dispose() {
    host.removeListener(refresh);
    name.dispose();
    port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editable = !loading && !host.busy && !host.running;
    return AlertDialog(
      title: Text(t('shareLocalModels')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t('shareLocalHint')),
              const SizedBox(height: 16),
              if (host.running) ...[
                Text('${host.info['model']} · ${host.info['backend']}'),
                Text(
                  host.info['llmModel'] == null
                      ? t('remoteLlmUnavailable')
                      : '${host.info['llmProvider']} · ${host.info['llmModel']}',
                ),
                const SizedBox(height: 16),
                Text(t('remoteAddress')),
                SelectableText(host.address),
                const SizedBox(height: 12),
                Text(t('pairingToken')),
                Row(
                  children: [
                    Expanded(child: SelectableText(host.token)),
                    IconButton(
                      tooltip: t('copy'),
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: host.token)),
                      icon: const Icon(Icons.copy_rounded),
                    ),
                  ],
                ),
                Text(t('pairingTokenHint')),
              ] else ...[
                TextField(
                  controller: name,
                  enabled: editable,
                  maxLength: 80,
                  decoration: InputDecoration(labelText: t('deviceName')),
                ),
                DropdownButtonFormField<String>(
                  initialValue: selectedAddress,
                  key: ValueKey(selectedAddress),
                  isExpanded: true,
                  decoration: InputDecoration(labelText: t('sharingNetwork')),
                  items: [
                    for (final item in addresses)
                      DropdownMenuItem(
                        value: item.$2.address,
                        child: Text(
                          '${item.$1} · ${item.$2.address}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: editable
                      ? (value) => setState(() => selectedAddress = value)
                      : null,
                ),
                if (!loading && addresses.isEmpty) Text(t('remoteNoNetwork')),
                const SizedBox(height: 12),
                TextField(
                  controller: port,
                  enabled: editable,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t('sharingPort')),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: model,
                  key: ValueKey('host-model-$model'),
                  decoration: InputDecoration(labelText: t('modelsEntry')),
                  items: [
                    for (final item in models)
                      DropdownMenuItem(value: item.id, child: Text(item.label)),
                  ],
                  onChanged: editable
                      ? (value) => setState(() => model = value)
                      : null,
                ),
                if (!loading && models.isEmpty) Text(t('whisperModelMissing')),
                const SizedBox(height: 12),
                DropdownButtonFormField<ComputeMode>(
                  initialValue: compute,
                  decoration: InputDecoration(labelText: t('computeBackend')),
                  items: [
                    for (final value in ComputeMode.values)
                      DropdownMenuItem(
                        value: value,
                        child: Text(
                          value == ComputeMode.automatic
                              ? t('automatic')
                              : value.name.toUpperCase(),
                        ),
                      ),
                  ],
                  onChanged: editable
                      ? (value) => setState(() => compute = value!)
                      : null,
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('shareTranslation')),
                  subtitle: Text(
                    widget.controller.llmProvider.isCloud
                        ? t('remoteLocalOnly')
                        : '${widget.controller.llmProvider.label} · ${widget.controller.translationModel}',
                  ),
                  value: translation,
                  onChanged:
                      editable &&
                          !widget.controller.llmProvider.isCloud &&
                          widget.controller.translationModel.isNotEmpty
                      ? (value) => setState(() => translation = value!)
                      : null,
                ),
              ],
              const SizedBox(height: 16),
              Text(t('remoteNetworkHint')),
              if (loading || host.busy) const LinearProgressIndicator(),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('done')),
        ),
        if (host.running)
          FilledButton(
            onPressed: host.busy ? null : () => host.stop(),
            child: Text(t('stopSharing')),
          )
        else
          FilledButton(
            key: const Key('start-sharing'),
            onPressed: editable && model != null && selectedAddress != null
                ? start
                : null,
            child: Text(t('startSharing')),
          ),
      ],
    );
  }
}
