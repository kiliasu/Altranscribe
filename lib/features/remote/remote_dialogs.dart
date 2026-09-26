import 'dart:async';
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
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/qr_code.dart';

String remoteIssue(Object error, bool english) {
  final text = error.toString();
  final key =
      RegExp(r'^PlatformException\(([^,]+),').firstMatch(text)?.group(1) ??
      text.replaceFirst(RegExp(r'^(FormatException|Bad state):\s*'), '');
  return strings[key]?[english ? 1 : 0] ??
      strings['remoteUnavailable']![english ? 1 : 0];
}

/// Connects by address with a pairing code from the host's screen, a pasted
/// invite link, or a token from a host older than 0.6.2.
class RemoteConnectionDialog extends StatefulWidget {
  const RemoteConnectionDialog({
    super.key,
    required this.controller,
    required this.english,
    this.initialAddress,
  });
  final RealtimeController controller;
  final bool english;
  final String? initialAddress;
  @override
  State<RemoteConnectionDialog> createState() => _RemoteConnectionState();
}

class _RemoteConnectionState extends State<RemoteConnectionDialog> {
  late final address = TextEditingController(
    text: widget.initialAddress ?? widget.controller.remoteConnection.address,
  );
  final secret = TextEditingController();
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
      final target = address.text.trim();
      final code = secret.text.trim();
      if (target.startsWith('altranscribe://')) {
        await widget.controller.pairWithInvite(target);
      } else if (PairingInvite.codePattern.hasMatch(code)) {
        await widget.controller.pairWithHost(target, code);
      } else {
        await widget.controller.connectRemote(target, code, '');
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = remoteIssue(e, widget.english));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    address.dispose();
    secret.dispose();
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
              key: const Key('remote-address'),
              controller: address,
              enabled: editable,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: t('remoteAddress'),
                hintText: 'http://192.168.1.20:8178',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('remote-token'),
              controller: secret,
              enabled: editable,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: t('codeOrToken'),
                helperText: t('codeOrTokenHint'),
                helperMaxLines: 3,
              ),
              onSubmitted: editable ? (_) => connect() : null,
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
  Timer? clock;
  SharedHost get host => widget.controller.sharedHost;
  String t(String key) => strings[key]![widget.english ? 1 : 0];
  @override
  void initState() {
    super.initState();
    host.addListener(refresh);
    host.devices.addListener(refresh);
    // The countdown next to the code ticks once a second.
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && host.devices.pairingCode != null) setState(() {});
    });
    // Deferred: the registry notifies the Devices page, which may be building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && host.running) offerCode();
    });
    load();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  /// A code is shown while this panel is open; closing it ends the window.
  void offerCode() {
    if (host.devices.pairingCode == null) host.devices.beginPairing();
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
      if (mounted && host.running) offerCode();
    } catch (_) {
      if (mounted) setState(() => error = t('remoteHostFailed'));
    }
  }

  @override
  void dispose() {
    host.removeListener(refresh);
    host.devices.removeListener(refresh);
    clock?.cancel();
    // After this frame: listeners must not be notified while the tree is locked.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => host.devices.cancelPairing(),
    );
    name.dispose();
    port.dispose();
    super.dispose();
  }

  /// " · 3 models available" when the shared service lists more than one.
  String sharedModelCount(Object? listed) {
    final count = listed is List ? listed.length : 0;
    if (count < 2) return '';
    return widget.english ? ' · $count models available' : ' · 共 $count 个模型可选';
  }

  PairingInvite invite(String code) => PairingInvite(
    address: host.address,
    code: code,
    name: host.info['name'] as String? ?? '',
    hostId: host.devices.hostId,
  );

  Future<void> copyInvite(String code) async {
    await Clipboard.setData(
      ClipboardData(text: invite(code).toUri().toString()),
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t('copied'))));
    }
  }

  List<Widget> pairingSection(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final code = host.devices.pairingCode;
    final expiry = host.devices.pairingExpiry;
    final remaining = expiry == null
        ? Duration.zero
        : expiry.difference(DateTime.now());
    final minutes = remaining.inMinutes.clamp(0, 99);
    final seconds = (remaining.inSeconds % 60).clamp(0, 59);
    return [
      Text(t('pairDevice'), style: text.titleMedium),
      const SizedBox(height: 8),
      Text(t('pairingCodeHint')),
      const SizedBox(height: 16),
      if (code == null)
        Center(
          child: FilledButton.tonalIcon(
            onPressed: offerCode,
            icon: const Icon(AltIcons.refresh, size: 20),
            label: Text(t('newPairingCode')),
          ),
        )
      else ...[
        Center(
          child: AltQrCode(
            key: const Key('pairing-qr'),
            data: invite(code).toUri().toString(),
            size: 200,
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: SelectableText(
            '${code.substring(0, 3)} ${code.substring(3)}',
            key: const Key('pairing-code'),
            style: text.headlineMedium?.copyWith(
              letterSpacing: 6,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Center(
          child: Text(
            '${t('pairingCode')} · ${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
            style: text.bodySmall,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: host.devices.beginPairing,
              icon: const Icon(AltIcons.refresh, size: 18),
              label: Text(t('newPairingCode')),
            ),
            TextButton.icon(
              onPressed: () => copyInvite(code),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(t('copyInvite')),
            ),
          ],
        ),
      ],
      if (host.discoveryUnavailable) ...[
        const SizedBox(height: 8),
        Text(
          t('discoveryUnavailable'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    ];
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
                      ? t('llmNotShared')
                      : '${host.info['llmProvider']} · ${host.info['llmModel']}'
                            '${sharedModelCount(host.info['llmModels'])}',
                ),
                const SizedBox(height: 16),
                Text(t('remoteAddress')),
                SelectableText(host.address),
                const SizedBox(height: 20),
                ...pairingSection(context),
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
                  isThreeLine: !widget.controller.llmProvider.isCloud,
                  subtitle: Text(
                    widget.controller.llmProvider.isCloud
                        ? t('remoteLocalOnly')
                        : '${widget.controller.llmProvider.label} · ${widget.controller.translationModel}\n${t('shareTranslationHint')}',
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
