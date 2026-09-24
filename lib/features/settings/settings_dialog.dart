import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';

abstract class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.controller,
    required this.english,
  });
  final RealtimeController controller;
  final bool english;
}

abstract class SettingsDialogState<T extends SettingsDialog> extends State<T>
    with WidgetsBindingObserver {
  bool busy = false;
  String? error;
  RealtimeController get controller => widget.controller;
  bool get allowDuringSession => false;
  bool get editable => !busy && (allowDuringSession || !controller.active);
  bool get canSave => editable;
  String t(String key) => strings[key]![widget.english ? 1 : 0];
  String get title;
  List<Widget> contents();
  Future<void> load();
  Future<void> save();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    run(load);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) run(load);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> run(
    Future<void> Function() operation, {
    bool close = false,
  }) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
      if (close && mounted) Navigator.pop(context);
    } catch (e) {
      final key = e.toString().replaceFirst(
        RegExp(r'^(FormatException|Bad state):\s*'),
        '',
      );
      if (mounted) {
        setState(
          () => error = strings.containsKey(key) ? t(key) : e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget gap() => const SizedBox(height: 12);

  Widget choices(List<Widget> children) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLowest,
    borderRadius: BorderRadius.circular(16),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: EdgeInsets.symmetric(
      horizontal: MediaQuery.sizeOf(context).width * .05,
      vertical: 24,
    ),
    constraints: BoxConstraints(
      maxWidth: 560,
      maxHeight: MediaQuery.sizeOf(context).height * .85,
    ),
    titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
    actionsPadding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
    title: Text(t(title)),
    content: SizedBox(
      width: 512,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controller.active && !allowDuringSession) ...[
              Text(t('settingsLocked')),
              gap(),
            ],
            ...contents(),
            if (busy) ...[gap(), const LinearProgressIndicator()],
            if (error != null) ...[
              gap(),
              SelectableText(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('cancel')),
      ),
      TextButton(
        onPressed: canSave ? () => run(save, close: true) : null,
        child: Text(t('save')),
      ),
    ],
  );
}
