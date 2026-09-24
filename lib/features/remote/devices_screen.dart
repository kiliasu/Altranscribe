import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/features/remote/remote_dialogs.dart';

import 'package:altranscribe/shared/ui/page_layout.dart';

class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key, required this.live, required this.english});
  final RealtimeController live;
  final bool english;
  String t(String key) => strings[key]![english ? 1 : 0];
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final sharing = live.sharedHost.running;
    Future<void> remoteDialog() => showDialog<void>(
      context: context,
      builder: (_) =>
          RemoteConnectionDialog(controller: live, english: english),
    );

    Future<void> sharingDialog() => showDialog<void>(
      context: context,
      builder: (_) => SharedHostDialog(controller: live, english: english),
    );
    return pageStack([
      pageHint(context, t('devicesSubtitle')),
      pagePanel(
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
      ),
      pageColumns(
        context,
        pagePanel(
          context,
          Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(t('connectNetwork'), style: text.titleMedium),
              ),
              const SizedBox(height: 18),
              Icon(AltIcons.devices, size: 40, color: colors.onSurfaceVariant),
              const SizedBox(height: 10),
              Text(
                t('remoteAddressConnection'),
                style: text.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                t('remoteConnectionGuide'),
                style: text.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: remoteDialog,
                icon: const Icon(AltIcons.radar, size: 20),
                label: Text(t('connectHost')),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        ),
        pagePanel(
          context,
          pageStack([
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(t('savedRemote'), style: text.titleMedium),
            ),
            ListTile(
              minTileHeight: 88,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(AltIcons.addLink),
              title: Text(
                live.remoteConnection.name.isEmpty
                    ? t('remoteButton')
                    : live.remoteConnection.name,
              ),
              subtitle: Text(
                live.remoteConnection.address.isEmpty
                    ? t('noRemote')
                    : '${live.remoteConnection.address}\n${t(live.remoteProcessing ? 'remoteSelected' : 'remoteSaved')}',
              ),
              trailing: const Icon(AltIcons.chevronRight),
              onTap: remoteDialog,
            ),
          ], gap: 0),
        ),
      ),
    ]);
  }
}
