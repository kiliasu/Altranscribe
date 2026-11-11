import 'package:altranscribe/features/records/record_detail_dialog.dart';
import 'package:altranscribe/shared/ui/page_layout.dart';
import 'package:altranscribe/app/l10n/localized_issue.dart';
import 'package:altranscribe/shared/ui/confirmation_dialog.dart';
import 'package:altranscribe/shared/ui/elapsed_text.dart';
import 'package:altranscribe/shared/ui/motion.dart';
import 'package:altranscribe/shared/ui/transcript_tile.dart';
import 'package:altranscribe/shared/ui/transcript_scroll_controller.dart';
import 'package:altranscribe/features/records/records_screen.dart';
import 'package:altranscribe/features/remote/devices_screen.dart';
import 'package:altranscribe/features/settings/settings_screen.dart';
import 'package:altranscribe/data/models/transcript_record.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show ScrollDirection;
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
  final fileOptions = <bool>[false, false, false, false];
  List<String> filePaths = [];
  String preferredSpellings = '';
  final scrollBucket = PageStorageBucket();
  late final sessionScroll = TranscriptScrollController(
    following: () => followLatest && followArmed,
  );
  bool followLatest = true;
  bool followScheduled = false;

  /// The next layout may move to the end: the transcript changed, the page
  /// was entered or following was turned on. Other layouts, such as rows
  /// built while the user scrolls, keep the reading position.
  bool followArmed = false;

  /// The reader is scrolling the transcript by hand.
  bool userScrolling = false;

  /// How many lines of [shownRecord] the session page had built. A line
  /// beyond them rises in when it first appears; one the reader scrolls
  /// back to does not.
  int shownLines = 0;
  String? shownRecord;

  /// The transcript a session just saved, acknowledged for a moment.
  TranscriptRecord? acknowledged;
  Timer? acknowledgeTimer;
  bool wasSession = false;
  int transcriptRevision = -1;
  String? anchorRecord;

  @override
  void initState() {
    super.initState();
    live.addListener(refresh);
    live.sharedHost.addListener(refresh);
    MobilePlatform.importedFiles.addListener(importMobileFiles);
    WidgetsBinding.instance.addPostFrameCallback((_) => importMobileFiles());
    wasSession = session;
    scheduleFollow();
  }

  void refresh() {
    if (!mounted) return;
    sessionScroll.captureAnchor();
    if (anchorRecord != live.record?.id) {
      sessionScroll.resetAnchors();
      anchorRecord = live.record?.id;
    }
    if (session && !wasSession) {
      sessionShape = math.Random().nextInt(AltLoading.shapeCount);
      followLatest = true;
      minimized = false;
    }
    final contentChanged = transcriptRevision != live.transcriptRevision;
    transcriptRevision = live.transcriptRevision;
    final ended = wasSession && !session;
    wasSession = session;
    // Lines that arrive while the page is away appear without rising in.
    if (!showSession && live.record?.id == shownRecord) {
      shownLines = live.record?.lines.length ?? 0;
    }
    setState(() {});
    if (contentChanged) scheduleFollow();
    if (ended) acknowledgeSession();
  }

  /// A finished session or file run ends with a checkmark where its bar
  /// was, and the way to the transcript it saved.
  void acknowledgeSession() {
    final record = live.record;
    final saved = live.records
        .where((item) => item.id == record?.id)
        .firstOrNull;
    if (saved == null || saved.status != 'completed' || live.error != null) {
      return;
    }
    acknowledgeTimer?.cancel();
    setState(() => acknowledged = saved);
    acknowledgeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => acknowledged = null);
    });
  }

  Widget acknowledgement(TranscriptRecord saved) {
    final label = saved.inputFile == null
        ? t('sessionSaved')
        : live.fileCount > 1
        ? t('filesDone').replaceFirst('{count}', '${live.fileCount}')
        : t('fileDone');
    return DecoratedBox(
      key: ValueKey(saved.id),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: altFloatingShadow,
      ),
      child: Material(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DrawnCheckmark(
                key: const Key('session-saved'),
                size: 24,
                color: colors.primary,
                checkColor: colors.onPrimary,
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  '$label · ${saved.displayTitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const Key('open-saved'),
                onPressed: () {
                  acknowledgeTimer?.cancel();
                  setState(() => acknowledged = null);
                  showRecord(saved);
                },
                child: Text(t('openRecord')),
              ),
            ],
          ),
        ),
      ),
    );
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
    if (!followLatest || !showSession) return;
    followArmed = true;
    if (followScheduled) return;
    followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      followScheduled = false;
      if (mounted && showSession && followLatest && sessionScroll.hasClients) {
        if ((sessionScroll.offset - sessionScroll.position.maxScrollExtent)
                .abs() >
            .1) {
          sessionScroll.jumpTo(sessionScroll.position.maxScrollExtent);
        }
      }
      // The jump's own layout may still correct the end of a list whose
      // length was estimated; after that frame, positions are kept again.
      WidgetsBinding.instance.addPostFrameCallback((_) => followArmed = false);
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Back to the latest line, however far away it is, following again.
  void jumpToLatest() {
    setState(() => followLatest = true);
    if (sessionScroll.hasClients) {
      sessionScroll.jumpTo(sessionScroll.position.maxScrollExtent);
    }
    scheduleFollow();
  }

  /// Scrolling away from the end by hand stops following, and reaching the
  /// end again follows once more. Only the reader's own scrolling counts:
  /// new text and the jumps that follow it move the view without a
  /// direction.
  bool onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is UserScrollNotification) {
      sessionScroll.releaseAnchor();
      userScrolling = notification.direction != ScrollDirection.idle;
    }
    if (!showSession || notification is! ScrollUpdateNotification) {
      return false;
    }
    if (!userScrolling && notification.dragDetails == null) return false;
    final metrics = notification.metrics;
    final distance = metrics.maxScrollExtent - metrics.pixels;
    if (followLatest && distance > 48) {
      setState(() => followLatest = false);
    } else if (!followLatest && distance < 8) {
      setState(() => followLatest = true);
    }
    return false;
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
    swapAnimation.dispose();
    sessionScroll.dispose();
    acknowledgeTimer?.cancel();
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

  /// File lines wait for the entire transcript before translation can start.
  /// Hold their translation space throughout that wait as well.
  bool awaitingTranslation(TranscriptLine line) {
    final current = live.record;
    return live.active &&
        current != null &&
        current.targetLanguage != null &&
        current.targetLanguage != current.language &&
        !current.directTranslation &&
        (live.processingFiles || line.transcriptionStatus == 'partial') &&
        line.translationStatus != 'done';
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
      0 => showSession ? const SizedBox.shrink() : transcribePage(),
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
                                  if (showSession && !live.processingFiles)
                                    captionToggle('session-captions'),
                                ],
                              ),
                            ),
                            Expanded(
                              child: PageStorage(
                                bucket: scrollBucket,
                                child: NotificationListener<ScrollNotification>(
                                  onNotification: onScroll,
                                  child: showSession
                                      ? sessionBody(narrow)
                                      : SingleChildScrollView(
                                          key: PageStorageKey(
                                            'page-$page-$showSession-$fileMode',
                                          ),
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
                                              child: pageTransition(
                                                pageContent,
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
            if (showSession)
              Positioned(
                left: 16,
                right: 16,
                bottom: (narrow ? 96 : 20) + 76,
                child: Center(child: jumpToLatestButton()),
              ),
            if (!session || live.backgroundFinishing)
              Positioned(
                left: 16,
                right: 16,
                bottom: narrow ? 96 : 20,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: AltMotion.content,
                    transitionBuilder: AltMotion.rise,
                    // It belongs to the page the session ran on; the
                    // library lists the saved transcript itself.
                    child: acknowledged == null || page != 0
                        ? const SizedBox.shrink()
                        : acknowledgement(acknowledged!),
                  ),
                ),
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
        return 'Whisper · Remote · ${t('noRemote')}';
      }
      return 'Whisper · Remote · ${live.remoteConnection.name.isEmpty ? t('noRemote') : live.remoteConnection.name} · ${live.sessionModel}';
    }
    if (live.speechProvider == SpeechProvider.nemotron) {
      return 'Nemotron · ${ModelCatalog.nemotron(live.nemotronModel)?.shortLabel ?? live.nemotronModel} · CPU';
    }
    if (live.transcribeSpeech) {
      return 'Transcribe · NVFP4 · GPU';
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

  /// The chosen on-device model is not on disk, for example after removal.
  bool get localModelMissing {
    final available = live.catalog.availability;
    if (available.isEmpty || live.remoteProcessing || live.cloudSpeech) {
      return false;
    }
    if (live.speechProvider == SpeechProvider.nemotron) {
      return available[live.nemotronModel] != ModelAvailability.available;
    }
    if (live.transcribeSpeech) {
      return available[live.transcribeModel] != ModelAvailability.available;
    }
    final model = ModelCatalog.models
        .where((item) => live.model == live.catalog.path(item))
        .firstOrNull;
    return model != null && available[model.id] != ModelAvailability.available;
  }

  /// Progress of a model download, shown outside the model settings too.
  Widget? downloadProgress() {
    final catalog = live.catalog;
    final model = catalog.downloadingModel;
    if (model == null) return null;
    final waiting =
        catalog.downloadStage == DownloadStage.retrying ||
        (catalog.downloadStage == DownloadStage.connecting &&
            catalog.receivedBytes == 0);
    final name = model is NemotronModel
        ? 'Nemotron · ${model.shortLabel}'
        : model is TranscribeModel
        ? 'Transcribe · NVFP4'
        : 'Whisper · ${model.label}';
    return Column(
      key: const Key('home-model-download'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: waiting ? null : catalog.receivedBytes / model.bytes,
        ),
        const SizedBox(height: 4),
        Text(
          '${t('modelDownloading')} · $name · ${catalog.downloadStage == DownloadStage.retrying
              ? t('modelRetrying')
              : waiting
              ? t('modelConnecting')
              : '${catalog.receivedBytes * 100 ~/ model.bytes}%'}',
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
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
    Widget? footer,
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
                  ?footer,
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
                            // Joining sentences requires its own explicit opt-in.
                            fileOptions[i] = value && i < 3;
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
            pageStack([
              speechStatus(),
              if (llmNeeded && !live.backgroundFinishing) llmStatus(),
            ], gap: 4),
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
          ListenableBuilder(
            listenable: live.catalog,
            builder: (context, _) => infoRow(
              AltIcons.graphicEq,
              t('model'),
              localModelMissing
                  ? '$modelSummary · ${t('model_missing')}'
                  : modelSummary,
              modelSettings,
              smallTitle: true,
              footer: downloadProgress(),
            ),
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
            for (var i = 0; i < fileOptions.length; i++)
              CheckboxListTile(
                key: ValueKey('file-option-$i'),
                title: Text(
                  t(
                    [
                      'unifyNames',
                      'unifyTerms',
                      'correctWords',
                      'mergeSentences',
                    ][i],
                  ),
                ),
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

  /// The speech side of starting: sources, the model and its files.
  Widget speechStatus() => ListenableBuilder(
    listenable: live.catalog,
    builder: (context, _) {
      final noSource = !fileMode && !microphone && !systemAudio;
      final missing = !noSource && localModelMissing;
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            noSource || missing ? AltIcons.error : AltIcons.checkCircle,
            size: 18,
            color: noSource || missing ? colors.error : colors.primary,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              live.backgroundFinishing
                  ? t('backgroundFinishingHint')
                  : noSource
                  ? t('noSource')
                  : missing
                  ? '$modelSummary · ${t('model_missing')}'
                  : fileMode
                  ? '${filePaths.length} ${t('filesInQueue')} · ${t('fileQueueHint')}'
                  : modelSummary,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      );
    },
  );

  /// Translation, the title and summary, or file cleanup call the text model.
  bool get llmNeeded =>
      live.generateSummary ||
      (translate && !directTranslation && sourceLanguage != targetLanguage) ||
      (fileMode && fileOptions.any((v) => v));

  /// One line of the text model's status, with an optional button.
  Widget llmNote(
    IconData icon,
    String message, {
    Color? tint,
    Widget? action,
  }) => ConstrainedBox(
    key: const Key('llm-status'),
    constraints: const BoxConstraints(minHeight: 28),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: tint ?? colors.onSurfaceVariant),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
        if (action != null) ...[const SizedBox(width: 4), action],
      ],
    ),
  );

  /// Whether the text model is loaded, with a way to load it before starting.
  /// While Transcribe would share the GPU with a local text model, files
  /// load the model after transcription, and live sessions translate after
  /// stopping or estimate the GPU memory. Online models need no loading.
  Widget llmStatus() {
    if (live.llmSharesGpu) {
      if (fileMode) return llmNote(AltIcons.schedule, t('llmAfterTranscribe'));
      if (live.liveLlm == LiveLlm.shared) {
        return live.sharedGpuFits
            ? llmNote(
                AltIcons.memory,
                t('gpuEstimate')
                    .replaceFirst('{need}', gigabytes(live.sharedGpuNeed!))
                    .replaceFirst('{total}', gigabytes(live.gpuTotal!)),
              )
            : llmNote(
                AltIcons.warning,
                issue(live.sharedGpuWarning),
                tint: colors.error,
              );
      }
      if (live.liveLlm == LiveLlm.afterStop) {
        return llmNote(
          AltIcons.schedule,
          t('llmTranslateAfterStop'),
          action: TextButton(
            key: const Key('set-live-cloud'),
            style: TextButton.styleFrom(visualDensity: altChipDensity),
            onPressed: session ? null : translationSettings,
            child: Text(t('setCloudModel')),
          ),
        );
      }
    }
    // An online model needs no loading; the engines name it.
    if (live.llmOnline) return llmNote(AltIcons.cloud, t('cloudModel'));
    final check = live.llmCheck;
    final state = check?.state;
    final failed = state == LlmCheckState.failed;
    final ready = state == LlmCheckState.ready;
    final message = switch (state) {
      null => t('llmUnchecked'),
      LlmCheckState.checking => t('llmChecking'),
      LlmCheckState.ready => t('llmReady'),
      LlmCheckState.failed =>
        '${t('llmCheckFailed')} · ${issue(check!.error!)}',
    };
    return ConstrainedBox(
      key: const Key('llm-status'),
      // As tall as its button (32 less the chip density), so the panel keeps
      // still while the button is hidden.
      constraints: const BoxConstraints(minHeight: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (state == LlmCheckState.checking)
            AltLoading(size: 18, shape: sessionShape)
          else
            Icon(
              failed
                  ? AltIcons.error
                  : ready
                  ? AltIcons.checkCircle
                  : AltIcons.memory,
              size: 18,
              color: failed
                  ? colors.error
                  : ready
                  ? colors.primary
                  : colors.onSurfaceVariant,
            ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: failed ? colors.error : colors.onSurfaceVariant,
              ),
            ),
          ),
          if (state != LlmCheckState.checking) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: t('llmPrepareHint'),
              child: TextButton(
                key: const Key('llm-prepare'),
                style: TextButton.styleFrom(visualDensity: altChipDensity),
                onPressed: session || !live.initialized ? null : live.checkLlm,
                child: Text(
                  t(
                    state == null
                        ? 'llmPrepare'
                        : failed
                        ? 'llmRetry'
                        : 'llmCheckAgain',
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

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
            live.removingModel ||
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
                  mergeSentences: fileOptions[3],
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
      // While the bar narrows with the window, it fits the room it has.
      Flexible(child: sessionControls()),
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

  /// The input levels of all sources at once, loudest first.
  List<double> get levelSamples {
    final lists = live.levelHistory.values.where((list) => list.isNotEmpty);
    if (lists.isEmpty) return const [];
    if (lists.length == 1) return lists.first;
    final length = lists.map((list) => list.length).reduce(math.max);
    return [
      for (var i = 0; i < length; i++)
        lists
            .map((list) {
              final j = list.length - length + i;
              return j < 0 ? 0.0 : list[j];
            })
            .reduce(math.max),
    ];
  }

  /// What the session is doing, at the bar's leading edge, where it stays
  /// in view however far the transcript has grown: a pulsing dot, the time
  /// spent listening and the input level while capturing, otherwise a
  /// spinner and the stage.
  Widget sessionStatus() {
    final phase = live.phase;
    final foreground = colors.onPrimaryContainer;
    final label = text.labelLarge?.copyWith(color: foreground);
    if (live.processingFiles) {
      return const SizedBox.shrink(key: ValueKey('files'));
    }
    if (phase == SessionPhase.listening || phase == SessionPhase.paused) {
      final pending = live.pendingTranslations;
      return Row(
        key: const ValueKey('capturing'),
        mainAxisSize: MainAxisSize.min,
        children: [
          PulsingDot(
            color: paused ? colors.tertiary : recordingRed,
            pulsing: !paused,
          ),
          const SizedBox(width: 10),
          // A clock that ticks every second stays still between ticks;
          // only counts that change now and then roll.
          ElapsedText.reading(
            () => live.listened,
            key: const Key('session-clock'),
            label: durationLabel,
            style: label?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (!narrow) ...[
            const SizedBox(width: 14),
            LevelMeter(
              samples: paused ? const [] : levelSamples,
              color: foreground.withValues(alpha: .7),
            ),
          ],
          AnimatedSize(
            duration: AltMotion.quick,
            curve: AltMotion.quickCurve,
            child: pending > 0 && translate
                ? Tooltip(
                    message: t('pendingCount')
                        .replaceFirst('{count}', '$pending'),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 14),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(AltIcons.translate, size: 16, color: foreground),
                          const SizedBox(width: 4),
                          RollingText('$pending', style: label),
                        ],
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      );
    }
    return Row(
      key: ValueKey('working $phase'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
        ),
        const SizedBox(width: 10),
        Text(sessionTitle, style: label),
      ],
    );
  }

  /// The floating bar. Its status and its controls change with the
  /// session's stage, and the bar takes the new width smoothly.
  Widget sessionControls() {
    final capturing =
        live.phase == SessionPhase.listening ||
        live.phase == SessionPhase.paused;
    final button = IconButton.styleFrom(fixedSize: Size(narrow ? 40 : 48, 40));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: altFloatingShadow,
      ),
      child: Material(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(999),
        // A size animation that took no time would change its own layout
        // while laying out; with reduced motion it is only short.
        child: AnimatedSize(
          duration: AltMotion.reduced(context)
              ? AltMotion.fade
              : AltMotion.content,
          curve: AltMotion.contentCurve,
          child: SizedBox(
            height: 64,
            child: Padding(
              padding: EdgeInsets.only(
                left: live.processingFiles ? 8 : (narrow ? 16 : 20),
                right: 8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: AltMotion.content,
                    transitionBuilder: AltMotion.rise,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.centerLeft,
                      children: [...previous, ?current],
                    ),
                    child: sessionStatus(),
                  ),
                  if (!live.processingFiles) SizedBox(width: narrow ? 12 : 16),
                  if (capturing) ...[
                    IconButton(
                      style: button,
                      key: const Key('pause'),
                      tooltip: t(paused ? 'resume' : 'pause'),
                      onPressed: !live.pausePending && !confirmingDiscard
                          ? live.togglePause
                          : null,
                      icon: AnimatedSwitcher(
                        duration: AltMotion.quick,
                        child: Icon(
                          paused ? AltIcons.playArrow : AltIcons.pause,
                          key: ValueKey(paused),
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  // Where the bar is short of room, the text size buttons
                  // give way to the status before the stop button does.
                  if (!narrow || !capturing) ...[
                    IconButton(
                      style: button,
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
                      style: button,
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
                  ],
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
      ),
    );
  }

  /// Appears above the bar once the reader has scrolled away from the
  /// latest line, and takes them back to it.
  Widget jumpToLatestButton() => AnimatedSwitcher(
    duration: AltMotion.content,
    transitionBuilder: AltMotion.rise,
    child: followLatest || (live.record?.lines.isEmpty ?? true)
        ? const SizedBox.shrink(key: ValueKey('following'))
        : FilledButton.tonalIcon(
            key: const Key('jump-to-latest'),
            style: FilledButton.styleFrom(
              elevation: 3,
              shadowColor: colors.shadow,
            ),
            onPressed: jumpToLatest,
            icon: const Icon(Icons.arrow_downward_rounded, size: 18),
            label: Text(t('jumpToLatest')),
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

  /// The file being processed: which one, its stage and how far it has
  /// come, at what speed and with which models. It stays above the
  /// transcript as that grows, so the progress never scrolls away.
  Widget fileProgressPanel() {
    final task = live.fileTask;
    final record = live.record;
    final stage = task?.stage ?? 'fileTranscribing';
    final fraction = fileProgress;
    final muted = text.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    final icon = switch (stage) {
      'fileTranslating' || 'fileCleaningTranslation' => AltIcons.translate,
      'generatingSummary' => AltIcons.autoAwesome,
      'fileCleaning' || 'filePreparingText' => AltIcons.spellcheck,
      _ => AltIcons.graphicEq,
    };
    final translating =
        record?.targetLanguage != null &&
        record?.targetLanguage != record?.language;
    Widget detail(IconData icon, String value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: colors.onSurfaceVariant),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            value,
            style: muted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    return pagePanel(
      context,
      pageStack([
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                record?.displayTitle ?? t('file'),
                style: text.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (live.fileCount > 1)
              Text(
                t('fileNumber')
                    .replaceFirst('{index}', '${live.fileNumber}')
                    .replaceFirst('{count}', '${live.fileCount}'),
                style: muted,
              ),
          ],
        ),
        pageStack([
          Row(
            children: [
              AnimatedSwitcher(
                duration: AltMotion.quick,
                child: Icon(
                  icon,
                  key: ValueKey(icon),
                  size: 20,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AltMotion.quick,
                  transitionBuilder: AltMotion.rise,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [...previous, ?current],
                  ),
                  child: Text(
                    sessionTitle,
                    key: ValueKey(sessionTitle),
                    style: text.labelLarge,
                  ),
                ),
              ),
              if (fraction != null)
                RollingText(
                  '${(fraction * 100).floor()}%',
                  style: text.labelLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(end: fraction ?? 0),
            duration: AltMotion.reduced(context)
                ? Duration.zero
                : AltMotion.content,
            curve: AltMotion.contentCurve,
            builder: (context, value, _) => LinearProgressIndicator(
              key: const Key('file-progress'),
              value: fraction == null ? null : value,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          if (task != null)
            ElapsedText(
              key: const Key('file-progress-label'),
              since: task.stageStarted,
              label: (_) => fileProgressLabel,
              style: muted?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ], gap: 8),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            detail(AltIcons.memory, live.speechBackend),
            if (translating)
              detail(
                AltIcons.translate,
                '${t('translateTo').replaceFirst('{language}', targetLanguage)} · ${live.llmBackend}',
              ),
            if (live.generateSummary)
              detail(
                AltIcons.autoAwesome,
                '${t('summaryShort')} · ${live.llmBackend}',
              ),
          ],
        ),
        if (live.record?.cleanupError != null)
          Text(
            issue(live.record!.cleanupError!),
            style: TextStyle(color: colors.error),
          ),
        if (live.error != null)
          Text(issue(live.error!), style: TextStyle(color: colors.error)),
      ], gap: 14),
      radius: 24,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
    );
  }

  /// Fades a page in from a slight blur when it is first shown.
  Widget pageTransition(Widget child) => AltPageIn(
    key: ValueKey('page-transition-$page${showSession ? '-session' : ''}'),
    child: child,
  );

  /// The session's page: the live panel then one row per line, or a file's
  /// progress fixed above the transcript it produces. Rows are built only
  /// near the screen, so a thousand lines cost no more to update than ten.
  /// While a live session follows its latest line, the earlier ones recede
  /// and what each new result adds fades in.
  Widget sessionBody(bool narrow) => LayoutBuilder(
    builder: (context, constraints) {
      final side = math.max(
        narrow ? 16.0 : 24.0,
        (constraints.maxWidth - 960) / 2,
      );
      final record = live.record;
      final lines = record?.lines ?? const <TranscriptLine>[];
      final keys = record == null
          ? const <GlobalKey>[]
          : sessionScroll.keysFor(record.id, lines);
      final indexes = {for (final (index, key) in keys.indexed) key: index};
      final files = live.processingFiles;
      final capturing =
          !files &&
          (live.phase == SessionPhase.listening ||
              live.phase == SessionPhase.paused);
      if (shownRecord != record?.id) {
        shownRecord = record?.id;
        shownLines = 0;
      }
      final arrivedFrom = shownLines;
      shownLines = lines.length;
      final reduced = AltMotion.reduced(context);
      Widget row(BuildContext context, int index) {
        final latest = index == lines.length - 1;
        final receded = capturing && followLatest && !latest;
        return Padding(
          key: keys[index],
          padding: EdgeInsets.only(bottom: latest ? 0 : 4),
          child: AltRise(
            animate: session && index >= arrivedFrom,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: receded ? .72 : 1),
              duration: reduced ? AltMotion.fade : AltMotion.settle,
              curve: AltMotion.contentCurve,
              builder: (context, emphasis, _) => TranscriptTile(
                line: lines[index],
                english: widget.english,
                captionSize: captionSize,
                awaitingTranslation: awaitingTranslation(lines[index]),
                animateTranslation: !files,
                streaming: capturing && latest,
                emphasis: emphasis,
              ),
            ),
          ),
        );
      }

      final list = EdgeFade(
        top: 16,
        bottom: 120,
        bottomClear: 64,
        child: CustomScrollView(
          key: PageStorageKey('page-$page-$showSession-$fileMode'),
          controller: sessionScroll,
          slivers: [
            if (!files)
              SliverPadding(
                // Clear of the fade at the top edge until it scrolls.
                padding: EdgeInsets.fromLTRB(side, 16, side, 0),
                sliver: SliverToBoxAdapter(child: sessionPanel()),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                side + 8,
                files ? 16 : 24,
                side + 8,
                120,
              ),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  row,
                  childCount: lines.length,
                  findChildIndexCallback: (key) => indexes[key],
                ),
              ),
            ),
          ],
        ),
      );
      return pageTransition(
        files
            ? Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(side, 8, side, 0),
                    child: fileProgressPanel(),
                  ),
                  Expanded(child: list),
                ],
              )
            : list,
      );
    },
  );

  /// How far the file has come in its current stage: the audio transcribed,
  /// then the lines translated. Null while a stage has no measure.
  double? get fileProgress {
    final task = live.fileTask;
    final record = live.record;
    if (task == null || record == null) return null;
    switch (task.stage) {
      case 'fileTranscribing':
        // The first piece says nothing until it returns; the text below
        // the bar shows how much audio has been read meanwhile.
        final total = task.durationMs;
        if (total == null || total <= 0 || task.processedMs == 0) return null;
        return (task.processedMs / total).clamp(0, 1).toDouble();
      case 'fileTranslating':
        if (record.lines.isEmpty) return null;
        return translatedLines(record) / record.lines.length;
      default:
        return null;
    }
  }

  static int translatedLines(TranscriptRecord record) => record.lines
      .where(
        (line) => const {
          'done',
          'failed',
          'interrupted',
        }.contains(line.translationStatus),
      )
      .length;

  /// The stage's measure, the time it has taken, and once there is enough
  /// to go on, its speed and the time left.
  String get fileProgressLabel {
    final task = live.fileTask;
    final record = live.record;
    if (task == null) return '';
    final now = DateTime.now();
    final elapsed = now.difference(task.stageStarted);
    final measured = task.progressAt?.difference(task.stageStarted);
    final parts = <String>[];
    Duration? left;
    if (task.stage == 'fileTranslating' && record != null) {
      final done = translatedLines(record);
      final total = record.lines.length;
      parts.add(
        t('translatedOf')
            .replaceFirst('{done}', '$done')
            .replaceFirst('{total}', '$total'),
      );
      if (done >= 3 && measured != null && measured.inMilliseconds > 0) {
        left =
            measured * ((total - done) / done) -
            now.difference(task.progressAt!);
      }
    } else if (task.stage == 'fileTranscribing') {
      final processed = Duration(milliseconds: task.processedMs);
      final total = task.durationMs == null
          ? null
          : Duration(milliseconds: task.durationMs!);
      parts.add(
        total == null
            ? '${t('processedAudio')} ${durationLabel(processed)}'
            : t('processedOf')
                  .replaceFirst('{done}', durationLabel(processed))
                  .replaceFirst('{total}', durationLabel(total)),
      );
      if (task.decodedMs > task.processedMs) {
        parts.add(
          '${t('audioRead')} ${durationLabel(Duration(milliseconds: task.decodedMs))}',
        );
      }
      if (processed.inSeconds >= 5 &&
          measured != null &&
          measured.inMilliseconds >= 1000) {
        final speed = processed.inMilliseconds / measured.inMilliseconds;
        parts.add(
          t('realTimeSpeed').replaceFirst('{speed}', speed.toStringAsFixed(1)),
        );
        if (total != null) {
          left =
              (total - processed) * (1 / speed) -
              now.difference(task.progressAt!);
        }
      }
    }
    parts.add(t('elapsedTime').replaceFirst('{time}', durationLabel(elapsed)));
    if (left != null && left.inSeconds >= 1) {
      parts.add(t('timeLeft').replaceFirst('{time}', durationLabel(left)));
    }
    return parts.join(' · ');
  }

  Widget sessionPanel() => pageStack([
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
                AnimatedSwitcher(
                  duration: AltMotion.quick,
                  child: paused
                      ? Icon(
                          AltIcons.pauseCircle,
                          key: const ValueKey('paused'),
                          size: 40,
                          color: colors.primary,
                        )
                      : AltLoading(
                          key: const ValueKey('working'),
                          shape: sessionShape,
                        ),
                ),
                const SizedBox(width: 16),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedSwitcher(
                        duration: AltMotion.quick,
                        transitionBuilder: AltMotion.rise,
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.centerLeft,
                          children: [...previous, ?current],
                        ),
                        child: Text(
                          sessionTitle,
                          key: ValueKey(sessionTitle),
                          style: text.titleLarge,
                        ),
                      ),
                      // The bar below keeps the time; the languages stay here.
                      Text(
                        '${live.record?.language == 'auto' ? t('cloudAutoLanguage') : sourceLanguage}${translate ? ' → $targetLanguage' : ''}',
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
                if ((translate && live.record?.directTranslation != true) ||
                    live.generateSummary)
                  Chip(
                    visualDensity: altChipDensity,
                    avatarBoxConstraints: altChipIconBounds,
                    avatar: const Icon(AltIcons.translate, size: 18),
                    label: Text('LLM · ${live.llmBackend}'),
                  ),
              ],
            ),
          ],
        ),
        for (final source in [
          if (live.record?.sources.contains('microphone') == true) 'microphone',
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
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            Text(
              t('latestLevel'),
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
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
  ]);
}
