import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/shared/ui/alt_icons.dart';

import 'settings_dialog.dart';

class AudioSettingsDialog extends SettingsDialog {
  const AudioSettingsDialog({
    super.key,
    required super.controller,
    required super.english,
  });
  @override
  State<AudioSettingsDialog> createState() => _AudioSettingsState();
}

class _AudioSettingsState extends SettingsDialogState<AudioSettingsDialog> {
  late String mic = controller.microphoneDevice;
  late String system = controller.systemDevice;
  late bool microphoneDenoise = controller.microphoneDenoise;
  late bool microphoneAutoGain = controller.microphoneAutoGain;
  late bool systemDenoise = controller.systemDenoise;
  late bool systemAutoGain = controller.systemAutoGain;
  List<Map<String, Object?>> devices = [];
  @override
  String get title => 'audioSettings';
  @override
  Future<void> load() async {
    final result = await controller.audio.devices();
    if (mounted) setState(() => devices = result);
  }

  Widget devicePicker(
    String source,
    String selected,
    ValueChanged<String?> onChanged,
  ) {
    final matches = devices
        .where((device) => device['source'] == source)
        .toList();
    final label = t(source == 'system' ? 'systemAudio' : 'microphone');
    final options = <String, String>{
      '': t('systemDefault'),
      if (selected.isNotEmpty &&
          !matches.any((device) => device['id'] == selected))
        selected: t('deviceUnavailable'),
      for (final device in matches)
        device['id'] as String: device['name'] as String,
    };
    return SizedBox(
      height: 72,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(
              source == 'system' ? AltIcons.volumeUp : AltIcons.mic,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey(
                  '$source-${matches.map((item) => item['id']).join()}',
                ),
                initialValue: selected,
                isExpanded: true,
                isDense: false,
                style: Theme.of(context).textTheme.bodyLarge,
                icon: const Icon(AltIcons.arrowDropDown),
                decoration: InputDecoration(
                  contentPadding: EdgeInsets.zero,
                  isCollapsed: true,
                  fillColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerLowest,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                ),
                selectedItemBuilder: (_) => [
                  for (final name in options.values)
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                ],
                items: [
                  for (final option in options.entries)
                    DropdownMenuItem(
                      value: option.key,
                      child: Text(
                        option.value,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: editable ? onChanged : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  List<Widget> contents() => [
    Text(t('audioPanelHint')),
    if (!controller.localInferenceAllowed) Text(t('androidSystemAudioHint')),
    gap(),
    choices([
      devicePicker('microphone', mic, (value) => setState(() => mic = value!)),
      CheckboxListTile(
        key: const Key('microphone-denoise'),
        value: microphoneDenoise,
        onChanged: editable
            ? (value) => setState(() => microphoneDenoise = value!)
            : null,
        title: Text(t('audioDenoise')),
        subtitle: Text(t('audioDenoiseHint')),
      ),
      CheckboxListTile(
        key: const Key('microphone-auto-gain'),
        value: microphoneAutoGain,
        onChanged: editable
            ? (value) => setState(() => microphoneAutoGain = value!)
            : null,
        title: Text(t('audioAutoGain')),
        subtitle: Text(t('audioAutoGainHint')),
      ),
    ]),
    gap(),
    choices([
      devicePicker(
        'system',
        system,
        (value) => setState(() => system = value!),
      ),
      CheckboxListTile(
        key: const Key('system-denoise'),
        value: systemDenoise,
        onChanged: editable
            ? (value) => setState(() => systemDenoise = value!)
            : null,
        title: Text(t('audioDenoise')),
        subtitle: Text(t('systemDenoiseHint')),
      ),
      CheckboxListTile(
        key: const Key('system-auto-gain'),
        value: systemAutoGain,
        onChanged: editable
            ? (value) => setState(() => systemAutoGain = value!)
            : null,
        title: Text(t('audioAutoGain')),
        subtitle: Text(t('audioAutoGainHint')),
      ),
    ]),
    gap(),
    Row(
      children: [
        Expanded(
          child: Text(
            t('deviceChangeHint'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(width: 12),
        TextButton.icon(
          onPressed: busy ? null : () => run(load),
          icon: const Icon(AltIcons.refresh, size: 18),
          label: Text(t('refreshDevices')),
        ),
      ],
    ),
  ];
  @override
  Future<void> save() async {
    controller.microphoneDevice = mic;
    controller.systemDevice = system;
    controller.microphoneDenoise = microphoneDenoise;
    controller.microphoneAutoGain = microphoneAutoGain;
    controller.systemDenoise = systemDenoise;
    controller.systemAutoGain = systemAutoGain;
    await controller.saveSettings();
  }
}
