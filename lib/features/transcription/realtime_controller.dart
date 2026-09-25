import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/logging/app_log.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:altranscribe/data/services/files/audio_file_decoder.dart';
import 'package:altranscribe/data/services/files/android_audio_decoder.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/data/services/files/file_transcriber.dart';
import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/cloud/cloud_api.dart';
import 'package:altranscribe/data/services/cloud/cloud_file_engine.dart';
import 'package:altranscribe/data/services/cloud/cloud_live.dart';
import 'package:altranscribe/data/services/cloud/cloud_live_session.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/cloud/credential_store.dart';

import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/data/services/transcription/chinese_script.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/translation/translation_context.dart';
import 'package:altranscribe/data/services/transcription/transcript_assembler.dart';
import 'package:altranscribe/data/models/caption_preferences.dart';
import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:altranscribe/data/services/remote/discovery.dart';
import 'package:altranscribe/data/services/remote/paired_devices.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:altranscribe/data/services/remote/remote_services.dart';
import 'package:altranscribe/data/services/remote/shared_host.dart';

enum SessionPhase { idle, loading, listening, paused, stopping, fileProcessing }

class RealtimeController extends ChangeNotifier {
  RealtimeController({
    required this.audio,
    required SpeechEngine engine,
    required this.store,
    TranslationService? translator,
    TranslationService? recordSummarizer,
    ModelCatalog? catalog,
    AudioFileDecoder? fileDecoder,
    CredentialStore? credentials,
    this.cloudSocketConnector,
    SharedHost? sharedHost,
  }) : localEngine = engine,
       _providedHost = sharedHost,
       credentials = credentials ?? WindowsCredentialStore(store.directory),
       localTranslator =
           translator ??
           LocalLlmService(
             cloudApi: CloudApi(
               credentials ?? WindowsCredentialStore(store.directory),
             ),
           ),
       fileDecoder =
           fileDecoder ??
           (MobilePlatform.android
               ? AndroidAudioDecoder()
               : FfmpegAudioDecoder()),
       localRecordSummarizer =
           recordSummarizer ??
           LocalLlmService(
             cloudApi: CloudApi(
               credentials ?? WindowsCredentialStore(store.directory),
             ),
           ),
       catalog =
           catalog ??
           ModelCatalog(
             Directory(
               environmentValue('ALTRANSCRIBE_MODELS_DIR') ??
                   '${store.directory.path}/models',
             ),
           );
  factory RealtimeController.local() {
    final audio = PlatformAudioService();
    return RealtimeController(
      audio: audio,
      engine: WhisperService(audio),
      store: RecordStore.local(),
    );
  }
  final AudioService audio;
  final SpeechEngine localEngine;
  SpeechEngine get engine => remoteProcessing ? remoteEngine : localEngine;
  final RecordStore store;
  final TranslationService localTranslator;
  final TranslationService localRecordSummarizer;
  TranslationService get translator =>
      remoteProcessing ? remoteTranslator : localTranslator;
  TranslationService get recordSummarizer =>
      remoteProcessing ? remoteSummarizer : localRecordSummarizer;
  final SharedHost? _providedHost;
  late final sharedHost =
      _providedHost ??
      SharedHost(
        engine: WhisperService(audio),
        translator: LocalLlmService(),
        // Phones never host, so their registry stays in memory.
        devices: PairedDevices(
          file: MobilePlatform.android
              ? null
              : File('${store.directory.path}/devices.json'),
        ),
      );
  final remoteConnection = RemoteConnection();

  /// Health of the saved host, refreshed while someone is watching it.
  HostStatus hostStatus = HostStatus.unknown;
  DateTime? hostSeen;
  Timer? _hostTimer;
  int _hostWatchers = 0;
  bool _probingHost = false;
  late final remoteEngine = RemoteSpeechEngine(remoteConnection);
  late final remoteTranslator = RemoteTranslationService(remoteConnection);
  late final remoteSummarizer = RemoteTranslationService(remoteConnection);
  bool useRemote = MobilePlatform.android;
  bool get localInferenceAllowed => !MobilePlatform.android;
  bool get remoteProcessing =>
      useRemote && speechProvider == SpeechProvider.whisper;
  String get sessionModel => remoteProcessing
      ? (remoteConnection.info?['model'] as String? ?? 'Whisper Remote')
      : model.split(RegExp(r'[/\\]')).last;
  String get sessionLlmModel => remoteProcessing
      ? (remoteConnection.info?['llmModel'] as String? ?? '')
      : translationModel;
  String get sessionLlmProvider =>
      remoteProcessing ? 'remote' : llmProvider.name;
  final ModelCatalog catalog;
  final AudioFileDecoder fileDecoder;
  final CredentialStore credentials;
  final CloudSocketConnector? cloudSocketConnector;
  SpeechProvider speechProvider = SpeechProvider.whisper;
  bool cloudDirectTranslation = true;
  bool cloudAutoLanguage = true;
  bool get cloudSpeech => speechProvider != SpeechProvider.whisper;
  String get speechBackend => cloudSpeech
      ? '${speechProvider.label} · ${record?.speechModel ?? (processingFiles ? speechProvider.fileModel : speechProvider.liveModel(cloudDirectTranslation))}'
      : engine.backend;
  final _cloudLive = <String, CloudLiveSession>{};
  final _cloudLines = <String, TranscriptLine>{};
  final _cloudFinalized = <String>{};
  Timer? _cloudSaveTimer;
  CloudFileEngine? _cloudFile;
  bool _directForSession = false;
  FileTranscriber? fileTask;
  Future<void>? _fileProcessing;
  int fileNumber = 0;
  int fileCount = 0;
  bool get processingFiles => fileTask != null;
  SessionPhase phase = SessionPhase.idle;
  String executable = '';
  String model = '';
  ComputeMode computeMode = ComputeMode.automatic;
  String translationAddress = 'http://127.0.0.1:11434';
  String translationModel = '';
  LlmProvider llmProvider = MobilePlatform.android
      ? LlmProvider.openAI
      : LlmProvider.ollama;
  bool generateSummary = true;
  bool generatingSummary = false;
  String? updatingRecordId;
  int transcriptRevision = 0;
  int _recordEditRevision = 0;
  String microphoneDevice = '';
  String systemDevice = '';
  bool microphoneDenoise = true;
  bool microphoneAutoGain = true;
  bool systemDenoise = false;
  bool systemAutoGain = false;
  String? error;
  String? warning;
  bool initialized = false;
  bool recognizing = false;
  bool translating = false;
  double lastTranslationSeconds = 0;
  bool pausePending = false;
  bool discardConfirmationPending = false;
  bool captionsVisible = false;
  CaptionPreferences captionPreferences = const CaptionPreferences();
  TranslationContextPolicy translationContext =
      const TranslationContextPolicy();
  double lastInferenceSeconds = 0;
  final levels = <String, double>{};
  // Native meters report RMS every 200 ms: 76 points span about 15 seconds.
  static const levelHistorySamples = 76;
  final levelHistory = <String, List<double>>{};
  final readySources = <String>{};
  List<TranscriptRecord> records = [];
  TranscriptRecord? record;
  final _queue = Queue<Map<String, Object?>>();
  TranscriptAssembler _sentences = TranscriptAssembler();
  Timer? _timer;
  Future<void>? _polling;
  Future<void>? _processing;
  final _translationQueue = Queue<(TranscriptRecord, List<TranscriptLine>)>();
  int _translationBatchRemaining = 0;
  Future<void>? _translations;
  Future<void>? _starting;
  Future<void>? _stopping;
  Completer<void>? _savedStop;
  bool backgroundFinishing = false;
  bool _cancelled = false;
  bool _discarding = false;
  bool _disposed = false;
  bool get active => phase != SessionPhase.idle;
  int get pending => _queue.length + (recognizing ? 1 : 0);
  int get pendingTranslations =>
      _translationQueue.fold<int>(0, (count, item) => count + item.$2.length) +
      _translationBatchRemaining;
  void _notify() {
    if (!active) captionsVisible = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      await store.initialize();
      final settings = await store.loadSettings();
      speechProvider =
          SpeechProvider.values
              .where((value) => value.name == settings['speechProvider'])
              .firstOrNull ??
          SpeechProvider.whisper;
      cloudDirectTranslation =
          settings['cloudDirectTranslation'] as bool? ?? true;
      cloudAutoLanguage = settings['cloudAutoLanguage'] as bool? ?? true;
      useRemote = settings['useRemote'] == true;
      if (!localInferenceAllowed && speechProvider == SpeechProvider.whisper) {
        useRemote = true;
      }
      remoteConnection.address = settings['remoteAddress'] as String? ?? '';
      remoteConnection.name = settings['remoteName'] as String? ?? '';
      remoteConnection.hostId = settings['remoteHostId'] as String? ?? '';
      if (remoteConnection.address.isNotEmpty) {
        remoteConnection.token = await credentials.readNamed('remote-host');
      }
      if (localInferenceAllowed) await sharedHost.devices.load();
      final root = environmentValue('ALTRANSCRIBE_WHISPER_DIR');
      executable =
          environmentValue('ALTRANSCRIBE_WHISPER_EXECUTABLE') ??
          settings['executable'] as String? ??
          (root == null ? '' : '$root/build/bin/whisper-server.exe');
      model =
          settings['model'] as String? ??
          (root == null ? '' : '$root/models/ggml-large-v3-turbo.bin');
      final available = await catalog.scan();
      final selectedName = model.split(RegExp(r'[/\\]')).last;
      final localModel = ModelCatalog.models
          .where(
            (item) =>
                item.filename == selectedName &&
                available[item.id] == ModelAvailability.available,
          )
          .firstOrNull;
      final defaultModel = ModelCatalog.models
          .where((item) => available[item.id] == ModelAvailability.available)
          .firstOrNull;
      if (localModel != null) {
        model = catalog.path(localModel);
      } else if (model.isEmpty && defaultModel != null) {
        model = catalog.path(defaultModel);
      }
      final compute =
          environmentValue('ALTRANSCRIBE_COMPUTE_MODE') ??
          settings['computeMode'];
      computeMode =
          ComputeMode.values
              .where((mode) => mode.name == compute)
              .firstOrNull ??
          ComputeMode.automatic;
      translationAddress =
          settings['translationAddress'] as String? ?? translationAddress;
      llmProvider =
          LlmProvider.values
              .where((item) => item.name == settings['llmProvider'])
              .firstOrNull ??
          LlmProvider.ollama;
      if (!localInferenceAllowed && llmProvider == LlmProvider.ollama) {
        llmProvider = LlmProvider.openAI;
      }
      generateSummary = settings['generateSummary'] as bool? ?? true;
      captionPreferences = CaptionPreferences.fromJson(
        settings['captions'] as Map? ?? {},
      );
      translationContext = TranslationContextPolicy.fromJson(
        settings['translationContext'] as Map? ?? {},
      );
      translationModel =
          environmentValue('ALTRANSCRIBE_TRANSLATION_MODEL') ??
          settings['translationModel'] as String? ??
          '';
      microphoneDevice = settings['microphoneDevice'] as String? ?? '';
      systemDevice = settings['systemDevice'] as String? ?? '';
      microphoneDenoise = settings['microphoneDenoise'] as bool? ?? true;
      microphoneAutoGain = settings['microphoneAutoGain'] as bool? ?? true;
      systemDenoise = settings['systemDenoise'] as bool? ?? false;
      systemAutoGain = settings['systemAutoGain'] as bool? ?? false;
      await _reloadRecords();
      if ((settings.isEmpty && root != null) ||
          environmentValue('ALTRANSCRIBE_WHISPER_EXECUTABLE') != null ||
          environmentValue('ALTRANSCRIBE_TRANSLATION_MODEL') != null) {
        await saveSettings();
      }
    } catch (e, s) {
      AppLog.instance.error('settings', e, s);
      error = e.toString();
    }
    initialized = true;
    _notify();
  }

  Future<void> saveSettings() async {
    await store.saveSettings({
      'executable': executable,
      'model': model,
      'computeMode': computeMode.name,
      'translationAddress': translationAddress,
      'translationModel': translationModel,
      'llmProvider': llmProvider.name,
      'generateSummary': generateSummary,
      'captions': captionPreferences.toJson(),
      'translationContext': translationContext.toJson(),
      'microphoneDevice': microphoneDevice,
      'systemDevice': systemDevice,
      'microphoneDenoise': microphoneDenoise,
      'microphoneAutoGain': microphoneAutoGain,
      'systemDenoise': systemDenoise,
      'systemAutoGain': systemAutoGain,
      'speechProvider': speechProvider.name,
      'cloudDirectTranslation': cloudDirectTranslation,
      'cloudAutoLanguage': cloudAutoLanguage,
      'useRemote': useRemote,
      'remoteAddress': remoteConnection.address,
      'remoteName': remoteConnection.name,
      'remoteHostId': remoteConnection.hostId,
    });
    _notify();
  }

  Future<void> setGenerateSummary(bool value) async {
    if (active) return;
    generateSummary = value;
    _notify();
    try {
      await saveSettings();
    } catch (e) {
      error = e.toString();
      _notify();
    }
  }

  Future<void> connectRemote(
    String address,
    String token,
    String name, {
    String hostId = '',
  }) async {
    if (active || updatingRecordId != null) throw StateError('recordBusy');
    final candidate = RemoteConnection(
      address: address,
      token: token,
      name: name,
      hostId: hostId,
    );
    final client = RemoteClient(candidate);
    try {
      final info = await client.connect();
      await credentials.writeNamed('remote-host', token);
      remoteConnection.address = remoteUri(address).toString();
      remoteConnection.token = token.trim();
      remoteConnection.name = name.trim().isEmpty
          ? candidate.info!['name'] as String
          : name.trim();
      remoteConnection.hostId = candidate.hostId;
      remoteConnection.info = candidate.info;
      hostStatus = info['busy'] == true ? HostStatus.busy : HostStatus.online;
      hostSeen = DateTime.now();
      useRemote = true;
      speechProvider = SpeechProvider.whisper;
      await saveSettings();
      _scheduleHostProbes();
    } finally {
      client.close();
    }
  }

  String get deviceName => MobilePlatform.android
      ? MobilePlatform.deviceName
      : Platform.localHostname;

  /// Trades a pairing code shown on the host for this device's own token,
  /// then connects. [name] is what this device calls the host.
  Future<void> pairWithHost(
    String address,
    String code, {
    String name = '',
  }) async {
    if (active || updatingRecordId != null) throw StateError('recordBusy');
    final client = RemoteClient(RemoteConnection(address: address));
    final grant = await client.pair(
      code,
      deviceName,
      MobilePlatform.android ? 'android' : 'windows',
    );
    AppLog.instance.info('remote', 'Paired with host ${grant['hostId']}');
    await connectRemote(
      address,
      grant['token'] as String,
      name.trim().isEmpty ? grant['name'] as String? ?? '' : name,
      hostId: grant['hostId'] as String,
    );
  }

  /// Pairs from a scanned or pasted invite.
  Future<void> pairWithInvite(String text) async {
    final invite = PairingInvite.parse(text);
    await pairWithHost(invite.address, invite.code, name: invite.name);
  }

  Future<void> forgetHost() async {
    if (active || updatingRecordId != null) throw StateError('recordBusy');
    remoteConnection
      ..address = ''
      ..token = ''
      ..name = ''
      ..hostId = ''
      ..info = null;
    hostStatus = HostStatus.unknown;
    hostSeen = null;
    _scheduleHostProbes();
    await credentials.writeNamed('remote-host', '');
    await saveSettings();
  }

  /// Hosts answering on the local network right now.
  Future<List<DiscoveredHost>> findHosts() => discoverHosts();

  /// Keeps the saved host's status fresh while a page shows it.
  void watchHost(bool watching) {
    _hostWatchers = math.max(0, _hostWatchers + (watching ? 1 : -1));
    _scheduleHostProbes();
  }

  void _scheduleHostProbes() {
    final wanted = _hostWatchers > 0 && remoteConnection.address.isNotEmpty;
    if (wanted && _hostTimer == null) {
      _hostTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => probeHost(),
      );
      unawaited(probeHost());
    } else if (!wanted) {
      _hostTimer?.cancel();
      _hostTimer = null;
    }
  }

  /// One health check of the saved host. A host that moved to another
  /// address is found again by identity through discovery.
  Future<void> probeHost({bool discover = true}) async {
    if (_probingHost ||
        _disposed ||
        remoteConnection.address.isEmpty ||
        remoteConnection.token.isEmpty) {
      return;
    }
    _probingHost = true;
    var moved = false;
    try {
      final client = RemoteClient(
        RemoteConnection(
          address: remoteConnection.address,
          token: remoteConnection.token,
          name: remoteConnection.name,
          hostId: remoteConnection.hostId,
        ),
      );
      try {
        final info = await client.connect();
        remoteConnection.info = info;
        if (info['hostId'] is String) {
          remoteConnection.hostId = info['hostId'] as String;
        }
        hostStatus = info['busy'] == true ? HostStatus.busy : HostStatus.online;
        hostSeen = DateTime.now();
      } finally {
        client.close();
      }
    } catch (_) {
      hostStatus = HostStatus.offline;
      if (discover && remoteConnection.hostId.isNotEmpty) {
        final found = await _findSavedHost();
        if (found != null && found.address != remoteConnection.address) {
          AppLog.instance.info(
            'remote',
            'Host ${remoteConnection.name} answered from ${found.address}',
          );
          remoteConnection.address = found.address;
          moved = true;
        }
      }
    } finally {
      _probingHost = false;
    }
    if (moved) {
      await saveSettings();
      return probeHost(discover: false);
    }
    _notify();
  }

  Future<DiscoveredHost?> _findSavedHost() async {
    try {
      return (await discoverHosts())
          .where((host) => host.id == remoteConnection.hostId)
          .firstOrNull;
    } catch (_) {
      return null;
    }
  }

  void setCaptionsVisible(bool value) {
    captionsVisible =
        value && active && !processingFiles && !backgroundFinishing;
    _notify();
  }

  Future<void> setCaptionPreferences(CaptionPreferences value) async {
    captionPreferences = value;
    await saveSettings();
  }

  Future<bool> beginDiscardConfirmation() async {
    if (discardConfirmationPending ||
        pausePending ||
        (phase != SessionPhase.listening && phase != SessionPhase.paused)) {
      return false;
    }
    discardConfirmationPending = true;
    _notify();
    try {
      if (phase == SessionPhase.listening) await togglePause();
      if (phase == SessionPhase.paused) return true;
    } catch (_) {
      endDiscardConfirmation();
      rethrow;
    }
    endDiscardConfirmation();
    return false;
  }

  void endDiscardConfirmation() {
    discardConfirmationPending = false;
    _notify();
  }

  bool canEditRecord(TranscriptRecord item) =>
      updatingRecordId == null && !(active && record?.id == item.id);

  TranscriptRecord _editableRecord(String id) {
    final item = records.where((item) => item.id == id).firstOrNull;
    if (item == null) throw StateError('recordNotFound');
    if (!canEditRecord(item)) throw StateError('recordBusy');
    return item.copy();
  }

  Future<void> _saveRecordEdit(TranscriptRecord updated) async {
    await store.save(updated);
    _recordEditRevision++;
    records = records
        .map((item) => item.id == updated.id ? updated : item)
        .toList();
    if (!active && record?.id == updated.id) record = updated;
    _notify();
  }

  Future<void> _reloadRecords() async {
    // A record edit may finish while stopping a session reads the library.
    // Do not replace its new title with an older disk snapshot.
    while (true) {
      final revision = _recordEditRevision;
      final loaded = await store.loadRecords();
      if (revision == _recordEditRevision) {
        records = [
          for (final item in loaded)
            if (backgroundFinishing && item.id == record?.id) record! else item,
        ];
        return;
      }
    }
  }

  Future<void> renameRecord(String id, String title) async {
    final name = title.trim();
    if (name.isEmpty) throw const FormatException('titleRequired');
    if (name.runes.length > 120) throw const FormatException('titleTooLong');
    final updated = _editableRecord(id)..title = name;
    updatingRecordId = id;
    _notify();
    try {
      await _saveRecordEdit(updated);
    } finally {
      updatingRecordId = null;
      _notify();
    }
  }

  Future<void> _deleteStoredRecord(String id) async {
    await store.delete(id);
    _recordEditRevision++;
    records = records.where((item) => item.id != id).toList();
    if (record?.id == id) record = null;
  }

  Future<void> deleteRecord(String id) async {
    _editableRecord(id);
    updatingRecordId = id;
    _notify();
    try {
      await _deleteStoredRecord(id);
    } finally {
      updatingRecordId = null;
      _notify();
    }
  }

  Future<void> generateRecordSummary(String id, String language) async {
    final updated = _editableRecord(id);
    if (!updated.needsSummary) return;
    if (updated.lines.every((line) => line.text.trim().isEmpty)) {
      throw const FormatException('noSpeechRecorded');
    }
    final address = translationAddress;
    final modelName = translationModel;
    final provider = llmProvider;
    updated.summaryStatus = 'pending';
    updated.summaryError = null;
    updated.summaryLanguage = language;
    updated.summaryProvider = sessionLlmProvider;
    updated.summaryModel = sessionLlmModel;
    updatingRecordId = id;
    _notify();
    try {
      await _saveRecordEdit(updated.copy());
      try {
        await recordSummarizer.prepare(address, modelName, provider: provider);
        updated.summaryProvider = sessionLlmProvider;
        updated.summaryModel = sessionLlmModel;
        final result = await recordSummarizer.summarize(
          updated.lines.map((line) => line.displayText).toList(),
          language,
        );
        // A title entered by the user takes precedence over a generated one.
        if (updated.title?.trim().isNotEmpty != true) {
          updated.title = result.title;
        }
        updated.summary = result.summary;
        updated.summaryStatus = 'done';
      } catch (e) {
        updated.summaryStatus = 'failed';
        updated.summaryError = e is SocketException || e is TimeoutException
            ? 'llmUnavailable'
            : e.toString();
        await _saveRecordEdit(updated);
        if (e is SocketException || e is TimeoutException) {
          throw const FormatException('llmUnavailable');
        }
        rethrow;
      }
      await _saveRecordEdit(updated);
    } finally {
      recordSummarizer.stop();
      updatingRecordId = null;
      _notify();
    }
  }

  Future<void> startFiles({
    required List<String> paths,
    required String language,
    String? targetLanguage,
    required String summaryLanguage,
    required CleanupOptions options,
  }) {
    if (active || !initialized || paths.isEmpty) return Future.value();
    _cancelled = false;
    error = warning = null;
    record = null;
    fileTask = FileTranscriber(fileDecoder);
    fileNumber = 0;
    fileCount = paths.length;
    phase = SessionPhase.loading;
    transcriptRevision++;
    _notify();
    final future = _runFiles(
      List.of(paths),
      cloudSpeech && cloudAutoLanguage ? 'auto' : language,
      targetLanguage,
      summaryLanguage,
      options,
    ).whenComplete(() => _fileProcessing = null);
    _fileProcessing = future;
    return future;
  }

  Future<void> _runFiles(
    List<String> paths,
    String language,
    String? targetLanguage,
    String summaryLanguage,
    CleanupOptions options,
  ) async {
    final fileEngine = cloudSpeech
        ? (_cloudFile = CloudFileEngine(
            CloudApi(credentials),
            speechProvider.cloud,
          ))
        : engine;
    final needsLlm =
        options.enabled ||
        generateSummary ||
        (targetLanguage != null && targetLanguage != language);
    try {
      _checkMobileProviders();
      await MobilePlatform.backgroundWork(true, language: summaryLanguage);
      await saveSettings();
      if (_cancelled) return;
      if (needsLlm) {
        await translator.prepare(
          translationAddress,
          translationModel,
          provider: llmProvider,
        );
      }
      if (_cancelled) return;
      await fileEngine.start(
        executable,
        model,
        store.directory,
        compute: computeMode,
      );
      if (_cancelled) return;
      for (final path in paths) {
        if (_cancelled) break;
        fileNumber++;
        fileTask = FileTranscriber(fileDecoder);
        final now = DateTime.now();
        final current = TranscriptRecord(
          id: 'session-${now.microsecondsSinceEpoch}',
          createdAt: now,
          language: language,
          speechProvider: remoteProcessing
              ? 'whisperRemote'
              : speechProvider.name,
          speechModel: cloudSpeech ? speechProvider.fileModel : sessionModel,
          targetLanguage: targetLanguage,
          translationModel: targetLanguage == null ? null : sessionLlmModel,
          llmProvider: needsLlm ? sessionLlmProvider : null,
          llmModel: needsLlm ? sessionLlmModel : null,
          summaryStatus: generateSummary ? 'pending' : 'none',
          summaryLanguage: generateSummary ? summaryLanguage : null,
          summaryProvider: generateSummary ? sessionLlmProvider : null,
          summaryModel: generateSummary ? sessionLlmModel : null,
          inputFile: path,
          sources: ['file'],
          lines: [],
          cleanupOptions: options.toJson(),
          cleanupStatus: options.enabled ? 'pending' : 'none',
        );
        record = current;
        phase = SessionPhase.fileProcessing;
        _notify();
        await fileTask!.run(
          record: current,
          engine: fileEngine,
          chunkSeconds: cloudSpeech ? 600 : 20,
          translator: translator,
          translationContext: translationContext,
          store: store,
          options: options,
          onChanged: () {
            transcriptRevision++;
            _notify();
          },
        );
        if (_cloudFile?.cleanupWarning != null) {
          warning = _cloudFile!.cleanupWarning;
        }
        if (current.status == 'error') warning = 'fileSomeFailed';
        await _reloadRecords();
      }
    } catch (e, s) {
      AppLog.instance.error('files', e, s);
      if (!_cancelled) {
        error = e is SocketException || e is TimeoutException
            ? 'llmUnavailable'
            : e.toString();
      }
    } finally {
      await fileDecoder.cancel();
      await MobilePlatform.backgroundWork(false);
      await fileEngine.stop();
      _cloudFile = null;
      translator.stop();
      try {
        await _reloadRecords();
      } catch (e) {
        error ??= e.toString();
      }
      fileTask = null;
      phase = SessionPhase.idle;
      _notify();
    }
  }

  Future<void> _cancelFiles() async {
    _cancelled = true;
    phase = SessionPhase.stopping;
    _notify();
    translator.stop();
    await fileTask?.cancel();
    await _cloudFile?.stop();
    await engine.stop();
    await _fileProcessing;
  }

  Future<void> start({
    required bool microphone,
    required bool system,
    required String language,
    String? targetLanguage,
    String? summaryLanguage,
  }) {
    if (active || !initialized || (!microphone && !system)) {
      return Future.value();
    }
    _cancelled = false;
    _directForSession =
        cloudSpeech && cloudDirectTranslation && targetLanguage != null;
    _cloudLines.clear();
    _cloudFinalized.clear();
    _sentences = TranscriptAssembler();
    error = warning = null;
    record = null;
    readySources.clear();
    levels.clear();
    levelHistory.clear();
    lastInferenceSeconds = 0;
    lastTranslationSeconds = 0;
    transcriptRevision++;
    phase = SessionPhase.loading;
    AppLog.instance.info(
      'session',
      'Start: microphone=$microphone system=$system $language→${targetLanguage ?? '-'} '
          'engine=${cloudSpeech
              ? speechProvider.name
              : remoteProcessing
              ? 'remote'
              : 'whisper'} '
          'llm=${llmProvider.name}',
    );
    _notify();
    final future = _start(
      microphone,
      system,
      cloudSpeech && (cloudAutoLanguage || _directForSession)
          ? 'auto'
          : language,
      targetLanguage,
      summaryLanguage ?? language,
    );
    _starting = future;
    return future;
  }

  Future<void> _start(
    bool microphone,
    bool system,
    String language,
    String? targetLanguage,
    String summaryLanguage,
  ) async {
    try {
      _checkMobileProviders();
      await saveSettings();
      if (_cancelled) return;
      if (generateSummary ||
          (!_directForSession &&
              targetLanguage != null &&
              targetLanguage != language)) {
        try {
          await translator.prepare(
            translationAddress,
            translationModel,
            provider: llmProvider,
          );
        } on SocketException {
          throw const FormatException('llmUnavailable');
        } on TimeoutException {
          throw const FormatException('llmUnavailable');
        }
        if (_cancelled) return;
      }
      if (!cloudSpeech) {
        await engine.start(
          executable,
          model,
          store.directory,
          compute: computeMode,
        );
      }
      if (_cancelled) return;
      final now = DateTime.now();
      record = TranscriptRecord(
        id: 'session-${now.microsecondsSinceEpoch}',
        createdAt: now,
        language: language,
        speechProvider: remoteProcessing
            ? 'whisperRemote'
            : speechProvider.name,
        speechModel: cloudSpeech
            ? speechProvider.liveModel(_directForSession)
            : sessionModel,
        directTranslation: _directForSession,
        targetLanguage: targetLanguage,
        translationModel: targetLanguage == null
            ? null
            : _directForSession
            ? speechProvider.liveModel(true)
            : sessionLlmModel,
        summaryStatus: generateSummary ? 'pending' : 'none',
        summaryLanguage: generateSummary ? summaryLanguage : null,
        summaryProvider: generateSummary ? sessionLlmProvider : null,
        summaryModel: generateSummary ? sessionLlmModel : null,
        llmProvider:
            generateSummary || (!_directForSession && targetLanguage != null)
            ? sessionLlmProvider
            : null,
        llmModel:
            generateSummary || (!_directForSession && targetLanguage != null)
            ? sessionLlmModel
            : null,
        sources: [if (microphone) 'microphone', if (system) 'system'],
        lines: [],
      );
      await store.save(record!);
      if (_cancelled) return;
      if (cloudSpeech) {
        for (final source in record!.sources) {
          if (_cancelled) return;
          final connection = CloudLiveSession(
            credentials: credentials,
            provider: speechProvider,
            directTranslation: _directForSession,
            source: source,
            language: language,
            targetLanguage: targetLanguage,
            onText: _cloudText,
            onRenewed: () {
              warning ??= 'cloudSessionRenewed';
              _notify();
            },
            connect: cloudSocketConnector,
            onError: (message) {
              error ??= message;
              if (phase != SessionPhase.loading) unawaited(stop());
            },
          );
          _cloudLive[source] = connection;
          await connection.start();
        }
        if (_cancelled) return;
      }
      await audio.start({
        'interfaceLanguage': summaryLanguage,
        'microphone': microphone,
        'system': system,
        'microphoneDevice': microphoneDevice,
        'systemDevice': systemDevice,
        'microphoneDenoise': microphoneDenoise,
        'microphoneAutoGain': microphoneAutoGain,
        'systemDenoise': systemDenoise,
        'systemAutoGain': systemAutoGain,
        if (cloudSpeech) 'streaming': true,
        if (cloudSpeech)
          'sampleRate': speechProvider == SpeechProvider.openAI ? 24000 : 16000,
      });
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!_cancelled && readySources.length < record!.sources.length) {
        _events(await audio.poll());
        if (error != null) throw StateError(error!);
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Audio capture did not become ready');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_cancelled) return;
      phase = SessionPhase.listening;
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _polling ??= _poll().whenComplete(() => _polling = null);
      });
      _notify();
    } catch (e, s) {
      AppLog.instance.error('session', e, s);
      if (!_cancelled) error = e.toString();
      // Let start settle before stop waits for it, avoiding a lifecycle deadlock.
      scheduleMicrotask(() => unawaited(stop()));
    }
  }

  void _checkMobileProviders() {
    // An online OpenAI-compatible service is checked by the translator itself,
    // which rejects plain-HTTP addresses on a phone.
    if (!localInferenceAllowed &&
        !remoteProcessing &&
        (speechProvider == SpeechProvider.whisper ||
            llmProvider == LlmProvider.ollama)) {
      throw const FormatException('mobileRemoteOnly');
    }
  }

  Future<void> _poll() async {
    try {
      _events(await audio.poll());
    } catch (e) {
      error = e.toString();
      unawaited(stop());
    }
  }

  void _events(List<Map<String, Object?>> events) {
    if (events.isEmpty || _discarding) return;
    for (final event in events) {
      final source = event['source'] as String;
      switch (event['type']) {
        case 'ready':
          readySources.add(source);
        case 'level':
          levels[source] = (event['level'] as num).toDouble();
          if (phase == SessionPhase.listening) {
            final history = [...?levelHistory[source], levels[source]!];
            // Keep one extra point offscreen so scrolling has no gap at the left edge.
            levelHistory[source] = List.unmodifiable(
              history.skip(
                (history.length - levelHistorySamples - 1).clamp(
                  0,
                  history.length,
                ),
              ),
            );
          }
        case 'gap':
          warning = 'audioGap';
        case 'error':
          AppLog.instance.warn('audio', '$source: ${event['message']}');
          error = '$source: ${event['message']}';
          if (phase != SessionPhase.loading) unawaited(stop());
        case 'chunk':
          // New snapshots supersede older queued previews, never final audio.
          _queue.removeWhere(
            (pending) =>
                pending['partial'] == true &&
                pending['source'] == source &&
                (pending['startMs'] as int) <= (event['startMs'] as int),
          );
          if (event['partial'] == true && _queue.length >= 8) break;
          if (_queue.where((pending) => pending['partial'] != true).length >=
              8) {
            // Stop instead of silently dropping speech or growing memory without a limit.
            warning = 'tooSlow';
            error = 'tooSlow';
            unawaited(stop());
          }
          _queue.add(event);
          _processing ??= _process().whenComplete(() => _processing = null);
        case 'frame':
          _cloudLive[source]?.add(
            event['pcm'] as Uint8List,
            event['startMs'] as int,
            event['endMs'] as int,
          );
        case 'paused':
          // Native emits this after its final frame, so silence cannot overtake
          // the last spoken audio when the user pauses capture.
          final connection = _cloudLive[source];
          if (connection != null) {
            final end = event['endMs'] as int;
            connection.add(Uint8List(connection.sampleRate * 2), end, end);
          }
      }
    }
    _notify();
  }

  void _cloudText(CloudLiveText update) {
    final current = record;
    if (current == null || _disposed || _discarding) return;
    final old = _cloudLines[update.id];
    final alreadyFinal = _cloudFinalized.contains(update.id);
    // Text-model translations hold the original line object. Direct streams,
    // however, can still deliver translation after a source window has closed.
    if (alreadyFinal && !_directForSession) return;
    final translation = update.translation ?? old?.translation;
    final translationFinalized =
        update.translationFinalized ?? update.finalized;
    final line = TranscriptLine(
      source: update.source,
      startMs: update.startMs,
      endMs: update.endMs,
      text: normalizeChineseScript(update.text, current.language),
      transcriptionStatus: update.finalized
          ? (update.serverConfirmed ? 'done' : 'streamed')
          : 'partial',
      continuous: update.continuous,
      timingEstimated: update.timingEstimated,
      translation: translation,
      translationStatus: _directForSession
          ? (translationFinalized
                ? (update.serverConfirmed ? 'done' : 'streamed')
                : (translation?.trim().isNotEmpty == true
                      ? 'streamed'
                      : 'pending'))
          : old?.translationStatus ?? 'none',
      translationError: old?.translationError,
    );
    if (old != null) current.lines.remove(old);
    _cloudLines[update.id] = line;
    var completedLines = <TranscriptLine>[line];
    if (update.finalized && !_directForSession) {
      completedLines = _sentences.accept(
        current,
        source: update.source,
        startMs: update.startMs,
        endMs: update.endMs,
        text: line.text,
        continues: update.continues,
      );
    } else if (line.text.isNotEmpty || line.translation?.isNotEmpty == true) {
      current.lines.add(line);
    }
    current.lines.sort((a, b) => a.startMs.compareTo(b.startMs));
    if (update.finalized && !alreadyFinal) {
      _cloudFinalized.add(update.id);
      if (!_directForSession &&
          current.targetLanguage != null &&
          line.text.isNotEmpty) {
        _translationQueue.removeWhere(
          (item) => item.$2.every((line) => !item.$1.lines.contains(line)),
        );
        _queueTranslations(current, completedLines);
        if (_translationQueue.isNotEmpty) {
          _translations ??= _translate().whenComplete(
            () => _translations = null,
          );
        }
      }
    }
    transcriptRevision++;
    _notify();
    _cloudSaveTimer ??= Timer(const Duration(seconds: 1), () {
      _cloudSaveTimer = null;
      unawaited(
        store.save(current).catchError((Object e) {
          error = e.toString();
          unawaited(stop());
        }),
      );
    });
  }

  Future<void> _process() async {
    while (_queue.isNotEmpty) {
      // Final audio takes precedence when a slow engine has previews waiting.
      final chunk =
          _queue.where((item) => item['partial'] != true).firstOrNull ??
          _queue.first;
      _queue.remove(chunk);
      final current = record!;
      recognizing = true;
      _notify();
      final clock = Stopwatch()..start();
      try {
        final text = await engine.transcribe(
          pcmToWave(chunk['pcm'] as Uint8List),
          current.language,
        );
        if (_discarding) return;
        lastInferenceSeconds = clock.elapsedMilliseconds / 1000;
        final partial = chunk['partial'] == true;
        final lines = _sentences.accept(
          current,
          source: chunk['source'] as String,
          startMs: chunk['startMs'] as int,
          endMs: chunk['endMs'] as int,
          text: text,
          partial: partial,
          continues: chunk['continues'] == true,
        );
        // A joined tail replaces the old row. Its pending translation is obsolete.
        _translationQueue.removeWhere(
          (item) => item.$2.every((line) => !item.$1.lines.contains(line)),
        );
        if (!partial) {
          _queueTranslations(current, lines);
        }
        transcriptRevision++;
        _notify();
        await store.save(current);
        if (!_discarding && _translationQueue.isNotEmpty) {
          _translations ??= _translate().whenComplete(
            () => _translations = null,
          );
        }
        final audioSeconds =
            ((chunk['endMs'] as int) - (chunk['startMs'] as int)) / 1000;
        if (lastInferenceSeconds > audioSeconds && _queue.isNotEmpty) {
          warning = 'fallingBehind';
        }
      } catch (e, s) {
        AppLog.instance.error('recognition', e, s);
        if (!_discarding) error = e.toString();
        _queue.clear();
        unawaited(stop());
      } finally {
        recognizing = false;
        _notify();
      }
    }
  }

  void _queueTranslations(
    TranscriptRecord current,
    List<TranscriptLine> lines,
  ) {
    if (current.targetLanguage == null || lines.isEmpty) return;
    for (final line in lines) {
      if (current.targetLanguage == current.language) {
        line.translation = line.text;
        line.translationStatus = 'done';
      } else if (_translationQueue.length >= 8) {
        line.translationStatus = 'failed';
        line.translationError = warning = 'translationTooSlow';
      } else {
        line.translationStatus = 'pending';
      }
    }
    // Capacity still counts audio windows, so splitting a window into many
    // short sentences cannot itself cause translations to be dropped.
    if (lines.first.translationStatus == 'pending') {
      _translationQueue.add((current, lines));
    }
  }

  Future<void> _translate() async {
    while (_translationQueue.isNotEmpty) {
      final (current, lines) = _translationQueue.removeFirst();
      for (var index = 0; index < lines.length; index++) {
        if (_discarding) break;
        _translationBatchRemaining = lines.length - index;
        final line = lines[index];
        if (!current.lines.contains(line)) continue;
        translating = true;
        _notify();
        final clock = Stopwatch()..start();
        try {
          final translation = await translator.translate(
            line.text,
            current.language,
            current.targetLanguage!,
            context: translationContext.select(current, line),
          );
          if (!_discarding && current.lines.contains(line)) {
            line.translation = translation;
            line.translationStatus = 'done';
          }
          lastTranslationSeconds = clock.elapsedMilliseconds / 1000;
        } catch (e) {
          if (!_discarding && current.lines.contains(line)) {
            line.translationStatus = 'failed';
            line.translationError = e.toString();
            warning = 'translationFailed';
          }
        }
        try {
          if (!_discarding && current.lines.contains(line)) {
            await store.save(current);
          }
        } catch (e) {
          error = e.toString();
          unawaited(stop());
        }
        translating = false;
        transcriptRevision++;
        _notify();
      }
      _translationBatchRemaining = 0;
    }
    translating = false;
    _notify();
  }

  Future<void> togglePause() async {
    if (pausePending ||
        (phase != SessionPhase.listening && phase != SessionPhase.paused)) {
      return;
    }
    pausePending = true;
    _notify();
    try {
      final pause = phase == SessionPhase.listening;
      await audio.pause(pause);
      if (phase != SessionPhase.stopping) {
        phase = pause ? SessionPhase.paused : SessionPhase.listening;
      }
    } catch (e) {
      error = e.toString();
      unawaited(stop());
    } finally {
      pausePending = false;
      _notify();
    }
  }

  Future<void> stop() {
    AppLog.instance.info('session', 'Stop requested while ${phase.name}');
    return _finishSession();
  }

  // The user can leave once capture stops and the received text is durable.
  // stop() still waits for tail responses, translations and the final summary.
  Future<void> stopAndSave() {
    if (_stopping != null) return _savedStop?.future ?? _stopping!;
    if (!active || processingFiles || phase == SessionPhase.loading) {
      return stop();
    }
    final saved = _savedStop = Completer<void>();
    unawaited(
      _finishSession().catchError((Object e, StackTrace stack) {
        error ??= e.toString();
        if (!saved.isCompleted) saved.completeError(e, stack);
        _notify();
      }),
    );
    return saved.future;
  }

  Future<void> discard() {
    if (phase != SessionPhase.paused || pausePending) {
      throw StateError('recordBusy');
    }
    return _finishSession(discard: true);
  }

  Future<void> _finishSession({bool discard = false}) {
    if (_stopping != null) return _stopping!;
    if (!active) return Future.value();
    if (processingFiles) {
      return _stopping = _cancelFiles().whenComplete(() => _stopping = null);
    }
    final wasLoading = phase == SessionPhase.loading;
    _discarding = discard;
    _cancelled = true;
    phase = SessionPhase.stopping;
    _timer?.cancel();
    _timer = null;
    _notify();
    final future = _stop(wasLoading).whenComplete(() {
      final saved = _savedStop;
      if (saved != null && !saved.isCompleted) {
        saved.completeError(StateError(error ?? 'recordSaveFailed'));
      }
      _savedStop = null;
      _stopping = null;
      _discarding = false;
    });
    _stopping = future;
    return future;
  }

  Future<void> _stop(bool wasLoading) async {
    try {
      if (wasLoading || _discarding) {
        if (_discarding) {
          _queue.clear();
          _translationQueue.clear();
          _cloudSaveTimer?.cancel();
          _cloudSaveTimer = null;
        }
        for (final connection in _cloudLive.values) {
          connection.cancel();
        }
        translator.stop();
        await engine.stop();
      }
      await _starting;
      await _polling;
      _events(await audio.stop());
      final saved = _savedStop;
      final current = record;
      if (saved != null && current != null) {
        try {
          current.status = 'finishing';
          await store.save(current);
          records = [
            current,
            ...records.where((item) => item.id != current.id),
          ];
          backgroundFinishing = true;
          captionsVisible = false;
          _notify();
          saved.complete();
        } catch (e, stack) {
          error ??= e.toString();
          saved.completeError(e, stack);
        }
      }
      await Future.wait(
        _cloudLive.values.map((connection) async {
          try {
            await connection.finish();
          } catch (e) {
            error ??= e.toString();
          }
        }),
      );
      await _processing;
      await _translations;
    } catch (e, stack) {
      error ??= e.toString();
      final saved = _savedStop;
      if (saved != null && !saved.isCompleted) saved.completeError(e, stack);
    } finally {
      _cloudSaveTimer?.cancel();
      _cloudSaveTimer = null;
      for (final connection in _cloudLive.values) {
        connection.cancel();
      }
      _cloudLive.clear();
      await engine.stop();
      if (_discarding) {
        // Even if capture shutdown failed, no writer may outlive deletion.
        await _processing;
        await _translations;
      }
      final current = record;
      if (current != null && _discarding) {
        try {
          await _deleteStoredRecord(current.id);
          await _reloadRecords();
        } catch (e) {
          error = e.toString();
        }
      } else if (current != null) {
        for (final line in current.lines) {
          if (line.transcriptionStatus == 'partial') {
            line.transcriptionStatus = 'interrupted';
          }
          if (_directForSession && line.translationStatus == 'pending') {
            line.translationStatus = 'interrupted';
          }
        }
        current.status = backgroundFinishing
            ? 'finishing'
            : error == null
            ? 'completed'
            : 'error';
        current.error = error;
        try {
          if (current.summaryStatus == 'pending') {
            await store.save(current);
            if (_disposed) {
              current.summaryStatus = 'interrupted';
            } else if (current.lines.isEmpty) {
              current.summaryStatus = 'empty';
            } else {
              generatingSummary = true;
              _notify();
              try {
                final result = await translator.summarize(
                  current.lines.map((line) => line.text).toList(),
                  current.summaryLanguage!,
                );
                current.title = result.title;
                current.summary = result.summary;
                current.summaryStatus = 'done';
              } catch (e) {
                current.summaryStatus = 'failed';
                current.summaryError = e.toString();
                warning = 'summaryFailed';
              } finally {
                generatingSummary = false;
              }
            }
          }
          current.status = error == null ? 'completed' : 'error';
          await store.save(current);
          await _reloadRecords();
        } catch (e, s) {
          AppLog.instance.error('save', e, s);
          error = e.toString();
          current.status = 'error';
          current.error = error;
        }
      }
      translator.stop();
      _queue.clear();
      _translationQueue.clear();
      levels.clear();
      levelHistory.clear();
      try {
        await MobilePlatform.backgroundWork(false);
      } catch (e) {
        error ??= e.toString();
      }
      phase = SessionPhase.idle;
      backgroundFinishing = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    catalog.dispose();
    sharedHost.dispose();
    recordSummarizer.stop();
    if (generatingSummary) translator.stop();
    _timer?.cancel();
    _hostTimer?.cancel();
    unawaited(stop());
    super.dispose();
  }
}

/// Overrides from the environment; an empty value counts as unset.
String? environmentValue(String name) {
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? null : value;
}
