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
  bool checking = false;
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
      final id = live.remoteConnection.hostId;
      if (id.isNotEmpty &&
          found.any((host) => host.id == id) &&
          !hostConnected) {
        unawaited(recheck());
      }
    } catch (_) {
      if (mounted) setState(() => nearby = []);
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  Future<void> recheck() async {
    if (checking) return;
    setState(() => checking = true);
    try {
      await live.probeHost();
    } finally {
      if (mounted) setState(() => checking = false);
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

  bool get hostConnected =>
      live.hostStatus == HostStatus.online ||
      live.hostStatus == HostStatus.busy;

  /// Whether the saved host answered the last search on this network.
  bool get hostNearby {
    final id = live.remoteConnection.hostId;
    return id.isNotEmpty && (nearby ?? const []).any((host) => host.id == id);
  }

  /// What the saved host does for this device.
  String get hostRole {
    final speech = live.remoteProcessing, text = live.remoteLlm;
    return t(
      speech && text
          ? 'hostForBoth'
          : speech
          ? 'hostForSpeech'
          : text
          ? 'hostForText'
          : 'hostUnused',
    );
  }

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

  /// The host this device uses. While it answers, the card takes the colours
  /// of this device's own card above, so the connected pair reads at a glance.
  Widget hostCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final connection = live.remoteConnection;
    final connected = hostConnected;
    final foreground = connected
        ? colors.onSecondaryContainer
        : colors.onSurface;
    final address =
        Uri.tryParse(connection.address)?.authority ?? connection.address;
    // Where a connected host was also found: on this network.
    final place = hostNearby ? ' · ${t('sameNetwork')}' : '';
    final (label, fill, ink) = switch (live.hostStatus) {
      HostStatus.online => (
        '${t('hostConnected')}$place',
        colors.secondary,
        colors.onSecondary,
      ),
      HostStatus.busy => (
        '${t('hostConnected')} · ${t('hostBusy')}$place',
        colors.secondary,
        colors.onSecondary,
      ),
      HostStatus.offline => (
        // After a restart the last sighting is unknown, not "never".
        live.hostSeen == null
            ? t('hostOffline')
            : '${t('hostOffline')} · ${seenText(live.hostSeen)}',
        colors.errorContainer,
        colors.onErrorContainer,
      ),
      HostStatus.unknown => (
        t('hostChecking'),
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
    };
    return pagePanel(
      context,
      Row(
        children: [
          AltBlob(
            icon: AltIcons.desktopWindows,
            background: connected
                ? colors.secondary
                : colors.surfaceContainerHighest,
            foreground: connected
                ? colors.onSecondary
                : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connection.name.isEmpty ? address : connection.name,
                  style: text.titleLarge?.copyWith(color: foreground),
                ),
                const SizedBox(height: 6),
                DecoratedBox(
                  key: const Key('host-status'),
                  decoration: ShapeDecoration(
                    color: fill,
                    shape: const StadiumBorder(),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 3, 12, 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          connected
                              ? Icons.check_circle_rounded
                              : live.hostStatus == HostStatus.offline
                              ? Icons.cloud_off_rounded
                              : Icons.more_horiz_rounded,
                          size: 16,
                          color: ink,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            label,
                            style: text.labelLarge?.copyWith(color: ink),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$address\n$hostRole',
                  style: text.bodyMedium?.copyWith(color: foreground),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const Key('forget-host'),
                tooltip: t('forgetHost'),
                color: foreground,
                onPressed: live.active ? null : forget,
                icon: const Icon(Icons.link_off_rounded),
              ),
              if (!connected)
                IconButton(
                  key: const Key('recheck-host'),
                  tooltip: t('recheckHost'),
                  color: foreground,
                  onPressed: checking ? null : recheck,
                  icon: const Icon(AltIcons.refresh),
                ),
            ],
          ),
        ],
      ),
      radius: 28,
      padding: const EdgeInsets.fromLTRB(24, 24, 12, 24),
      color: connected ? colors.secondaryContainer : null,
    );
  }

  /// Ways to reach a host: scan its code, type its address, or pick it from
  /// the hosts answering on this network. The saved host is not listed again.
  Widget connectPanel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final saved = live.remoteConnection.hostId;
    final others = nearby
        ?.where((host) => saved.isEmpty || host.id != saved)
        .toList();
    return pagePanel(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t(
              live.remoteConnection.address.isEmpty
                  ? 'connectHost'
                  : 'otherHost',
            ),
            style: text.titleMedium,
          ),
          const SizedBox(height: 18),
          Icon(AltIcons.devices, size: 40, color: colors.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(
            t('remoteConnectionGuide'),
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          // Two actions of one size on one line, so neither sits higher.
          if (MobilePlatform.android)
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const Key('scan-to-pair'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: pairing ? null : scan,
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                    label: Text(t('scanToPair')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('connect-manually'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: pairing ? null : () => manual(),
                    icon: const Icon(AltIcons.radar, size: 20),
                    label: Text(t('remoteButton')),
                  ),
                ),
              ],
            )
          else
            Center(
              child: FilledButton.tonalIcon(
                key: const Key('connect-manually'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => manual(),
                icon: const Icon(AltIcons.radar, size: 20),
                label: Text(t('remoteButton')),
              ),
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
          if (others != null && others.isEmpty && !searching)
            pageHint(
              context,
              t(nearby!.isEmpty ? 'noHostsFound' : 'noOtherHosts'),
            ),
          for (final host in others ?? const <DiscoveredHost>[])
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
              trailing: FilledButton.tonal(
                onPressed: pairing ? null : () => manual(host.address),
                child: Text(t('pairAction')),
              ),
            ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    );
  }

  @override
  Widget build(BuildContext context) => pageStack([
    pageHint(context, t('devicesSubtitle')),
    localCard(context),
    if (live.localInferenceAllowed) pairedPanel(context),
    if (live.remoteConnection.address.isNotEmpty) hostCard(context),
    connectPanel(context),
  ]);
}
