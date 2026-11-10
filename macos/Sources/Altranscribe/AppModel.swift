import AppKit
import Observation
import UniformTypeIdentifiers
import AltranscribeCore

/// What the sidebar has selected: a capture page, settings, or a saved transcript.
enum Destination: Hashable {
    case live, files, settings, transcript(UUID)
}

enum SessionPhase { case idle, preparing, recording, paused, finishing, files }
enum SettingsPage { case general, speech, text }
enum QueueStatus { case waiting, processing, completed, failed, cancelled }
/// The file the queue is working on, for the progress shown on the files page.
struct FileRun: Equatable {
    enum Stage: Equatable { case transcribing, translating, summarizing }
    let recordID: UUID
    let fileName: String
    let duration: Double
    let configuration: AppSettings
    var processed = 0.0 { didSet { updated = .now } }
    var stage = Stage.transcribing
    let started = Date()
    /// When `processed` last moved, so speed and time left stay steady between chunks.
    private(set) var updated = Date()
}

/// One model the current engine can use without downloading anything.
struct SpeechModelChoice: Identifiable, Hashable {
    let id: String
    let title: String
}

struct QueuedFile: Identifiable {
    let id = UUID()
    let url: URL
    var status: QueueStatus = .waiting
    var progress = 0.0
    var error: LocalizedText?
    var recordID: UUID?
}

/// Serialize snapshots off the UI actor; a late interim save cannot replace a newer final save.
private actor RecordWriter {
    let store: RecordStore
    private var revisions: [UUID: UInt64] = [:]
    init(store: RecordStore) { self.store = store }
    func save(_ record: TranscriptRecord, revision: UInt64) throws {
        guard revision > revisions[record.id, default: 0] else { return }
        try store.save(record)
        revisions[record.id] = revision
    }
}

@MainActor @Observable final class AppModel {
    var settings = AppSettings()
    var destination: Destination? = .live
    var settingsPage: SettingsPage = .general
    var source: AudioSource = .microphone
    var records: [TranscriptRecord] = []
    var activeRecordID: UUID?
    var queue: [QueuedFile] = []
    var queueRunning = false
    var phase: SessionPhase = .idle
    var status = LocalizedText("Ready")
    var meter: Float = 0
    var elapsed = 0.0
    var search = ""
    var error: LocalizedText?
    var downloadID: String?
    var downloadTask: Task<Void, Never>?
    var modelRevision = 0
    var appleSpeechLocales: [String] = []
    var appleSpeechStatus: AppleSpeechStatus = .checking
    var isPostProcessing = false
    private(set) var postProcessingID: UUID?
    var renamingRecordID: UUID?
    var pendingDeletion: UUID?
    /// When the last live session ended through Stop and Save, set in the same update that returns to idle.
    var sessionSavedAt: Date?
    private(set) var pendingTranslations = 0
    /// Set while the queue processes a file; cleared when the queue stops.
    var fileRun: FileRun?

    let paths: AppPaths
    let store: RecordStore
    private let writer: RecordWriter
    private var saveRevision: UInt64 = 0
    private let whisper = NativeWhisper()
    private let nemotron = NativeNemotron()
    private let fluidAudio = NativeFluidAudio()
    private let appleSpeech = NativeAppleSpeech()
    private let api: APIClient
    private let capture = AudioCapture()
    private var cloudSpeech: CloudSpeechSession?
    private var work: Task<Void, Never>?
    private var translationTasks: [UUID: Task<Void, Never>] = [:]
    private struct TranslationJob {
        var segment: TranscriptSegment
        var provisional: Bool
    }
    private var translationQueue: [TranslationJob] = []
    private var draftTranslation: Task<Void, Never>?
    private var partialID: UUID?
    private var lastDraftTranslation = Date.distantPast
    private var lastDraftRequest: (id: UUID, text: String)?
    private var liveSentences = LiveSentenceAssembler()
    private var sentenceRecordID: UUID?
    private var discard = false
    private var deferredSave: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    var captions: CaptionWindow?
    private var preparedRecordingLocation = false

    init(paths: AppPaths = AppPaths(), api: APIClient = APIClient()) {
        self.api = api
        self.paths = paths; store = RecordStore(paths: paths)
        writer = RecordWriter(store: store)
        do { settings = try store.loadSettings() }
        catch { self.error = LocalizedText("Settings could not be read. Defaults are in use; the original settings file was retained.") }
        do {
            let loaded = try store.load()
            records = loaded.records
            if loaded.unreadable > 0 {
                error = LocalizedText("Unreadable record files: %@. The files were retained.", String(loaded.unreadable))
            }
        } catch { self.error = LocalizedText(error: error) }
    }

    var busy: Bool { phase != .idle || isPostProcessing }
    var recordingFolder: URL {
        settings.recordingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? paths.recordings
    }
    func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.title = L("Recording Location")
        panel.prompt = L("Choose Folder")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = recordingFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.recordingDirectory = url.path
            saveSettings()
        }
    }
    func prepareRecordingLocation() async {
        guard !preparedRecordingLocation else { return }
        preparedRecordingLocation = true
        guard records.contains(where: { $0.hasRecording == true && $0.recordingDirectory == nil }) else { return }
        do {
            let folder = paths.recordings
            // Documents access may wait for a macOS permission prompt. Keep the window responsive.
            try await Task.detached {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }.value
            for index in records.indices where records[index].hasRecording == true {
                try store.relocateRecording(&records[index])
            }
        } catch {
            self.error = LocalizedText("Recordings could not be moved. Existing audio is still available at its original location.")
        }
    }
    var activeRecord: TranscriptRecord? { records.first { $0.id == activeRecordID } }
    var isCapturing: Bool { phase == .recording || phase == .paused }
    var filteredRecords: [TranscriptRecord] { records.filter { $0.matches(search) } }
    /// The record the floating captions follow: only a live session while it is captured or finishing.
    /// Idle captions are empty; a file being transcribed or a session that has ended is never shown.
    var captionRecord: TranscriptRecord? {
        guard phase == .recording || phase == .paused || phase == .finishing,
              let record = activeRecord, record.source != .file else { return nil }
        return record
    }
    var captionSegments: [TranscriptSegment] { Array((captionRecord?.segments ?? []).suffix(settings.visibleCaptionCount)) }
    func isTranslationPending(_ id: UUID) -> Bool {
        translationTasks[id] != nil || translationQueue.contains { $0.segment.id == id }
    }
    var currentCaption: TranscriptSegment? { captionRecord?.segments.last }
    var currentCaptionTranslation: TranscriptSegment? { captionRecord?.segments.last { $0.translation != nil } }
    var modelReady: Bool {
        _ = modelRevision
        switch settings.speechProvider {
        case .whisper: return FileManager.default.fileExists(atPath: settings.effectiveModelPath)
        case .nemotron: return settings.nemotronModel.isInstalled(in: paths.models)
        case .fluidAudio: return settings.fluidAudioModel.isInstalled(in: paths.models)
        case .appleSpeech: return appleSpeechStatus == .installed
        default: return true
        }
    }
    func saveSettings() {
        do { try store.saveSettings(settings) } catch { self.error = LocalizedText(error: error) }
    }
    /// A session can begin only with a usable speech model and, where translation or a summary
    /// needs it, a text model. The home page explains whichever is missing.
    func canStart(live: Bool) -> Bool { modelReady && textIssue(live: live) == nil }
    func textIssue(live: Bool) -> LocalizedText? {
        guard settings.needsTextModel(live: live) else { return nil }
        if settings.textModelMissing(live: live) { return LocalizedText("Translation or summary needs a text model.") }
        return settings.textProvider == .apple ? NativeAppleText.availabilityIssue : nil
    }
    /// What the current engine can switch to in place: installed local models, the cloud file models,
    /// or the languages Apple's transcriber supports. Downloading stays in Settings.
    var speechModelChoices: [SpeechModelChoice] {
        _ = modelRevision
        let models = paths.models
        switch settings.speechProvider {
        case .whisper:
            var choices = WhisperModel.catalog
                .filter { FileManager.default.fileExists(atPath: models.appendingPathComponent($0.filename).path) }
                .map { SpeechModelChoice(id: models.appendingPathComponent($0.filename).path, title: $0.title) }
            let path = settings.effectiveModelPath
            if !path.isEmpty, !choices.contains(where: { $0.id == path }), FileManager.default.fileExists(atPath: path) {
                choices.append(SpeechModelChoice(id: path, title: URL(fileURLWithPath: path).lastPathComponent))
            }
            return choices
        case .nemotron:
            return NemotronModel.catalog.filter { $0.isInstalled(in: models) }.map {
                SpeechModelChoice(id: $0.id, title: $0.multilingual ? L("Nemotron 3.5 · Multilingual") : L("Nemotron · English"))
            }
        case .fluidAudio:
            return FluidAudioModel.allCases.filter { $0.isInstalled(in: models) }.map { SpeechModelChoice(id: $0.id, title: $0.title) }
        case .appleSpeech:
            return appleSpeechLocales.map {
                SpeechModelChoice(id: $0, title: InterfaceLanguage.current.locale.localizedString(forIdentifier: $0) ?? $0)
            }
        case .compatible:
            return OpenAITranscriptionModel.allCases.map {
                SpeechModelChoice(id: $0.rawValue, title: $0.isDeprecated ? $0.rawValue + " · " + L("legacy") : $0.rawValue)
            }
        case .gemini:
            return [SpeechModelChoice(id: settings.effectiveGeminiSpeechModel, title: settings.effectiveGeminiSpeechModel)]
        }
    }
    /// The current engine's model, as one of `speechModelChoices`.
    var selectedSpeechModel: String {
        get {
            switch settings.speechProvider {
            case .whisper: settings.effectiveModelPath
            case .nemotron: settings.nemotronModel.id
            case .fluidAudio: settings.fluidAudioModel.id
            case .appleSpeech: settings.appleSpeechLocale
            case .compatible: settings.effectiveSpeechModel
            case .gemini: settings.effectiveGeminiSpeechModel
            }
        }
        set {
            switch settings.speechProvider {
            case .whisper: settings.modelPath = newValue
            case .nemotron: settings.nemotronModelID = newValue
            case .fluidAudio: settings.fluidAudioModelID = newValue
            case .appleSpeech: settings.appleSpeechLocaleID = newValue
            case .compatible: settings.speechModel = newValue; settings.speechModelOverride = nil
            case .gemini: settings.geminiSpeechModel = newValue
            }
        }
    }
    var modelIssue: LocalizedText? {
        guard !modelReady else { return nil }
        switch settings.speechProvider {
        case .whisper:
            return settings.effectiveModelPath.isEmpty ? LocalizedText("No Whisper model is selected.")
                                                       : LocalizedText("The selected Whisper model file is missing.")
        case .appleSpeech: return LocalizedText(verbatim: appleSpeechStatus.title)
        default: return LocalizedText("The selected model is not downloaded yet.")
        }
    }

    private func prepare(_ configuration: AppSettings, live: Bool = false) async throws -> (speechKey: String, textKey: String) {
        var speechKey = ""
        var textKey = ""
        if (configuration.translate && !(live && configuration.usesDirectSpeechTranslation)) || configuration.summarize {
            guard !configuration.effectiveTextModel.isEmpty else {
                throw AppError("Translation or summary is enabled. Configure a text model in Settings first.")
            }
            if configuration.textProvider == .apple {
                try NativeAppleText.checkAvailability()
            } else {
                let endpoint = try APIEndpoint(configuration.textEndpoint)
                textKey = try await KeychainStore.read(endpoint: configuration.textEndpoint)
                if textKey.isEmpty && !endpoint.isLoopback { throw AppError("Save an API key for the text service.") }
            }
        }
        if configuration.speechProvider == .whisper {
            try await whisper.load(model: configuration.effectiveModelPath, useGPU: configuration.useGPU, live: live)
        } else if configuration.speechProvider == .nemotron {
            let model = configuration.nemotronModel
            try await nemotron.load(model: model, directory: model.directory(in: paths.models), language: configuration.recognitionLanguage, live: live)
        } else if configuration.speechProvider == .fluidAudio {
            try await fluidAudio.load(model: configuration.fluidAudioModel, models: paths.models, live: live)
        } else if configuration.speechProvider == .appleSpeech {
            try await appleSpeech.load(locale: configuration.appleSpeechLocale)
        } else {
            let endpoint = try APIEndpoint(configuration.speechEndpoint)
            speechKey = try await KeychainStore.read(endpoint: configuration.speechEndpoint)
            if speechKey.isEmpty && !endpoint.isLoopback { throw AppError("Save an API key for the speech service.") }
        }
        try Task.checkCancellation()
        return (speechKey, textKey)
    }

    private func beginActivity(live: Bool = false) {
        activity = ProcessInfo.processInfo.beginActivity(options: live ? [.userInitiated, .latencyCritical, .idleSystemSleepDisabled] : [.userInitiated, .idleSystemSleepDisabled], reason: L("Transcribing audio"))
    }
    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func createRecord(source: AudioSource, file: URL?, configuration: AppSettings) throws -> UUID {
        let title = file?.deletingPathExtension().lastPathComponent ?? "\(source.title) · \(Localization.date(.now))"
        let speechModel: String
        if source != .file && configuration.usesCloudLive { speechModel = configuration.liveSpeechModel }
        else { switch configuration.speechProvider {
        case .whisper: speechModel = URL(fileURLWithPath: configuration.effectiveModelPath).deletingPathExtension().lastPathComponent
        case .nemotron: speechModel = configuration.nemotronModel.id
        case .fluidAudio: speechModel = configuration.fluidAudioModel.id
        case .appleSpeech: speechModel = "Apple SpeechTranscriber · " + configuration.appleSpeechLocale
        case .gemini: speechModel = configuration.effectiveGeminiSpeechModel
        case .compatible: speechModel = configuration.effectiveSpeechModel
        } }
        var record = TranscriptRecord(title: title, source: source, language: configuration.recognitionLanguage, speechModel: speechModel)
        record.sourcePath = file?.path
        record.hasRecording = source != .file && configuration.keepsRecording ? true : nil
        if record.hasRecording == true {
            record.recordingDirectory = configuration.recordingDirectory ?? paths.recordings.path
            record.recordingFilename = AppPaths.recordingFilename(for: record, title: source.title)
        }
        record.targetLanguage = configuration.translate ? configuration.targetLanguage : nil
        try store.save(record)
        records.insert(record, at: 0)
        activeRecordID = record.id
        return record.id
    }

    func startLive() {
        guard !busy else { return }
        saveSettings()
        let configuration = settings
        let summaryLanguage = InterfaceLanguage.current.speechCode
        let source = source
        phase = .preparing; status = LocalizedText("Preparing…")
        elapsed = 0; meter = 0; discard = false
        lastDraftTranslation = .distantPast; lastDraftRequest = nil; partialID = nil
        beginActivity(live: true)
        work = Task(priority: .userInitiated) { [self] in
            var recordID: UUID?
            var saved = false
            do {
                if source == .microphone { _ = try MicrophoneDevice.resolve(configuration.microphoneDeviceUID) }
                let keys = try await prepare(configuration, live: true)
                let id = try createRecord(source: source, file: nil, configuration: configuration)
                recordID = id
                if configuration.usesCloudLive {
                    let speech = CloudSpeechSession(settings: configuration, key: keys.speechKey, onUpdate: { [weak self] update in
                        try await self?.saveSegments(update.finalized ? [update.segment] : [], partial: update.finalized ? nil : update.segment,
                                                     recordID: id, configuration: configuration, textKey: keys.textKey)
                    }, onFailure: { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.activeRecordID == id else { return }
                            await self.capture.stop()
                        }
                    })
                    cloudSpeech = speech
                    try await speech.start()
                }
                if configuration.speechProvider == .appleSpeech {
                    try await appleSpeech.startLive(vocabulary: configuration.vocabulary, onUpdate: { [weak self] update in
                        try await self?.saveSegments(update.finalized, partial: update.partial, recordID: id,
                                                     configuration: configuration, textKey: keys.textKey)
                    }, onFailure: { [weak self] in await self?.capture.stop() })
                }
                status = LocalizedText("Starting audio capture…")
                let chunks = try await capture.start(source: source, chunkSeconds: configuration.liveChunkSeconds,
                    automaticChunks: configuration.usesBatchLiveAudio && (configuration.liveChunkMode ?? .automatic) == .automatic,
                    adaptiveGain: configuration.adaptiveInputGain ?? true, voiceProcessing: configuration.microphoneVoiceProcessing ?? false,
                    microphoneUID: configuration.microphoneDeviceUID,
                    recordingURL: configuration.keepsRecording ? activeRecord.map { paths.recording($0) } : nil) { [weak self] level, duration in
                    Task { @MainActor in
                        guard let self, self.phase == .recording else { return }
                        self.meter = level
                        // The clock shows whole seconds. Publishing every audio buffer would
                        // re-evaluate each view that shows it about ten times a second.
                        let seconds = duration.rounded(.down)
                        if seconds != self.elapsed { self.elapsed = seconds }
                    }
                }
                try Task.checkCancellation()
                phase = .recording; status = LocalizedText("Listening")
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    if let cloudSpeech { try await cloudSpeech.accept(chunk) }
                    else if configuration.speechProvider == .appleSpeech { try await appleSpeech.acceptLive(chunk) }
                    else { try await process(chunk, recordID: id, configuration: configuration, keys: keys) }
                }
                phase = .finishing
                if configuration.speechProvider == .appleSpeech { try await appleSpeech.finishLive() }
                if let cloudSpeech, try await !cloudSpeech.finish(), let index = records.firstIndex(where: { $0.id == id }) {
                    records[index].error = await cloudSpeech.warning?.message
                        ?? LocalizedText("The preview translation service did not confirm the final output. Review the last sentence.")
                }
                try await finishRecord(id, configuration: configuration, textKey: keys.textKey, summaryLanguage: summaryLanguage)
                saved = true
            } catch is CancellationError {
                if let recordID { await finishInterrupted(recordID) }
            } catch {
                if let recordID { await failRecord(recordID, error: error) }
                self.error = LocalizedText(error: error)
            }
            await capture.stop()
            if let recordID, let index = records.firstIndex(where: { $0.id == recordID }), records[index].hasRecording == true {
                records[index].hasRecording = FileManager.default.fileExists(atPath: paths.recording(records[index]).path) ? true : nil
                records[index].recordingDuration = capture.recordedDuration
                await persist(index)
            }
            await cloudSpeech?.cancel(); cloudSpeech = nil
            await drainTranslations(cancel: true)
            liveSentences = LiveSentenceAssembler(); sentenceRecordID = nil
            if let recordID, let index = records.firstIndex(where: { $0.id == recordID }) {
                for line in records[index].segments.indices where records[index].segments[line].translationIsProvisional == true {
                    records[index].segments[line].translation = nil
                    records[index].segments[line].translationIsProvisional = nil
                    records[index].segments[line].translationSource = nil
                }
            }
            await whisper.unload()
            await nemotron.unload()
            await fluidAudio.unload()
            await appleSpeech.unload()
            if discard, let recordID { deleteRecord(recordID) }
            if saved { sessionSavedAt = .now }
            phase = .idle; meter = 0; status = LocalizedText("Ready"); work = nil
            endActivity()
        }
    }

    func togglePause() {
        guard phase == .recording || phase == .paused else { return }
        let pause = phase == .recording
        capture.pause(pause)
        phase = pause ? .paused : .recording
        meter = 0; status = pause ? LocalizedText("Paused") : LocalizedText("Listening")
    }
    func stopAndSave() {
        guard phase == .recording || phase == .paused else { return }
        phase = .finishing; status = LocalizedText("Finishing remaining audio…")
        Task { await capture.stop() }
    }
    func cancel(discardRecording: Bool = false) {
        discard = discardRecording
        work?.cancel()
        translationTasks.values.forEach { $0.cancel() }
        status = LocalizedText("Stopping…")
        Task { await cloudSpeech?.cancel(); await capture.stop() }
    }

    private func process(_ chunk: AudioChunk, recordID: UUID, configuration: AppSettings, keys: (speechKey: String, textKey: String)) async throws {
        if configuration.usesBatchLiveAudio && !configuration.speechProvider.isLocal && !chunk.containsSpeech { return }
        let segments: [TranscriptSegment]
        var partial: TranscriptSegment?
        if configuration.speechProvider == .whisper {
            segments = try await whisper.transcribe(chunk, language: configuration.sourceLanguage, vocabulary: configuration.vocabulary)
        } else if configuration.speechProvider == .nemotron {
            let update = try await nemotron.accept(chunk)
            segments = update.finalized; partial = update.partial
        } else if configuration.speechProvider == .fluidAudio {
            segments = try await fluidAudio.transcribe(chunk)
        } else if configuration.speechProvider == .appleSpeech {
            segments = try await appleSpeech.transcribe(chunk, vocabulary: configuration.vocabulary)
        } else {
            segments = try await api.transcribe(chunk, settings: configuration, key: keys.speechKey) { [weak self] warning in
                Task { @MainActor in self?.error = warning.message }
            }
        }
        try await saveSegments(segments, partial: partial, recordID: recordID, configuration: configuration, textKey: keys.textKey)
    }

    func saveSegments(_ segments: [TranscriptSegment], partial: TranscriptSegment? = nil,
                              recordID: UUID, configuration: AppSettings, textKey: String) async throws {
        try Task.checkCancellation()
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        var segments = segments, partial = partial
        if records[index].source != .file && configuration.speechProvider != .nemotron {
            if sentenceRecordID != recordID { liveSentences = LiveSentenceAssembler(); sentenceRecordID = recordID }
            (segments, partial) = liveSentences.update(segments, partial: partial)
        }
        if segments.contains(where: { $0.id == partialID }) {
            partialID = nil; draftTranslation?.cancel()
        }
        if let partial { partialID = partial.id }
        var changed = false, needsSort = false
        for segment in segments + (partial.map { [$0] } ?? []) {
            var segment = segment
            if configuration.usesDirectSpeechTranslation, records[index].source != .file, segment.translation != nil {
                segment.translationIsProvisional = partial?.id == segment.id ? true : nil
                segment.translationSource = partial?.id == segment.id ? segment.text : nil
            }
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                (segment.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let line = records[index].segments.lastIndex(where: { $0.id == segment.id }) {
                    records[index].segments.remove(at: line); changed = true
                }
                continue
            }
            if let line = records[index].segments.lastIndex(where: { $0.id == segment.id }) {
                if records[index].segments[line].text != segment.text || records[index].segments[line].end != segment.end {
                    let old = records[index].segments[line]
                    if translationText(old.text) != translationText(segment.text) {
                        records[index].segments[line].translationError = nil
                        // Keep feedback while the growing sentence is translated again.
                        records[index].segments[line].translationIsProvisional = old.translation == nil ? nil : true
                        records[index].segments[line].translationSource = old.translation == nil ? nil : (old.translationSource ?? old.text)
                    }
                    records[index].segments[line].text = segment.text
                    records[index].segments[line].end = segment.end
                    changed = true
                }
                if records[index].segments[line].start != segment.start {
                    records[index].segments[line].start = segment.start; changed = true; needsSort = true
                }
                if let translation = segment.translation, records[index].segments[line].translation != translation {
                    records[index].segments[line].translation = translation; changed = true
                }
                if configuration.usesDirectSpeechTranslation, records[index].source != .file, segment.translation != nil {
                    records[index].segments[line].translationIsProvisional = partial?.id == segment.id ? true : nil
                    records[index].segments[line].translationSource = partial?.id == segment.id ? segment.text : nil
                    changed = true
                }
            } else {
                needsSort = needsSort || (records[index].segments.last.map { $0.start > segment.start } ?? false)
                records[index].segments.append(segment); changed = true
            }
        }
        if changed {
            if needsSort { records[index].segments.sort { $0.start < $1.start } }
            if segments.isEmpty, partial != nil { scheduleSave(recordID) } else { try await persistNow(index) }
        }
        if configuration.translate && !(records[index].source != .file && configuration.usesDirectSpeechTranslation) {
            if records[index].source == .file {
                let snapshot = records[index], incoming = Set(segments.map(\.id))
                let pending = snapshot.segments.indices.filter {
                    let line = snapshot.segments[$0]
                    return incoming.contains(line.id) && (line.translation == nil || line.translationIsProvisional == true) && line.translationError == nil
                }
                if !pending.isEmpty, fileRun?.recordID == recordID { fileRun?.stage = .translating }
                try await translateBatch(snapshot, indices: pending, configuration: configuration, key: textKey) { line, result in
                    guard let index = self.records.firstIndex(where: { $0.id == recordID }),
                          let current = self.records[index].segments.firstIndex(where: { $0.id == snapshot.segments[line].id }) else { return }
                    switch result {
                    case .success(let text):
                        self.records[index].segments[current].translation = text
                        self.records[index].segments[current].translationError = nil
                    case .failure(let error):
                        self.records[index].segments[current].translation = nil
                        self.records[index].segments[current].translationError = LocalizedText(error: error)
                    }
                    self.records[index].segments[current].translationIsProvisional = nil
                    self.records[index].segments[current].translationSource = nil
                    try await self.persistNow(index)
                }
            } else {
                for segment in segments {
                    try Task.checkCancellation()
                    guard let line = records[index].segments.last(where: { $0.id == segment.id }),
                          line.translation == nil || line.translationIsProvisional == true,
                          line.translationError == nil else { continue }
                    try enqueueTranslation(line, recordID: recordID, configuration: configuration, textKey: textKey)
                }
            }
            if let partial, records[index].source != .file,
               configuration.textProvider != .gemini {
                scheduleDraftTranslation(partial.id, recordID: recordID, configuration: configuration, textKey: textKey)
            }
        }
    }

    private func scheduleDraftTranslation(_ id: UUID, recordID: UUID, configuration: AppSettings, textKey: String) {
        guard draftTranslation == nil else { return }
        draftTranslation = Task(priority: .userInitiated) {
            defer { draftTranslation = nil }
            do {
                try await Task.sleep(for: .seconds(max(0.6, 4 - Date().timeIntervalSince(lastDraftTranslation))))
                guard partialID == id, let line = records.first(where: { $0.id == recordID })?.segments.last(where: { $0.id == id }),
                      line.text.count >= 16, line.translationSource != line.text,
                      lastDraftRequest?.id != id || lastDraftRequest?.text != line.text else { return }
                lastDraftTranslation = .now
                lastDraftRequest = (id, line.text)
                try enqueueTranslation(line, recordID: recordID, configuration: configuration, textKey: textKey, provisional: true)
            } catch is CancellationError { }
            catch { self.error = LocalizedText(error: error) }
        }
    }

    private func translateSegment(_ segment: TranscriptSegment, recordID: UUID, configuration: AppSettings, textKey: String, provisional: Bool = false) async throws {
        guard let recordIndex = records.firstIndex(where: { $0.id == recordID }),
              let segmentIndex = records[recordIndex].segments.lastIndex(where: { $0.id == segment.id }) else { return }
        let language = records[recordIndex].language
        let context = records[recordIndex].segments[..<segmentIndex].suffix(3).map(\.text).joined(separator: "\n")
        var translation: String?
        var failure: LocalizedText?
        do {
            translation = try await api.translate(segment.text, sourceLanguage: language, context: context, settings: configuration, key: textKey)
        } catch is CancellationError { throw CancellationError() }
        catch { failure = LocalizedText(error: error) }
        try Task.checkCancellation()
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              let line = records[index].segments.lastIndex(where: { $0.id == segment.id }) else { return }
        let current = translationText(records[index].segments[line].text), requested = translationText(segment.text)
        guard current == requested || (provisional && current.hasPrefix(requested)) else { return }
        // A draft failure must not prevent the eventual final translation.
        if provisional && failure != nil { return }
        records[index].segments[line].translation = translation
        records[index].segments[line].translationError = failure
        records[index].segments[line].translationIsProvisional = provisional ? true : nil
        records[index].segments[line].translationSource = provisional ? segment.text : nil
        try await writeSnapshot(records[index])
    }

    private func enqueueTranslation(_ segment: TranscriptSegment, recordID: UUID, configuration: AppSettings, textKey: String, provisional: Bool = false) throws {
        if let queued = translationQueue.firstIndex(where: { $0.segment.id == segment.id }) {
            translationQueue[queued] = TranslationJob(segment: segment, provisional: provisional)
            return
        }
        // Text-service latency must not fill the audio queue or stop recognition.
        if !provisional, translationQueue.count >= 8,
           let draft = translationQueue.firstIndex(where: \.provisional) { translationQueue.remove(at: draft) }
        guard translationQueue.count < 8 else {
            if provisional { return }
            if let index = records.firstIndex(where: { $0.id == recordID }),
               let line = records[index].segments.lastIndex(where: { $0.id == segment.id }) {
                records[index].segments[line].translationError = LocalizedText("Translation is falling behind. The original text was saved; translate it later from Library.")
                scheduleSave(recordID)
            }
            return
        }
        translationQueue.append(TranslationJob(segment: segment, provisional: provisional))
        pendingTranslations = translationQueue.count + translationTasks.count
        startTranslations(recordID: recordID, configuration: configuration, textKey: textKey)
    }

    private func startTranslations(recordID: UUID, configuration: AppSettings, textKey: String) {
        // Keep Gemini and the shared on-device model serial; other text services get two bounded lanes.
        let limit = [.apple, .gemini].contains(configuration.textProvider) ? 1 : 2
        while translationTasks.count < limit,
              let index = translationQueue.firstIndex(where: { !$0.provisional && translationTasks[$0.segment.id] == nil }) ??
                translationQueue.firstIndex(where: { translationTasks[$0.segment.id] == nil }) {
            let next = translationQueue.remove(at: index)
            translationTasks[next.segment.id] = Task(priority: .userInitiated) {
                defer {
                    translationTasks[next.segment.id] = nil
                    pendingTranslations = translationQueue.count + translationTasks.count
                    if !Task.isCancelled { startTranslations(recordID: recordID, configuration: configuration, textKey: textKey) }
                }
                do { try await translateSegment(next.segment, recordID: recordID, configuration: configuration, textKey: textKey, provisional: next.provisional) }
                catch is CancellationError { }
                catch { self.error = LocalizedText(error: error); cancel() }
            }
        }
    }

    private func translationText(_ text: String) -> String {
        var value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        // A delayed sentence-ending period is harmless; signs, decimals and word boundaries are not.
        while let last = value.last, last == "." || last == "。" { value.removeLast() }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A bounded pool shared by file chunks and historical retranslations. Context and result
    /// indices come from the original transcript, so completion order never changes sentence order.
    private func translateBatch(_ record: TranscriptRecord, indices: [Int], configuration: AppSettings, key: String,
                                receive: @MainActor (Int, Result<String, Error>) async throws -> Void) async throws {
        let api = api
        let translate: @Sendable (Int) async throws -> (Int, Result<String, Error>) = { index in
            try Task.checkCancellation()
            let context = record.segments[..<index].suffix(3).map(\.text).joined(separator: "\n")
            do {
                let text = try await api.translate(record.segments[index].text, sourceLanguage: record.language,
                                                   context: context, settings: configuration, key: key)
                return (index, .success(text))
            } catch is CancellationError { throw CancellationError() }
            catch { return (index, .failure(error)) }
        }
        try await withThrowingTaskGroup(of: (Int, Result<String, Error>).self) { group in
            var next = 0
            for index in indices.prefix(configuration.fileTranslationConcurrency) {
                group.addTask { try await translate(index) }; next += 1
            }
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                try await receive(index, result)
                if next < indices.count {
                    let index = indices[next]; next += 1
                    group.addTask { try await translate(index) }
                }
            }
        }
    }

    private func drainTranslations(cancel: Bool = false) async {
        draftTranslation?.cancel(); await draftTranslation?.value
        draftTranslation = nil; partialID = nil
        if cancel {
            translationQueue.removeAll()
            translationTasks.values.forEach { $0.cancel() }
        }
        while let task = translationTasks.values.first { await task.value }
        pendingTranslations = 0
    }

    func finishRecord(_ id: UUID, configuration: AppSettings, textKey: String, summaryLanguage: String = InterfaceLanguage.current.speechCode) async throws {
        if fileRun?.recordID == id { fileRun?.stage = .transcribing }
        if configuration.speechProvider == .nemotron {
            let tail = try await nemotron.finish()
            try await saveSegments(tail.finalized, recordID: id, configuration: configuration, textKey: textKey)
        }
        await drainTranslations()
        try Task.checkCancellation()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if configuration.summarize, !records[index].segments.isEmpty {
            status = LocalizedText("Creating summary…")
            if fileRun?.recordID == id { fileRun?.stage = .summarizing }
            do {
                let result = try await api.summarize(records[index].fullText, language: summaryLanguage, settings: configuration, key: textKey)
                try Task.checkCancellation()
                records[index].summary = result.summary
                records[index].summaryLanguage = summaryLanguage
                useSummaryTitle(result.title, at: index)
            } catch is CancellationError { throw CancellationError() }
            catch { records[index].error = LocalizedText(error: error, context: "Summary failed: ") }
        }
        records[index].status = .completed
        try await persistNow(index)
    }
    private func finishInterrupted(_ id: UUID) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = .interrupted
        await persist(index)
    }
    private func failRecord(_ id: UUID, error: Error) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = .failed; records[index].error = LocalizedText(error: error)
        await persist(index)
    }
    private func persist(_ index: Int) async {
        do { try await persistNow(index) } catch { self.error = LocalizedText(error: error) }
    }
    private func persistNow(_ index: Int) async throws {
        deferredSave?.cancel(); deferredSave = nil
        try await writeSnapshot(records[index])
    }
    private func writeSnapshot(_ record: TranscriptRecord) async throws {
        saveRevision += 1
        try await writer.save(record, revision: saveRevision)
    }
    /// Interim text changes several times a second and is rewritten in place, so it is written at most
    /// once a second. Final text, translations and status changes are written immediately.
    private func scheduleSave(_ recordID: UUID) {
        guard deferredSave == nil else { return }
        deferredSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.deferredSave = nil
            if let index = self.records.firstIndex(where: { $0.id == recordID }) { await self.persist(index) }
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = L("Import Audio or Video…")
        panel.prompt = L("Import")
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
    func addFiles(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            if !queue.contains(where: { $0.url == url && ($0.status == .waiting || $0.status == .processing) }) {
                queue.append(QueuedFile(url: url))
            }
        }
        destination = .files
    }
    // The running queue addresses items by index, so it is only edited while idle.
    func retryQueued(_ id: UUID) {
        guard !queueRunning, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].status = .waiting; queue[index].error = nil; queue[index].progress = 0
    }
    func removeQueued(_ id: UUID) {
        guard !queueRunning else { return }
        queue.removeAll { $0.id == id }
    }
    func clearCompletedQueue() {
        guard !queueRunning else { return }
        queue.removeAll { $0.status == .completed }
    }
    func startQueue() {
        guard !busy, queue.contains(where: { $0.status == .waiting }) else { return }
        queueRunning = true
        saveSettings()
        let configuration = settings
        let summaryLanguage = InterfaceLanguage.current.speechCode
        phase = .preparing; status = LocalizedText("Preparing…"); discard = false
        beginActivity()
        work = Task {
            do {
                let keys = try await prepare(configuration)
                phase = .files
                while let index = queue.firstIndex(where: { $0.status == .waiting }), !Task.isCancelled {
                    queue[index].status = .processing
                    let decoder = MediaDecoder(chunkSeconds: configuration.speechProvider.isLocal ? 20 : 600)
                    var recordID: UUID?
                    do {
                        status = LocalizedText(verbatim: queue[index].url.lastPathComponent)
                        let duration = try await decoder.open(queue[index].url)
                        if configuration.speechProvider == .nemotron { await nemotron.beginStream() }
                        let id = try createRecord(source: .file, file: queue[index].url, configuration: configuration)
                        recordID = id; queue[index].recordID = id
                        fileRun = FileRun(recordID: id, fileName: queue[index].url.lastPathComponent, duration: duration, configuration: configuration)
                        while let chunk = try await decoder.next() {
                            fileRun?.stage = .transcribing
                            try await process(chunk, recordID: id, configuration: configuration, keys: keys)
                            queue[index].progress = duration > 0 ? min(0.99, (chunk.start + chunk.duration) / duration) : 0
                            fileRun?.processed = duration > 0 ? min(duration, chunk.start + chunk.duration) : chunk.start + chunk.duration
                        }
                        try Task.checkCancellation()
                        try await finishRecord(id, configuration: configuration, textKey: keys.textKey, summaryLanguage: summaryLanguage)
                        queue[index].status = .completed; queue[index].progress = 1
                    } catch is CancellationError {
                        queue[index].status = .cancelled
                        if let recordID { await finishInterrupted(recordID) }
                    } catch {
                        queue[index].status = .failed; queue[index].error = LocalizedText(error: error)
                        if let recordID { await failRecord(recordID, error: error) }
                    }
                    await decoder.cancel()
                }
            } catch is CancellationError { /* Nothing was captured. */ }
            catch { self.error = LocalizedText(error: error) }
            await whisper.unload()
            await nemotron.unload()
            await fluidAudio.unload()
            await appleSpeech.unload()
            fileRun = nil
            phase = .idle; queueRunning = false; work = nil; status = LocalizedText("Ready")
            endActivity()
        }
    }

    func renameRecord(_ id: UUID, title: String) {
        guard !busy, let index = records.firstIndex(where: { $0.id == id }) else { return }
        do { records[index] = try store.rename(records[index], title: title) }
        catch { self.error = LocalizedText(error: error) }
    }
    private func useSummaryTitle(_ title: String?, at index: Int) {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { records[index] = try store.rename(records[index], title: title) }
        catch { records[index].error = LocalizedText(error: error, context: "Recording could not be renamed: ") }
    }
    func deleteRecord(_ id: UUID) {
        do {
            deferredSave?.cancel(); deferredSave = nil
            try store.delete(id)
            if destination == .transcript(id) {
                // Like Notes and Mail, move the selection to the neighbouring transcript.
                let visible = filteredRecords
                let next = visible.firstIndex { $0.id == id }.flatMap { index in
                    visible.indices.contains(index + 1) ? visible[index + 1] : index > 0 ? visible[index - 1] : nil
                }
                destination = next.map { .transcript($0.id) } ?? .live
            }
            records.removeAll { $0.id == id }
            if activeRecordID == id { activeRecordID = nil }
        } catch { self.error = LocalizedText(error: error) }
    }
    func export(_ record: TranscriptRecord, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.title = L("Export")
        panel.prompt = L("Save")
        panel.nameFieldLabel = L("Save As:")
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        let safeTitle = record.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle).\(format.rawValue)"
        if panel.runModal() == .OK, let url = panel.url {
            do { try TranscriptExport.render(record, as: format).write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = LocalizedText(error: error) }
        }
    }
    func copy(_ record: TranscriptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscriptExport.render(record, as: .text), forType: .string)
    }
    func download(_ model: WhisperModel) {
        guard downloadTask == nil else { return }
        downloadID = model.id
        downloadTask = Task {
            do {
                let url = try await model.download(to: paths.models)
                settings.modelPath = url.path; saveSettings(); modelRevision += 1
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = LocalizedText(error: error) } }
            downloadID = nil; downloadTask = nil
        }
    }
    func download(_ model: NemotronModel) {
        guard downloadTask == nil else { return }
        downloadID = model.id
        downloadTask = Task {
            do {
                _ = try await model.download(to: paths.models)
                settings.nemotronModelID = model.id; saveSettings(); modelRevision += 1
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = LocalizedText(error: error) } }
            downloadID = nil; downloadTask = nil
        }
    }
    func download(_ model: FluidAudioModel) {
        guard downloadTask == nil, !busy else { return }
        downloadID = model.id
        downloadTask = Task {
            do {
                try await model.download(to: paths.models)
                settings.fluidAudioModelID = model.id; saveSettings(); modelRevision += 1
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = LocalizedText(error: error) } }
            downloadID = nil; downloadTask = nil
        }
    }

    func refreshAppleSpeech() async {
        let locale = settings.appleSpeechLocale
        let locales = await NativeAppleSpeech.supportedLocales()
        let status = await NativeAppleSpeech.status(locale: locale)
        guard !Task.isCancelled, settings.appleSpeechLocale == locale else { return }
        appleSpeechLocales = locales
        appleSpeechStatus = status
    }

    func installAppleSpeech() {
        guard downloadTask == nil, !busy else { return }
        let locale = settings.appleSpeechLocale
        downloadID = "apple-speech"
        appleSpeechStatus = .downloading
        downloadTask = Task {
            do { try await NativeAppleSpeech.install(locale: locale) }
            catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = LocalizedText(error: error) } }
            downloadID = nil; downloadTask = nil
            Task { await refreshAppleSpeech() }
        }
    }

    var captionsVisible: Bool {
        get { captions?.isVisible ?? false }
        set {
            if newValue { showCaptions() }
            else { captions?.hide() }
        }
    }
    func showCaptions() {
        if captions == nil { captions = CaptionWindow(model: self) }
        captions?.show()
    }
    func postProcess(_ record: TranscriptRecord, summary: Bool) {
        guard !busy else { return }
        let configuration = settings
        let summaryLanguage = InterfaceLanguage.current.speechCode
        isPostProcessing = true; postProcessingID = record.id
        status = summary ? LocalizedText("Creating summary…") : LocalizedText("Translating…")
        beginActivity()
        work = Task {
            defer { isPostProcessing = false; postProcessingID = nil; work = nil; status = LocalizedText("Ready"); endActivity() }
            do {
                let key = configuration.textProvider == .apple ? "" : try await KeychainStore.read(endpoint: configuration.textEndpoint)
                if summary {
                    let result = try await api.summarize(record.fullText, language: summaryLanguage, settings: configuration, key: key)
                    try Task.checkCancellation()
                    if let index = records.firstIndex(where: { $0.id == record.id }) {
                        records[index].summary = result.summary
                        records[index].summaryLanguage = summaryLanguage
                        records[index].error = nil
                        useSummaryTitle(result.title, at: index)
                        try store.save(records[index])
                    }
                } else {
                    // Replace a translation as one saved result, so failures never mix languages.
                    var updated = record
                    var completed = 0
                    try await translateBatch(record, indices: Array(record.segments.indices), configuration: configuration, key: key) { line, result in
                        updated.segments[line].translation = try result.get()
                        updated.segments[line].translationError = nil
                        updated.segments[line].translationIsProvisional = nil
                        updated.segments[line].translationSource = nil
                        completed += 1
                        self.status = LocalizedText("Translating %@/%@", String(completed), String(record.segments.count))
                    }
                    try Task.checkCancellation()
                    updated.targetLanguage = configuration.targetLanguage
                    if let index = records.firstIndex(where: { $0.id == record.id }) {
                        try store.save(updated)
                        records[index] = updated
                    }
                }
            } catch is CancellationError { }
            catch { self.error = LocalizedText(error: error) }
        }
    }
}
