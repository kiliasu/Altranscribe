import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/media_paths.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';

class FileImportPanel extends StatefulWidget {
  const FileImportPanel({
    super.key,
    required this.paths,
    required this.onChanged,
    required this.english,
  });
  final List<String> paths;
  final ValueChanged<List<String>> onChanged;
  final bool english;
  @override
  State<FileImportPanel> createState() => _FileImportPanelState();
}

class _FileImportPanelState extends State<FileImportPanel> {
  bool dragging = false;
  String? error;
  String t(String key) => strings[key]![widget.english ? 1 : 0];

  Future<void> addPaths(Iterable<String> paths) async {
    final accepted = <String>[];
    final rejected = <String>[];
    for (final path in paths) {
      if (!isSupportedAudioFile(path) ||
          (!isDocumentUri(path) && !await File(path).exists())) {
        rejected.add(mediaFileName(path));
      } else {
        accepted.add(isDocumentUri(path) ? path : File(path).absolute.path);
      }
    }
    if (!mounted) return;
    final next = [...widget.paths];
    for (final path in accepted) {
      if (!next.any(
        (old) => MobilePlatform.android
            ? old == path
            : old.replaceAll('\\', '/').toLowerCase() ==
                  path.replaceAll('\\', '/').toLowerCase(),
      )) {
        next.add(path);
      }
    }
    setState(() {
      dragging = false;
      error = rejected.isEmpty
          ? null
          : '${t('unsupportedFile')}: ${rejected.join(', ')}';
    });
    widget.onChanged(next);
  }

  Future<void> choose() async {
    try {
      if (MobilePlatform.android) {
        final paths = await MobilePlatform.chooseFiles();
        if (mounted) await addPaths(paths);
        return;
      }
      final files = await openFiles(
        acceptedTypeGroups: [
          XTypeGroup(label: t('file'), extensions: audioFileExtensions),
        ],
      );
      if (mounted) await addPaths(files.map((file) => file.path));
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DropTarget(
      key: const Key('file-drop-target'),
      enable:
          !MobilePlatform.android &&
          (ModalRoute.of(context)?.isCurrent ?? true),
      onDragEntered: (_) => setState(() => dragging = true),
      onDragExited: (_) => setState(() => dragging = false),
      onDragDone: (details) => addPaths(details.files.map((file) => file.path)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t('file'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  key: const Key('choose-files'),
                  onPressed: choose,
                  icon: const Icon(AltIcons.add, size: 20),
                  label: Text(t('addFiles')),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Material(
              color: dragging ? colors.secondaryContainer : colors.surface,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: CustomPaint(
                foregroundPainter: _DropOutline(
                  dragging ? colors.primary : colors.outline,
                ),
                child: InkWell(
                  onTap: choose,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 200),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 24,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const AltBlob(
                            icon: AltIcons.uploadFile,
                            size: 56,
                            iconSize: 28,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            t('dropFiles'),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            t('fileFormats'),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                          if (widget.paths.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              children: [
                                for (var i = 0; i < widget.paths.length; i++)
                                  InputChip(
                                    visualDensity: altChipDensity,
                                    avatarBoxConstraints: altChipIconBounds,
                                    avatar: const Icon(
                                      AltIcons.audioFile,
                                      size: 18,
                                    ),
                                    label: Text(
                                      mediaFileName(widget.paths[i]),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    deleteIcon: Icon(
                                      AltIcons.close,
                                      size: 18,
                                      key: ValueKey('remove-file-$i'),
                                    ),
                                    deleteButtonTooltipMessage: t('removeFile'),
                                    onDeleted: () => widget.onChanged(
                                      [...widget.paths]..removeAt(i),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                error!,
                                style: TextStyle(color: colors.error),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DropOutline extends CustomPainter {
  _DropOutline(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.5),
          const Radius.circular(20),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      for (double start = 0; start < metric.length; start += 8) {
        canvas.drawPath(
          metric.extractPath(start, (start + 4).clamp(0, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DropOutline oldDelegate) => oldDelegate.color != color;
}
