import 'package:altranscribe/features/records/record_detail_dialog.dart';
import 'package:altranscribe/shared/ui/page_layout.dart';
import 'package:altranscribe/app/l10n/localized_issue.dart';
import 'package:altranscribe/shared/ui/confirmation_dialog.dart';
import 'package:altranscribe/shared/ui/transcript_tile.dart';
import 'package:altranscribe/features/records/records_screen.dart';
import 'package:altranscribe/features/remote/devices_screen.dart';
import 'package:altranscribe/features/settings/settings_screen.dart';
import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/app/theme/app_theme.dart';
import 'package:altranscribe/shared/ui/alt_icons.dart';
import 'package:altranscribe/shared/ui/audio_visualizer.dart';
import 'package:altranscribe/shared/ui/expressive.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/features/settings/audio_settings_dialog.dart';
import 'package:altranscribe/features/settings/model_settings_dialog.dart';
import 'package:altranscribe/features/settings/translation_settings_dialog.dart';
import 'package:altranscribe/features/settings/context_settings_dialog.dart';
import 'package:altranscribe/features/settings/caption_settings_dialog.dart';
import 'package:altranscribe/features/files/file_import_panel.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';

class AltranscribeHome extends StatefulWidget {
  const AltranscribeHome({
    super.key,
    required this.english,
    required this.themeMode,
    required this.palette,
    required this.reduceMotion,
    required this.onLocale,
    required this.onTheme,
    required this.onPalette,
    required this.onMotion,
    required this.realtime,
  });

  final bool english;
  final ThemeMode themeMode;
  final AppPalette palette;
  final bool reduceMotion;
  final ValueChanged<bool> onLocale;
  final ValueChanged<ThemeMode> onTheme;
  final ValueChanged<AppPalette> onPalette;
  final ValueChanged<bool> onMotion;
  final RealtimeController realtime;

  @override
  State<AltranscribeHome> createState() => _AltranscribeHomeState();
}

class _AltranscribeHomeState extends State<AltranscribeHome>
    with SingleTickerProviderStateMixin {
  int page = 0;
  Timer? sessionClock;
  bool minimized = false;
  int sessionShape = math.Random().nextInt(AltLoading.shapeCount);
  bool get confirmingDiscard => live.discardConfirmationPending;
  String recordQuery = '';
  bool get showSession =>
      session && !live.backgroundFinishing && !minimized && page == 0;
  bool get narrow => MediaQuery.sizeOf(context).width < 840;
  bool fileMode = false;
  bool microphone = true;
  bool systemAudio = false;
  bool translate = true;
  bool get directTranslation =>
      live.cloudSpeech && live.cloudDirectTranslation && translate && !fileMode;
  bool get automaticLanguage =>
      live.cloudSpeech && (live.cloudAutoLanguage || directTranslation);
  RealtimeController get live => widget.realtime;
  bool get session => live.active;
  bool get paused => live.phase == SessionPhase.paused;
  bool get sharing => live.sharedHost.running;
  String sourceLanguage = 'English';
  String targetLanguage = '简体中文';
  late final swapAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
    value: 1,
  );
  int swapCount = 0;
  String? previousSource, previousTarget;
  double captionSize = 22;
  final fileOptions = <bool>[false, false, false];
  List<String> filePaths = [];
  String preferredSpellings = '';
  final scrollBucket = PageStorageBucket();
  final sessionScroll = ScrollController();
  bool followLatest = true;
  bool followScheduled = false;
  bool wasSession = false;
  int transcriptRevision = -1;
  double? lastSessionExtent;
  double? lastSessionViewport;

  @override
  void initState() {
    super.initState();
    live.addListener(refresh);
    live.sharedHost.addListener(refresh);
    MobilePlatform.importedFiles.addListener(importMobileFiles);
    WidgetsBinding.instance.addPostFrameCallback((_) => importMobileFiles());
    sessionClock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && session) setState(() {});
    });
    wasSession = session;
    scheduleFollow();
  }

  void refresh() {
    if (!mounted) return;
    if (session && !wasSession) {
      sessionShape = math.Random().nextInt(AltLoading.shapeCount);
      followLatest = true;
      minimized = false;
    }
    final contentChanged = transcriptRevision != live.transcriptRevision;
    transcriptRevision = live.transcriptRevision;
    wasSession = session;
    setState(() {});
    if (contentChanged) scheduleFollow();
  }

  void importMobileFiles() {
    final paths = MobilePlatform.importedFiles.value;
    if (!mounted || paths.isEmpty) return;
    MobilePlatform.importedFiles.value = [];
    setState(() {
      filePaths = {...filePaths, ...paths.where(isSupportedAudioFile)}.toList();
      if (!session) {
        fileMode = true;
        page = 0;
      }
    });
    if (paths.any((path) => !isSupportedAudioFile(path))) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t('unsupportedFile'))));
    }
  }

  void scheduleFollow() {
    if (followScheduled || !followLatest || !showSession) return;
    followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      followScheduled = false;
      if (mounted && showSession && followLatest && sessionScroll.hasClients) {
        sessionScroll.jumpTo(sessionScroll.position.maxScrollExtent);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void selectPage(int value) {
    setState(() => page = value);
    scheduleFollow();
  }

  @override
  void dispose() {
    live.removeListener(refresh);
    live.sharedHost.removeListener(refresh);
    MobilePlatform.importedFiles.removeListener(importMobileFiles);
    sessionClock?.cancel();
    swapAnimation.dispose();
    sessionScroll.dispose();
    super.dispose();
  }

  static const languageCodes = {
    'English': 'en',
    '简体中文': 'zh',
    '日本語': 'ja',
    '한국어': 'ko',
  };

  Future<void> showRecord(TranscriptRecord record) => showDialog<void>(
    context: context,
    builder: (_) => RecordDetailDialog(
      live: live,
      initial: record,
      english: widget.english,
    ),
  );

  Future<void> audioSettings() => showDialog<void>(
    context: context,
    builder: (_) =>
        AudioSettingsDialog(controller: live, english: widget.english),
  );

  Future<void> modelSettings() => showDialog<void>(
    context: context,
    builder: (_) =>
        ModelSettingsDialog(controller: live, english: widget.english),
  );

  Future<void> translationSettings() => showDialog<void>(
    context: context,
    builder: (_) =>
        TranslationSettingsDialog(controller: live, english: widget.english),
  );

  Future<void> captionSettings() => showDialog<void>(
    context: context,
    builder: (_) =>
        CaptionSettingsDialog(controller: live, english: widget.english),
  );

  Future<void> contextSettings() => showDialog<void>(
    context: context,
    builder: (_) =>
        ContextSettingsDialog(controller: live, english: widget.english),
  );

  Duration get navigationDuration =>
      widget.reduceMotion || MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 240);

  Widget captionToggle(String key, {bool compact = false}) => compact
      ? IconButton(
          key: Key(key),
          tooltip: t('floatingCaptions'),
          isSelected: live.captionsVisible,
          selectedIcon: const Icon(AltIcons.subtitles, fill: 1),
          onPressed: () => live.setCaptionsVisible(!live.captionsVisible),
          icon: const Icon(AltIcons.subtitles),
        )
      : FilterChip(
          key: Key(key),
          selected: live.captionsVisible,
          avatar: live.captionsVisible
              ? null
              : const Icon(AltIcons.subtitles, size: 18),
          label: Text(t('floatingCaptions')),
          onSelected: live.setCaptionsVisible,
        );

  String issue(String value) => localizedIssue(value, widget.english);

  /// A line still being recognized in a session that translates with a text
  /// model; direct speech translation streams its own text instead.
  bool awaitingTranslation(TranscriptLine line) {
    final current = live.record;
    return live.active &&
        current != null &&
        current.targetLanguage != null &&
        current.targetLanguage != current.language &&
        !current.directTranslation &&
        line.transcriptionStatus == 'partial' &&
        line.translationStatus == 'none';
  }

  String t(String key) => strings[key]![widget.english ? 1 : 0];
  ColorScheme get colors => Theme.of(context).colorScheme;
  TextTheme get text => Theme.of(context).textTheme;

  static const pageKeys = ['transcribe', 'library', 'devices', 'settings'];
  static const pageIcons = [
    AltIcons.subtitles,
    AltIcons.history,
    AltIcons.devices,
    AltIcons.tune,
  ];

  @override
  Widget build(BuildContext context) {
    final pageContent = switch (page) {
      0 => showSession ? sessionPage() : transcribePage(),
      1 => RecordsScreen(
        controller: live,
        english: widget.english,
        query: recordQuery,
        onQueryChanged: (value) => setState(() => recordQuery = value),
        onTranscribe: () => setState(() {
          page = 0;
          fileMode = false;
        }),
      ),
      2 => DevicesScreen(live: live, english: widget.english),
      _ => SettingsScreen(
        live: live,
        english: widget.english,
        themeMode: widget.themeMode,
        palette: widget.palette,
        reduceMotion: widget.reduceMotion,
        onLocale: widget.onLocale,
        onTheme: widget.onTheme,
        onPalette: widget.onPalette,
        onMotion: widget.onMotion,
        captionSize: captionSize,
        onCaptionSize: (value) => setState(() => captionSize = value),
        modelSummary: modelSummary,
        llmSummary: llmSummary,
        audioSummary: audioSummary,
      ),
    };
    final scaffold = Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!narrow)
                        SizedBox(
                          width: 220,
                          child: ColoredBox(
                            color: colors.surfaceContainerLow,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  height: 56,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 28,
                                    ),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        'Altranscribe',
                                        style: text.titleMedium?.copyWith(
                                          color: colors.primary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                for (var i = 0; i < pageKeys.length; i++)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Semantics(
                                      selected: i == page,
                                      child: AnimatedContainer(
                                        duration: navigationDuration,
                                        curve: Curves.easeOutCubic,
                                        decoration: BoxDecoration(
                                          color: i == page
                                              ? colors.secondaryContainer
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            28,
                                          ),
                                        ),
                                        child: TextButton(
                                          key: ValueKey('nav-$i'),
                                          onPressed: () => selectPage(i),
                                          style: TextButton.styleFrom(
                                            minimumSize: const Size(0, 56),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                            ),
                                            backgroundColor: Colors.transparent,
                                            foregroundColor: i == page
                                                ? colors.onSurface
                                                : colors.onSurfaceVariant,
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                pageIcons[i],
                                                size: 24,
                                                fill: i == page ? 1 : 0,
                                                color: i == page
                                                    ? colors
                                                          .onSecondaryContainer
                                                    : colors.onSurfaceVariant,
                                              ),
                                              const SizedBox(width: 12),
                                              Text(
                                                t(pageKeys[i]),
                                                style: text.labelLarge,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: Column(
                          children: [
                            Padding(
                              padding: EdgeInsets.fromLTRB(
                                narrow ? 16 : 24,
                                20,
                                narrow ? 16 : 24,
                                8,
                              ),
                              child: Row(
                                children: [
                                  if (showSession) ...[
                                    IconButton(
                                      key: const Key('minimize-session'),
                                      tooltip: t('minimize'),
                                      onPressed: () =>
                                          setState(() => minimized = true),
                                      icon: const Icon(AltIcons.arrowBack),
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                  Expanded(
                                    child: Text(
                                      t(pageKeys[page]),
                                      style: text.headlineMedium,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (showSession)
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: narrow ? 16 : 24,
                                ),
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Wrap(
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    spacing: 8,
                                    children: [
                                      if (!live.processingFiles)
                                        captionToggle('session-captions'),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Checkbox(
                                            key: const Key('follow-latest'),
                                            value: followLatest,
                                            onChanged: (v) {
                                              setState(() => followLatest = v!);
                                              scheduleFollow();
                                            },
                                          ),
                                          GestureDetector(
                                            onTap: () {
                                              setState(
                                                () => followLatest =
                                                    !followLatest,
                                              );
                                              scheduleFollow();
                                            },
                                            child: Text(
                                              t('followLatest'),
                                              style: text.labelLarge,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            Expanded(
                              child: PageStorage(
                                bucket: scrollBucket,
                                child:
                                    NotificationListener<
                                      ScrollMetricsNotification
                                    >(
                                      onNotification: (notification) {
                                        if (showSession &&
                                            notification.depth == 0) {
                                          final metrics = notification.metrics;
                                          final resized =
                                              lastSessionExtent !=
                                                  metrics.maxScrollExtent ||
                                              lastSessionViewport !=
                                                  metrics.viewportDimension;
                                          lastSessionExtent =
                                              metrics.maxScrollExtent;
                                          lastSessionViewport =
                                              metrics.viewportDimension;
                                          if (resized) scheduleFollow();
                                        }
                                        return false;
                                      },
                                      child: SingleChildScrollView(
                                        key: PageStorageKey(
                                          'page-$page-$showSession-$fileMode',
                                        ),
                                        controller: showSession
                                            ? sessionScroll
                                            : null,
                                        padding: EdgeInsets.fromLTRB(
                                          narrow ? 16 : 24,
                                          8,
                                          narrow ? 16 : 24,
                                          session ? 120 : 32,
                                        ),
                                        child: Align(
                                          alignment: Alignment.topCenter,
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 960,
                                            ),
                                            child:
                                                TweenAnimationBuilder<double>(
                                                  key: ValueKey(
                                                    'page-transition-$page',
                                                  ),
                                                  tween: Tween(
                                                    begin: 0,
                                                    end: 1,
                                                  ),
                                                  duration: navigationDuration,
                                                  curve: Curves.easeOutCubic,
                                                  builder:
                                                      (
                                                        context,
                                                        value,
                                                        child,
                                                      ) => Opacity(
                                                        opacity: value,
                                                        child:
                                                            Transform.translate(
                                                              offset: Offset(
                                                                0,
                                                                12 *
                                                                    (1 - value),
                                                              ),
                                                              child: child,
                                                            ),
                                                      ),
                                                  child: pageContent,
                                                ),
                                          ),
                                        ),
                                      ),
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (narrow)
                  NavigationBar(
                    selectedIndex: page,
                    onDestinationSelected: selectPage,
                    destinations: [
                      for (var i = 0; i < pageKeys.length; i++)
                        NavigationDestination(
                          key: ValueKey('nav-$i'),
                          icon: Icon(pageIcons[i], fill: 0),
                          selectedIcon: Icon(pageIcons[i], fill: 1),
                          label: t(pageKeys[i]),
                        ),
                    ],
                  ),
              ],
            ),
            if (showSession)
              Positioned(
                left: 16,
                right: 16,
                bottom: narrow ? 96 : 20,
                child: Center(child: sessionToolbar()),
              ),
            if (session && !live.backgroundFinishing && !showSession)
              Positioned(
                right: 24,
                bottom: narrow ? 96 : 20,
                child: miniSession(),
              ),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: !MobilePlatform.android || (!showSession && page == 0),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !MobilePlatform.android) return;
        if (showSession) {
          setState(() => minimized = true);
        } else {
          selectPage(0);
        }
      },
      child: scaffold,
    );
  }

  String get modelSummary {
    if (live.remoteProcessing) {
      if (live.remoteConnection.name.isEmpty) {
        return 'Whisper Remote · ${t('noRemote')}';
      }
      return 'Whisper Remote · ${live.remoteConnection.name.isEmpty ? t('noRemote') : live.remoteConnection.name} · ${live.sessionModel}';
    }
    if (live.speechProvider == SpeechProvider.nemotron) {
      return 'Nemotron · ${ModelCatalog.nemotron(live.nemotronModel)?.shortLabel ?? live.nemotronModel} · CPU';
    }
    if (live.cloudSpeech) {
      return '${live.speechProvider.label} · ${fileMode ? live.speechProvider.fileModel : live.speechProvider.liveModel(directTranslation)}';
    }
    final filename = live.model.split(RegExp(r'[/\\]')).last;
    final model = ModelCatalog.models
        .where((item) => item.filename == filename)
        .firstOrNull;
    return 'Whisper · ${model?.label ?? (filename.isEmpty ? t('noModelConfigured') : filename)} · ${live.computeMode.name == 'automatic' ? t('automatic') : live.computeMode.name.toUpperCase()}';
  }

  String get llmSummary => live.remoteLlm
      ? 'Remote · ${live.sessionLlmModel.isEmpty ? t('remoteHostLlm') : live.sessionLlmModel}'
      : '${live.llmProvider.label} · ${live.translationModel.isEmpty ? t('translationModelMissing') : live.translationModel}';
  String get audioSummary =>
      live.microphoneDevice.isEmpty && live.systemDevice.isEmpty
      ? t('systemDefault')
      : t('selectedDevices');

  Widget infoRow(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap, {
    bool smallTitle = false,
  }) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: [
            Icon(icon, size: 24, color: colors.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: smallTitle ? null : 1,
                    overflow: smallTitle ? null : TextOverflow.ellipsis,
                    style: smallTitle
                        ? text.labelMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          )
                        : text.bodyLarge,
                  ),
                  Text(
                    subtitle,
                    style: smallTitle
                        ? text.bodyLarge
                        : text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(AltIcons.chevronRight, color: colors.onSurfaceVariant),
          ],
        ),
      ),
    ),
  );

  Widget section(String title, Widget child, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: text.titleMedium)),
            ?trailing,
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );

  Widget transcribePage() => pageStack([
    Align(
      alignment: Alignment.centerLeft,
      child: AltButtonGroup(
        items: [
          AltGroupItem(t('live'), icon: AltIcons.mic),
          AltGroupItem(t('file'), icon: AltIcons.folderOpen),
        ],
        selected: {fileMode ? 1 : 0},
        onPressed: session ? null : (i) => setState(() => fileMode = i == 1),
      ),
    ),
    pagePanel(
      context,
      pageStack([
        if (fileMode)
          IgnorePointer(
            ignoring: session,
            child: FileImportPanel(
              paths: filePaths,
              english: widget.english,
              onChanged: (paths) => setState(() => filePaths = paths),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 4),
            child: Row(
              children: [
                Expanded(child: Text(t('sources'), style: text.titleMedium)),
                TextButton.icon(
                  onPressed: audioSettings,
                  icon: const Icon(AltIcons.tune, size: 20),
                  label: Text(t('audioSettings')),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: AltButtonGroup(
              height: 56,
              stretch: true,
              items: [
                AltGroupItem(
                  t('microphone'),
                  icon: microphone ? AltIcons.check : AltIcons.mic,
                  key: const Key('microphone'),
                ),
                AltGroupItem(
                  t('systemAudio'),
                  icon: systemAudio ? AltIcons.check : AltIcons.volumeUp,
                  key: const Key('system-audio'),
                ),
              ],
              selected: {if (microphone) 0, if (systemAudio) 1},
              onPressed: session
                  ? null
                  : (i) => setState(() {
                      if (i == 0) {
                        microphone = !microphone;
                      } else {
                        systemAudio = !systemAudio;
                      }
                    }),
            ),
          ),
        ],
        Padding(
          padding: EdgeInsets.fromLTRB(20, fileMode ? 0 : 12, 20, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Tooltip(
                message: t(fileMode ? 'fileSummaryHint' : 'summaryHint'),
                child: FilterChip(
                  visualDensity: altChipDensity,
                  avatarBoxConstraints: altChipIconBounds,
                  key: const Key('generate-summary'),
                  showCheckmark: false,
                  avatar: Icon(
                    live.generateSummary
                        ? AltIcons.check
                        : AltIcons.autoAwesome,
                    size: 18,
                  ),
                  label: Text(t('summaryShort')),
                  selected: live.generateSummary,
                  onSelected: live.initialized && !session
                      ? live.setGenerateSummary
                      : null,
                ),
              ),
              if (fileMode)
                FilterChip(
                  visualDensity: altChipDensity,
                  avatarBoxConstraints: altChipIconBounds,
                  key: const Key('refine'),
                  showCheckmark: false,
                  avatar: Icon(
                    fileOptions.any((v) => v)
                        ? AltIcons.check
                        : AltIcons.spellcheck,
                    size: 18,
                  ),
                  label: Text(t('refine')),
                  selected: fileOptions.any((v) => v),
                  onSelected: session
                      ? null
                      : (value) => setState(() {
                          for (var i = 0; i < fileOptions.length; i++) {
                            fileOptions[i] = value;
                          }
                        }),
                ),
              ActionChip(
                visualDensity: altChipDensity,
                avatarBoxConstraints: altChipIconBounds,
                avatar: const Icon(AltIcons.translate, size: 18),
                label: Text(
                  '${t('translationToggle')} · ${translate ? '${automaticLanguage ? t('cloudAutoLanguage') : sourceLanguage} → $targetLanguage' : t('sourceOff')}',
                ),
                onPressed: session
                    ? null
                    : () => setState(() => translate = !translate),
              ),
            ],
          ),
        ),
        if (fileMode && fileOptions.any((v) => v))
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: TextFormField(
              key: const Key('preferred-spellings'),
              enabled: !session,
              initialValue: preferredSpellings,
              minLines: 2,
              maxLines: 4,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: t('preferredSpellings'),
                helperText: t('spellingsHint'),
                helperMaxLines: 3,
              ),
              onChanged: (value) => preferredSpellings = value,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: pageStack([
            startButton(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  !fileMode && !microphone && !systemAudio
                      ? AltIcons.error
                      : AltIcons.checkCircle,
                  size: 18,
                  color: !fileMode && !microphone && !systemAudio
                      ? colors.error
                      : colors.primary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    live.backgroundFinishing
                        ? t('backgroundFinishingHint')
                        : !fileMode && !microphone && !systemAudio
                        ? t('noSource')
                        : fileMode
                        ? '${filePaths.length} ${t('filesInQueue')} · ${t('fileQueueHint')}'
                        : modelSummary,
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ], gap: 12),
        ),
      ], gap: 0),
      radius: 28,
    ),
    pageColumns(
      context,
      languageSection(),
      pagePanel(
        context,
        pageStack([
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(t('engine'), style: text.titleMedium),
          ),
          infoRow(
            AltIcons.graphicEq,
            t('model'),
            modelSummary,
            modelSettings,
            smallTitle: true,
          ),
          infoRow(
            AltIcons.translate,
            'LLM',
            llmSummary,
            translationSettings,
            smallTitle: true,
          ),
          infoRow(
            AltIcons.headsetMic,
            t('audio'),
            audioSummary,
            audioSettings,
            smallTitle: true,
          ),
        ], gap: 0),
      ),
    ),
    if (live.cloudSpeech)
      pageHint(context, t(fileMode ? 'cloudFileHint' : 'cloudAudioNotice')),
    if (live.error != null)
      Text(issue(live.error!), style: TextStyle(color: colors.error)),
    if (live.warning != null) Text(issue(live.warning!)),
    pagePanel(
      context,
      pageStack([
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
          child: Row(
            children: [
              Expanded(child: Text(t('recent'), style: text.titleMedium)),
              TextButton(onPressed: () => selectPage(1), child: Text(t('all'))),
            ],
          ),
        ),
        for (final record in live.records.take(2))
          infoRow(
            record.summary == null
                ? AltIcons.description
                : AltIcons.autoAwesome,
            record.displayTitle,
            '${record.dateTimeLabel} · ${record.lines.length} ${t('segments')}',
            () => showRecord(record),
          ),
        if (live.records.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: pageHint(context, t('emptyLibraryHint')),
          ),
      ], gap: 0),
    ),
    if (fileMode)
      pagePanel(
        context,
        ExpansionTile(
          key: const PageStorageKey('file-processing-options'),
          title: Text(t('fileOptions')),
          shape: const Border(),
          children: [
            for (var i = 0; i < 3; i++)
              CheckboxListTile(
                key: ValueKey('file-option-$i'),
                title: Text(t(['unifyNames', 'unifyTerms', 'correctWords'][i])),
                value: fileOptions[i],
                onChanged: session
                    ? null
                    : (value) => setState(() => fileOptions[i] = value!),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: pageHint(context, t('cleanupHint')),
            ),
          ],
        ),
      ),
  ]);

  Widget languageSection() => pagePanel(
    context,
    pageStack([
      Row(
        children: [
          Text(t('languages'), style: text.titleMedium),
          const SizedBox(width: 20),
          Text(t('translationToggle'), style: text.bodyMedium),
          const SizedBox(width: 8),
          Switch(
            key: const Key('translate'),
            value: translate,
            onChanged: session
                ? null
                : (value) => setState(() => translate = value),
          ),
        ],
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (automaticLanguage)
            OutlinedButton(onPressed: null, child: Text(t('cloudAutoLanguage')))
          else
            languagePicker(
              t('sourceLanguage'),
              sourceLanguage,
              (v) => setState(() => sourceLanguage = v!),
              const Key('source-language'),
            ),
          if (translate) ...[
            IconButton(
              key: const Key('swap-languages'),
              tooltip: t('swap'),
              onPressed: session || automaticLanguage
                  ? null
                  : () {
                      if (swapAnimation.isAnimating) return;
                      setState(() {
                        previousSource = sourceLanguage;
                        previousTarget = targetLanguage;
                        final old = sourceLanguage;
                        sourceLanguage = targetLanguage;
                        targetLanguage = old;
                        swapCount++;
                      });
                      if (!MediaQuery.disableAnimationsOf(context)) {
                        swapAnimation.forward(from: 0);
                      }
                    },
              icon: AnimatedRotation(
                turns: swapCount * .5,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 500),
                curve: altSpatial,
                child: const Icon(AltIcons.swapHoriz),
              ),
            ),
            languagePicker(
              t('targetLanguage'),
              targetLanguage,
              (v) => setState(() => targetLanguage = v!),
              const Key('target-language'),
            ),
          ],
        ],
      ),
      pageHint(
        context,
        t(
          directTranslation
              ? 'cloudDirectHint'
              : translate
              ? 'translationHint'
              : 'translationOff',
        ),
      ),
    ], gap: 12),
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
  );

  Widget languagePicker(
    String label,
    String value,
    ValueChanged<String?> onChanged,
    Key key,
  ) => PopupMenuButton<String>(
    key: key,
    tooltip: label,
    enabled: !session,
    onSelected: onChanged,
    itemBuilder: (_) => [
      for (final language in languageCodes.keys)
        PopupMenuItem(value: language, child: Text(language)),
    ],
    child: AnimatedBuilder(
      animation: swapAnimation,
      builder: (context, _) {
        final progress = swapAnimation.value;
        final opacity = progress < .45
            ? 1 - altSpatial.transform(progress / .45).clamp(0.0, 1.0)
            : progress < .55
            ? 0.0
            : altSpatial.transform((progress - .55) / .45).clamp(0.0, 1.0);
        final previous = key == const Key('source-language')
            ? previousSource
            : previousTarget;
        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: .85 + .15 * opacity,
            child: IgnorePointer(
              child: OutlinedButton(
                onPressed: () {},
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(progress < .48 ? previous ?? value : value),
                    const SizedBox(width: 8),
                    const Icon(AltIcons.arrowDropDown, size: 20),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget startButton() => FilledButton.icon(
    key: const Key('start'),
    style:
        FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 96),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          iconSize: 32,
          textStyle: text.headlineSmall?.copyWith(
            fontWeight: FontWeight.w400,
            fontVariations: const [],
          ),
        ).copyWith(
          shape: WidgetStateProperty.resolveWith(
            (states) => RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                states.contains(WidgetState.pressed) ? 16 : 999,
              ),
            ),
          ),
        ),
    onPressed:
        session ||
            !live.initialized ||
            (fileMode ? filePaths.isEmpty : !microphone && !systemAudio)
        ? null
        : () {
            setState(() => minimized = false);
            if (fileMode) {
              live.startFiles(
                paths: filePaths,
                language: languageCodes[sourceLanguage]!,
                targetLanguage: translate
                    ? languageCodes[targetLanguage]
                    : null,
                summaryLanguage: widget.english ? 'en' : 'zh',
                options: CleanupOptions(
                  names: fileOptions[0],
                  terms: fileOptions[1],
                  corrections: fileOptions[2],
                  spellings: preferredSpellings
                      .split(RegExp(r'[,，\n]'))
                      .map((s) => s.trim())
                      .where((s) => s.isNotEmpty)
                      .toSet()
                      .toList(),
                ),
              );
            } else {
              live.start(
                microphone: microphone,
                system: systemAudio,
                language: languageCodes[sourceLanguage]!,
                targetLanguage: translate
                    ? languageCodes[targetLanguage]
                    : null,
                summaryLanguage: widget.english ? 'en' : 'zh',
              );
            }
          },
    icon: Icon(fileMode ? AltIcons.folderOpen : AltIcons.playArrow),
    label: Text(t(fileMode ? 'startFiles' : 'start')),
  );

  String get sessionTitle => t(switch (live.phase) {
    SessionPhase.loading => 'loadingModel',
    SessionPhase.stopping =>
      live.generatingSummary ? 'generatingSummary' : 'stopping',
    SessionPhase.paused => 'paused',
    SessionPhase.fileProcessing => live.fileTask?.stage ?? 'fileTranscribing',
    _ => 'listening',
  });

  Future<void> discardSession() async {
    var ownsConfirmation = false;
    try {
      ownsConfirmation = await live.beginDiscardConfirmation();
      if (!ownsConfirmation) return;
      if (!mounted || !paused) return;
      final confirmed = await confirmRemoval(
        context,
        widget.english,
        'discardSession',
        t('discardSessionHint'),
        'confirm-discard',
      );
      if (confirmed && mounted && paused) {
        await live.discard();
        if (live.error != null) throw StateError(live.error!);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(issue(e.toString()))));
      }
    } finally {
      if (ownsConfirmation) live.endDiscardConfirmation();
    }
  }

  Future<void> stopSession() async {
    try {
      await live.stopAndSave();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(issue(e.toString()))));
      }
    }
  }

  Widget sessionToolbar() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      sessionControls(),
      if (!live.processingFiles) ...[
        const SizedBox(width: 12),
        IconButton.filledTonal(
          key: const Key('discard-session'),
          tooltip: t('discardSession'),
          style: IconButton.styleFrom(
            backgroundColor: colors.surfaceContainerHigh,
            foregroundColor: colors.error,
            fixedSize: const Size(40, 40),
          ),
          onPressed:
              (paused || live.phase == SessionPhase.listening) &&
                  !live.pausePending &&
                  !confirmingDiscard
              ? discardSession
              : null,
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
    ],
  );

  Widget sessionControls() => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      boxShadow: altFloatingShadow,
    ),
    child: Material(
      color: colors.primaryContainer,
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!live.processingFiles)
                IconButton(
                  style: IconButton.styleFrom(
                    fixedSize: Size(narrow ? 40 : 48, 40),
                  ),
                  key: const Key('pause'),
                  tooltip: t(paused ? 'resume' : 'pause'),
                  onPressed:
                      (live.phase == SessionPhase.listening || paused) &&
                          !live.pausePending &&
                          !confirmingDiscard
                      ? live.togglePause
                      : null,
                  icon: Icon(
                    paused ? AltIcons.playArrow : AltIcons.pause,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              if (!live.processingFiles) const SizedBox(width: 4),
              IconButton(
                style: IconButton.styleFrom(
                  fixedSize: Size(narrow ? 40 : 48, 40),
                ),
                key: const Key('caption-smaller'),
                tooltip: t('smallerCaptions'),
                onPressed: captionSize > 16
                    ? () => setState(() => captionSize -= 2)
                    : null,
                icon: Icon(
                  AltIcons.textDecrease,
                  color: colors.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                style: IconButton.styleFrom(
                  fixedSize: Size(narrow ? 40 : 48, 40),
                ),
                key: const Key('caption-larger'),
                tooltip: t('largerCaptions'),
                onPressed: captionSize < 36
                    ? () => setState(() => captionSize += 2)
                    : null,
                icon: Icon(
                  AltIcons.textIncrease,
                  color: colors.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('stop'),
                onPressed:
                    live.phase == SessionPhase.stopping || confirmingDiscard
                    ? null
                    : stopSession,
                icon: const Icon(AltIcons.stop, size: 20),
                label: Text(
                  t(
                    live.processingFiles
                        ? 'cancelFile'
                        : live.phase == SessionPhase.loading
                        ? 'cancel'
                        : 'stop',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  void restoreSession() {
    setState(() {
      page = 0;
      minimized = false;
    });
    scheduleFollow();
  }

  Widget miniSession() => SizedBox(
    width: math.min(480, MediaQuery.sizeOf(context).width - 48),
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: altFloatingShadow,
      ),
      child: Material(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('restore-session'),
          onTap: restoreSession,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (paused)
                      const Icon(AltIcons.pauseCircle, size: 28)
                    else
                      AltLoading(size: 28, shape: sessionShape),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        sessionTitle,
                        style: text.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!live.processingFiles)
                      captionToggle('mini-captions', compact: true),
                    if (!live.processingFiles)
                      IconButton(
                        tooltip: t(paused ? 'resume' : 'pause'),
                        onPressed:
                            (paused || live.phase == SessionPhase.listening) &&
                                !live.pausePending &&
                                !confirmingDiscard
                            ? live.togglePause
                            : null,
                        icon: Icon(
                          paused ? AltIcons.playArrow : AltIcons.pause,
                        ),
                      ),
                    if (!live.processingFiles) const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: t('liveSession'),
                      onPressed: restoreSession,
                      icon: const Icon(AltIcons.openInFull),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  live.record?.lines.lastOrNull?.displayText ??
                      t('waitingSpeech'),
                  key: const Key('mini-transcript'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
                if (live.record?.targetLanguage != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    live.record?.lines.lastOrNull?.displayTranslation ??
                        t(switch (live
                            .record
                            ?.lines
                            .lastOrNull
                            ?.translationStatus) {
                          'failed' => 'translationFailed',
                          'interrupted' => 'translationInterrupted',
                          _ => 'translationPending',
                        }),
                    key: const Key('mini-translation'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );

  String elapsedLabel(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 999999999);
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget fileSessionPage() => pageStack([
    pagePanel(
      context,
      pageStack([
        Row(
          children: [
            AltLoading(shape: sessionShape),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sessionTitle, style: text.titleLarge),
                  Text(
                    '${live.fileNumber} / ${live.fileCount} · ${live.record?.displayTitle ?? t('file')}',
                    style: text.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(
              visualDensity: altChipDensity,
              avatarBoxConstraints: altChipIconBounds,
              avatar: const Icon(AltIcons.audioFile, size: 18),
              label: Text(t('file')),
            ),
            Chip(
              visualDensity: altChipDensity,
              avatarBoxConstraints: altChipIconBounds,
              avatar: const Icon(AltIcons.memory, size: 18),
              label: Text(live.speechBackend),
            ),
            if (translate || fileOptions.any((v) => v) || live.generateSummary)
              Chip(
                visualDensity: altChipDensity,
                avatarBoxConstraints: altChipIconBounds,
                avatar: const Icon(AltIcons.translate, size: 18),
                label: Text('LLM · ${live.translator.backend}'),
              ),
          ],
        ),
        LinearProgressIndicator(
          minHeight: 8,
          borderRadius: BorderRadius.circular(4),
        ),
        Text(
          '${t('processedAudio')}: ${elapsedLabel(Duration(milliseconds: live.fileTask?.processedMs ?? 0))}',
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ]),
      radius: 28,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
    ),
    if (live.record?.cleanupError != null)
      Text(
        issue(live.record!.cleanupError!),
        style: TextStyle(color: colors.error),
      ),
    if (live.error != null)
      Text(issue(live.error!), style: TextStyle(color: colors.error)),
    Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: pageStack([
        for (final line in live.record?.lines ?? <TranscriptLine>[])
          TranscriptTile(
            line: line,
            english: widget.english,
            captionSize: captionSize,
            highlight:
                showSession && identical(line, live.record?.lines.lastOrNull),
            awaitingTranslation: awaitingTranslation(line),
          ),
      ], gap: 4),
    ),
  ]);

  Widget sessionPage() => live.processingFiles
      ? fileSessionPage()
      : pageStack([
          pagePanel(
            context,
            pageStack([
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (paused)
                        Icon(
                          AltIcons.pauseCircle,
                          size: 40,
                          color: colors.primary,
                        )
                      else
                        AltLoading(shape: sessionShape),
                      const SizedBox(width: 16),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(sessionTitle, style: text.titleLarge),
                            Text(
                              '${t('elapsed')} ${elapsedLabel(DateTime.now().difference(live.record?.createdAt ?? DateTime.now()))} · ${live.record?.language == 'auto' ? t('cloudAutoLanguage') : sourceLanguage}${translate ? ' → $targetLanguage' : ''}',
                              style: text.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (live.record?.sources.contains('microphone') == true)
                        Chip(
                          visualDensity: altChipDensity,
                          avatarBoxConstraints: altChipIconBounds,
                          avatar: const Icon(AltIcons.mic, size: 18),
                          label: Text(t('microphone')),
                        ),
                      if (live.record?.sources.contains('system') == true)
                        Chip(
                          visualDensity: altChipDensity,
                          avatarBoxConstraints: altChipIconBounds,
                          avatar: const Icon(AltIcons.volumeUp, size: 18),
                          label: Text(t('systemAudio')),
                        ),
                      Chip(
                        visualDensity: altChipDensity,
                        avatarBoxConstraints: altChipIconBounds,
                        avatar: const Icon(AltIcons.memory, size: 18),
                        label: Text(live.speechBackend),
                      ),
                      if ((translate &&
                              live.record?.directTranslation != true) ||
                          live.generateSummary)
                        Chip(
                          visualDensity: altChipDensity,
                          avatarBoxConstraints: altChipIconBounds,
                          avatar: const Icon(AltIcons.translate, size: 18),
                          label: Text('LLM · ${live.translator.backend}'),
                        ),
                    ],
                  ),
                ],
              ),
              for (final source in [
                if (live.record?.sources.contains('microphone') == true)
                  'microphone',
                if (live.record?.sources.contains('system') == true) 'system',
              ])
                Row(
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        t(source == 'system' ? 'systemAudio' : 'microphone'),
                        style: text.labelLarge?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: AudioLevelHistory(
                        key: ValueKey('level-history-$source'),
                        samples: live.levelHistory[source] ?? const [],
                        running: live.phase == SessionPhase.listening,
                        label:
                            '${t(source == 'system' ? 'systemAudio' : 'microphone')} · ${t('volumeHistory')}',
                        color: source == 'microphone'
                            ? colors.primary
                            : colors.tertiary,
                      ),
                    ),
                  ],
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    t('volumeHistory'),
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    t('latestLevel'),
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              LayoutBuilder(
                builder: (context, constraints) => RecordingWave(
                  running: live.phase == SessionPhase.listening,
                  // The histories reserve 96 px for the label and a 16 px gap.
                  historyWidth: constraints.maxWidth - 112,
                ),
              ),
              Text(
                [
                  if (!live.cloudSpeech)
                    '${t('pendingAudio')}: ${live.pending} · ${t('lastInference')}: ${live.lastInferenceSeconds.toStringAsFixed(1)} s',
                  if (translate && live.record?.directTranslation != true)
                    '${t('pendingTranslations')}: ${live.pendingTranslations} · ${t('lastTranslation')}: ${live.lastTranslationSeconds.toStringAsFixed(1)} s',
                ].join(' · '),
                style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ]),
            radius: 28,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          ),
          if (live.warning != null) Text(issue(live.warning!)),
          if (live.error != null)
            Text(issue(live.error!), style: TextStyle(color: colors.error)),
          if (live.record?.lines.isEmpty ?? true)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(t('waitingSpeech'), textAlign: TextAlign.center),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: pageStack([
              for (final line in live.record?.lines ?? <TranscriptLine>[])
                TranscriptTile(
                  line: line,
                  english: widget.english,
                  captionSize: captionSize,
                  highlight:
                      showSession &&
                      identical(line, live.record?.lines.lastOrNull),
                  awaitingTranslation: awaitingTranslation(line),
                ),
            ], gap: 4),
          ),
        ]);
}
