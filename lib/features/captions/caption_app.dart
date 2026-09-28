import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/app/theme/app_theme.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/features/captions/caption_host.dart'
    show captionChannel;
import 'package:altranscribe/data/models/caption_preferences.dart';

class CaptionApp extends StatefulWidget {
  const CaptionApp({super.key});
  @override
  State<CaptionApp> createState() => _CaptionAppState();
}

class _CaptionAppState extends State<CaptionApp> {
  Map data = const {};
  final navigator = GlobalKey<NavigatorState>();
  @override
  void initState() {
    super.initState();
    captionChannel.setMethodCallHandler((call) async {
      if (call.method == 'snapshot' && mounted) {
        setState(() => data = call.arguments as Map);
      } else if (call.method == 'hidden') {
        navigator.currentState?.popUntil((route) => route.isFirst);
      }
    });
    unawaited(load());
  }

  Future<void> load() async {
    final initial = await captionChannel.invokeMapMethod('ready');
    if (mounted && data.isEmpty && initial != null) {
      setState(() => data = initial);
    }
  }

  @override
  void dispose() {
    captionChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final english = data['english'] == true;
    final palette =
        AppPalette.values.where((p) => p.name == data['palette']).firstOrNull ??
        AppPalette.amber;
    return MaterialApp(
      title: 'Altranscribe · Captions',
      navigatorKey: navigator,
      debugShowCheckedModeBanner: false,
      locale: english ? const Locale('en') : const Locale('zh', 'CN'),
      supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: altranscribeTheme(
        data['dark'] == true ? Brightness.dark : Brightness.light,
        palette: palette,
      ),
      themeAnimationDuration: data['reduceMotion'] == true
          ? Duration.zero
          : const Duration(milliseconds: 200),
      home: CaptionPanel(
        data: data,
        action: (action) =>
            captionChannel.invokeMethod<Object?>('action', action),
      ),
    );
  }
}

class CaptionPanel extends StatefulWidget {
  const CaptionPanel({super.key, required this.data, required this.action});
  final Map data;
  final Future<Object?> Function(String action) action;
  @override
  State<CaptionPanel> createState() => _CaptionPanelState();
}

class _CaptionPanelState extends State<CaptionPanel> {
  bool busy = false;
  String? error;
  final scroll = ScrollController();
  String t(String key) => strings[key]![widget.data['english'] == true ? 1 : 0];
  CaptionPreferences get prefs =>
      CaptionPreferences.fromJson(widget.data['preferences'] as Map? ?? {});
  bool get paused => widget.data['phase'] == 'paused';
  bool get canPause =>
      ['listening', 'paused'].contains(widget.data['phase']) &&
      widget.data['pausePending'] != true &&
      widget.data['confirming'] != true &&
      !busy;

  Future<void> run(String action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (action == 'discard') {
        if (await widget.action('prepareDiscard') != true) return;
        try {
          if (!mounted) return;
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(t('discardSession')),
              content: SingleChildScrollView(
                child: Text(t('discardSessionHint')),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(t('cancel')),
                ),
                FilledButton(
                  key: const Key('caption-confirm-discard'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(t('discardSession')),
                ),
              ],
            ),
          );
          if (confirmed == true) await widget.action('discard');
        } finally {
          await widget.action('cancelDiscard');
        }
      } else {
        await widget.action(action);
      }
    } catch (_) {
      if (mounted) setState(() => error = t('captionActionFailed'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rows = widget.data['rows'] as List? ?? [];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
    });
    Widget button(
      String action,
      String label,
      IconData icon, {
      bool enabled = true,
    }) => IconButton(
      key: Key('caption-$action'),
      tooltip: t(label),
      onPressed: enabled && !busy ? () => run(action) : null,
      icon: Icon(icon, size: 22),
    );
    final style = TextStyle(
      fontFamily: prefs.font,
      fontFamilyFallback: const ['NotoSansSC', 'Roboto'],
      fontSize: prefs.fontSize,
      height: 1.4,
      color: colors.onSurface,
    );
    return Scaffold(
      backgroundColor: colors.surfaceContainer,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) =>
                        captionChannel.invokeMethod<void>('drag'),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.move,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            Icon(
                              AltIcons.subtitles,
                              size: 20,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Altranscribe · ${t('floatingCaptions')}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                button('close', 'closeCaptions', AltIcons.close),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          t('waitingSpeech'),
                          style: style.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    for (final row in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.data['rows'] != null &&
                                rows.map((r) => r['source']).toSet().length > 1)
                              Text(
                                t(
                                  row['source'] == 'system'
                                      ? 'systemAudio'
                                      : 'microphone',
                                ),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            if (prefs.original &&
                                (row['original'] as String).isNotEmpty)
                              Text(row['original'] as String, style: style),
                            if (prefs.translation &&
                                widget.data['hasTranslation'] == true) ...[
                              if (prefs.original) const SizedBox(height: 4),
                              Text(
                                (row['translation'] as String).isNotEmpty
                                    ? row['translation'] as String
                                    : t(switch (row['status']) {
                                        'failed' => 'translationFailed',
                                        'interrupted' =>
                                          'translationInterrupted',
                                        _ => 'translationPending',
                                      }),
                                style: style.copyWith(
                                  color: colors.primary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    if (rows.isNotEmpty &&
                        !prefs.original &&
                        widget.data['hasTranslation'] != true)
                      Text(t('captionTranslationOff'), style: style),
                  ],
                ),
              ),
            ),
            if (error != null)
              Text(error!, maxLines: 2, style: TextStyle(color: colors.error)),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    t(switch (widget.data['phase']) {
                      'paused' => 'paused',
                      'loading' => 'loadingModel',
                      'stopping' => 'stopping',
                      _ => 'listening',
                    }),
                    style: Theme.of(context).textTheme.labelMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                button(
                  'smaller',
                  'smallerCaptions',
                  AltIcons.textDecrease,
                  enabled: prefs.fontSize > 14,
                ),
                button(
                  'larger',
                  'largerCaptions',
                  AltIcons.textIncrease,
                  enabled: prefs.fontSize < 48,
                ),
                const SizedBox(width: 4),
                button(
                  'pause',
                  paused ? 'resume' : 'pause',
                  paused ? AltIcons.playArrow : AltIcons.pause,
                  enabled: canPause,
                ),
                button(
                  'stop',
                  'stop',
                  AltIcons.stop,
                  enabled:
                      !busy &&
                      widget.data['confirming'] != true &&
                      [
                        'listening',
                        'paused',
                        'loading',
                      ].contains(widget.data['phase']),
                ),
                const SizedBox(width: 12),
                IconButton(
                  key: const Key('caption-discard'),
                  tooltip: t('discardSession'),
                  onPressed: canPause ? () => run('discard') : null,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    color: canPause ? colors.error : null,
                    size: 22,
                  ),
                ),
              ],
            ),
            if (MobilePlatform.android)
              Align(
                alignment: Alignment.bottomRight,
                child: GestureDetector(
                  key: const Key('caption-resize'),
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) =>
                      captionChannel.invokeMethod<void>('resize'),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 20, top: 4),
                    child: Icon(
                      Icons.south_east_rounded,
                      size: 18,
                      color: colors.outline,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
