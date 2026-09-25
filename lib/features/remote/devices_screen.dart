import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/data/services/remote/discovery.dart';
import 'package:altranscribe/data/services/remote/paired_devices.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/confirmation_dialog.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/features/remote/remote_dialogs.dart';

import 'package:altranscribe/shared/ui/page_layout.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.live, required this.english});
  final RealtimeController live;
  final bool english;
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  /// Null until the first search; empty when nothing answered.
  List<DiscoveredHost>? nearby;
  bool searching = false;
  bool pairing = false;
  String? issue;
  RealtimeController get live => widget.live;
  bool get english => widget.english;
  String t(String key) => strings[key]![english ? 1 : 0];

  @override
  void initState() {
    super.initState();
    live.watchHost(true);
    live.sharedHost.devices.addListener(refresh);
    // A phone looks around as soon as the page opens; a computer on request.
    if (MobilePlatform.android) unawaited(search());
  }

  @override
  void dispose() {
    live.watchHost(false);
    live.sharedHost.devices.removeListener(refresh);
    super.dispose();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  void snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> search() async {
    if (searching) return;
    setState(() => searching = true);
    try {
      final found = await live.findHosts();
      if (mounted) setState(() => nearby = found);
    } catch (_) {
      if (mounted) setState(() => nearby = []);
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  Future<void> scan() async {
    setState(() {
      pairing = true;
      issue = null;
    });
    try {
      final text = await MobilePlatform.scanQr(t('scanHint'));
      if (text == null) return;
      await live.pairWithInvite(text);
      if (mounted) snack('${t('pairedWith')} ${live.remoteConnection.name}');
    } catch (e) {
      if (mounted) setState(() => issue = remoteIssue(e, english));
    } finally {
      if (mounted) setState(() => pairing = false);
    }
  }

  Future<void> manual([String? address]) async {
    final paired = await showDialog<bool>(
      context: context,
      builder: (_) => RemoteConnectionDialog(
        controller: live,
        english: english,
        initialAddress: address,
      ),
    );
    if (paired == true && mounted) {
      snack('${t('pairedWith')} ${live.remoteConnection.name}');
    }
  }

  Future<void> sharingDialog() => showDialog<void>(
    context: context,
    builder: (_) => SharedHostDialog(controller: live, english: english),
  );

  Future<void> forget() async {
    if (!await confirmRemoval(
      context,
      english,
      'forgetHost',
      t('forgetHostHint'),
      'confirm-forget-host',
    )) {
      return;
    }
    try {
      await live.forgetHost();
    } catch (e) {
      if (mounted) snack(remoteIssue(e, english));
    }
  }

  Future<void> revoke(PairedDevice device) async {
    if (!await confirmRemoval(
      context,
      english,
      'removeDevice',
      '${device.name} · ${t('removeDeviceHint')}',
      'confirm-remove-device',
    )) {
      return;
    }
    await live.sharedHost.devices.revoke(device.id);
  }

  String seenText(DateTime? seen) {
    if (seen == null) return t('neverConnected');
    final elapsed = DateTime.now().difference(seen);
    if (elapsed.inMinutes < 1) return t('seenJustNow');
    if (elapsed.inHours < 1) {
      return english
          ? 'Seen ${elapsed.inMinutes} min ago'
          : '${elapsed.inMinutes} 分钟前在线';
    }
    if (elapsed.inDays < 1) {
      return english
          ? 'Seen ${elapsed.inHours} h ago'
          : '${elapsed.inHours} 小时前在线';
    }
    return english ? 'Seen ${elapsed.inDays} d ago' : '${elapsed.inDays} 天前在线';
  }

  String statusText(HostStatus status) => t(switch (status) {
    HostStatus.online => 'hostOnline',
    HostStatus.busy => 'hostBusy',
    HostStatus.offline => 'hostOffline',
    HostStatus.unknown => 'hostUnknown',
  });

  Color statusColor(ColorScheme colors, HostStatus status) => switch (status) {
    HostStatus.online => colors.primary,
    HostStatus.busy => colors.tertiary,
    HostStatus.offline => colors.error,
    HostStatus.unknown => colors.onSurfaceVariant,
  };

  Widget localCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final sharing = live.sharedHost.running;
    return pagePanel(
      context,
      pageStack([
        Row(
          children: [
            AltBlob(
              icon: MobilePlatform.android
                  ? Icons.phone_android_rounded
                  : AltIcons.desktopWindows,
              background: colors.secondary,
              foreground: colors.onSecondary,
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    MobilePlatform.android
                        ? MobilePlatform.deviceName
                        : t('local'),
                    style: text.titleLarge?.copyWith(
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                  Text(
                    t(
                      MobilePlatform.android
                          ? 'mobileDeviceHint'
                          : 'deviceLocalHint',
                    ),
                    style: text.bodyMedium?.copyWith(
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (live.localInferenceAllowed)
          pagePanel(
            context,
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('share'), style: text.bodyLarge),
                      pageHint(
                        context,
                        sharing
                            ? '${live.sharedHost.address} · ${live.sharedHost.info['model']}'
                            : t('shareLocalHint'),
                      ),
                      if (sharing)
                        TextButton(
                          onPressed: sharingDialog,
                          child: Text(t('sharingDetails')),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Switch(
                  key: const Key('sharing'),
                  value: sharing,
                  onChanged: live.sharedHost.busy
                      ? null
                      : (value) async {
                          if (value) {
                            await sharingDialog();
                          } else {
                            await live.sharedHost.stop();
                          }
                        },
                ),
              ],
            ),
            radius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: colors.surface,
          ),
      ], gap: 20),
      radius: 28,
      padding: const EdgeInsets.all(24),
      color: colors.secondaryContainer,
    );
  }

  /// Devices allowed to use this computer, with a way to add and remove them.
  Widget pairedPanel(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final devices = live.sharedHost.devices.devices;
    return pagePanel(
      context,
      pageStack([
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(t('pairedDevices'), style: text.titleMedium),
              ),
              TextButton.icon(
                key: const Key('add-device'),
                onPressed: sharingDialog,
                icon: const Icon(Icons.qr_code_2_rounded, size: 20),
                label: Text(t('addDevice')),
              ),
            ],
          ),
        ),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: pageHint(context, t('noPairedDevices')),
          )
        else
          for (final device in devices)
            ListTile(
              key: ValueKey('paired-${device.id}'),
              contentPadding: const EdgeInsets.only(left: 16, right: 8),
              leading: Icon(
                device.platform == 'android'
                    ? Icons.phone_android_rounded
                    : AltIcons.desktopWindows,
                color: colors.onSurfaceVariant,
              ),
              title: Text(device.name),
              subtitle: Text(seenText(device.lastSeen)),
              trailing: IconButton(
                tooltip: t('removeDevice'),
                onPressed: () => revoke(device),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ),
        const SizedBox(height: 4),
      ], gap: 0),
    );
  }

  Widget connectPanel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final found = nearby;
    return pagePanel(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t('connectNetwork'), style: text.titleMedium),
          const SizedBox(height: 18),
          Icon(AltIcons.devices, size: 40, color: colors.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(
            t('remoteConnectionGuide'),
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (MobilePlatform.android)
                FilledButton.tonalIcon(
                  key: const Key('scan-to-pair'),
                  onPressed: pairing ? null : scan,
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                  label: Text(t('scanToPair')),
                ),
              if (MobilePlatform.android)
                TextButton.icon(
                  key: const Key('connect-manually'),
                  onPressed: pairing ? null : () => manual(),
                  icon: const Icon(AltIcons.radar, size: 20),
                  label: Text(t('remoteButton')),
                )
              else
                FilledButton.tonalIcon(
                  key: const Key('connect-manually'),
                  onPressed: () => manual(),
                  icon: const Icon(AltIcons.radar, size: 20),
                  label: Text(t('connectHost')),
                ),
            ],
          ),
          if (pairing) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (issue != null) ...[
            const SizedBox(height: 12),
            Text(
              issue!,
              style: TextStyle(color: colors.error),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: Text(t('nearbyHosts'), style: text.titleSmall)),
              TextButton.icon(
                key: const Key('find-hosts'),
                onPressed: searching ? null : search,
                icon: const Icon(AltIcons.refresh, size: 18),
                label: Text(t(searching ? 'searching' : 'findHosts')),
              ),
            ],
          ),
          if (searching) const LinearProgressIndicator(),
          if (found != null && found.isEmpty && !searching)
            pageHint(context, t('noHostsFound')),
          for (final host in found ?? const <DiscoveredHost>[])
            ListTile(
              key: ValueKey('nearby-${host.id}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                AltIcons.desktopWindows,
                color: host.busy ? colors.tertiary : colors.primary,
              ),
              title: Text(host.name),
              subtitle: Text(
                '${host.address} · ${t(host.busy ? 'hostBusy' : 'hostOnline')}',
              ),
              trailing: host.id == live.remoteConnection.hostId
                  ? Text(
                      t('pairedLabel'),
                      style: text.labelLarge?.copyWith(color: colors.primary),
                    )
                  : FilledButton.tonal(
                      onPressed: pairing ? null : () => manual(host.address),
                      child: Text(t('pairAction')),
                    ),
            ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    );
  }

  Widget savedPanel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final connection = live.remoteConnection;
    final saved = connection.address.isNotEmpty;
    return pagePanel(
      context,
      pageStack([
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(t('savedRemote'), style: text.titleMedium),
        ),
        ListTile(
          key: const Key('saved-host'),
          minTileHeight: 88,
          contentPadding: const EdgeInsets.only(left: 16, right: 8),
          leading: Icon(
            saved ? AltIcons.desktopWindows : AltIcons.addLink,
            color: saved
                ? statusColor(colors, live.hostStatus)
                : colors.onSurfaceVariant,
          ),
          title: Text(
            connection.name.isEmpty ? t('remoteButton') : connection.name,
          ),
          subtitle: Text(
            !saved
                ? t('noRemote')
                : '${connection.address}\n'
                      '${statusText(live.hostStatus)} · ${seenText(live.hostSeen)} · '
                      '${t(live.remoteProcessing ? 'remoteSelected' : 'remoteSaved')}',
          ),
          isThreeLine: saved,
          trailing: saved
              ? IconButton(
                  key: const Key('forget-host'),
                  tooltip: t('forgetHost'),
                  onPressed: live.active ? null : forget,
                  icon: const Icon(Icons.link_off_rounded),
                )
              : const Icon(AltIcons.chevronRight),
          onTap: () => manual(),
        ),
      ], gap: 0),
    );
  }

  @override
  Widget build(BuildContext context) => pageStack([
    pageHint(context, t('devicesSubtitle')),
    localCard(context),
    if (live.localInferenceAllowed) pairedPanel(context),
    pageColumns(context, connectPanel(context), savedPanel(context)),
  ]);
}
