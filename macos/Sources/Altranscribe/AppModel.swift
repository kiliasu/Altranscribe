import AppKit
import Observation
import UniformTypeIdentifiers
import AltranscribeCore

/// What the sidebar has selected: one of the two capture pages or a saved transcript.
enum Destination: Hashable {
    case live, files, transcript(UUID)
}

enum SessionPhase { case idle, preparing, recording, paused, finishing, files }
enum QueueStatus { case waiting, processing, completed, failed, cancelled }
struct QueuedFile: Identifiable {
    let id = UUID()
    let url: URL
    var status: QueueStatus = .waiting
    var progress = 0.0
    var error: LocalizedText?
    var recordID: UUID?
}

@MainActor @Observable final class AppModel {
    var settings = AppSettings()
    var destination: Destination? = .live
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
    var isPostProcessing = false
    private(set) var postProcessingID: UUID?
    var renamingRecordID: UUID?
    var pendingDeletion: UUID?
    private(set) var pendingTranslations = 0

    let paths: AppPaths
    let store: RecordStore
    private let whisper = NativeWhisper()
    private let nemotron = NativeNemotron()
    private let api: APIClient
    private let capture = AudioCapture()
    private var work: Task<Void, Never>?
    private var translationWork: Task<Void, Never>?
    private var translationQueue: [TranscriptSegment] = []
    private var translatingID: UUID?
    private var discard = false
    private var activity: NSObjectProtocol?
    var captions: CaptionWindow?

    init(paths: AppPaths = AppPaths(), api: APIClient = APIClient()) {
        self.api = api
        self.paths = paths; store = RecordStore(paths: paths)
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
    var activeRecord: TranscriptRecord? { records.first { $0.id == activeRecordID } }
    var isCapturing: Bool { phase == .recording || phase == .paused }
    var filteredRecords: [TranscriptRecord] { records.filter { $0.matches(search) } }
    var currentCaption: TranscriptSegment? { activeRecord?.segments.last }
    var currentCaptionTranslation: TranscriptSegment? { activeRecord?.segments.last { $0.translation != nil } }
    var modelReady: Bool {
        _ = modelRevision
        switch settings.speechProvider {
        case .whisper: return FileManager.default.fileExists(atPath: settings.effectiveModelPath)
        case .nemotron: return settings.nemotronModel.isInstalled(in: paths.models)
        default: return true
        }
    }
    var localProcessing: Bool {
        let localSpeech = settings.speechProvider.isLocal || (try? APIEndpoint(settings.speechEndpoint).isLoopback) == true
        return localSpeech && (!(settings.translate || settings.summarize) || (try? APIEndpoint(settings.textEndpoint).isLoopback) == true)
    }

    func saveSettings() {
        do { try store.saveSettings(settings) } catch { self.error = LocalizedText(error: error) }
    }

    private func prepare(_ configuration: AppSettings) async throws -> (speechKey: String, textKey: String) {
        var speechKey = ""
        var textKey = ""
        if configuration.translate || configuration.summarize {
            guard !configuration.textModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError("Translation or summary is enabled. Configure a text model in Settings first.")
            }
            let endpoint = try APIEndpoint(configuration.textEndpoint)
            textKey = try KeychainStore.read(endpoint: configuration.textEndpoint)
            if textKey.isEmpty && !endpoint.isLoopback { throw AppError("Save an API key for the text service.") }
        }
        if configuration.speechProvider == .whisper {
            try await whisper.load(model: configuration.effectiveModelPath, useGPU: configuration.useGPU)
        } else if configuration.speechProvider == .nemotron {
            let model = configuration.nemotronModel
            try await nemotron.load(model: model, directory: model.directory(in: paths.models), language: configuration.recognitionLanguage)
        } else {
            let endpoint = try APIEndpoint(configuration.speechEndpoint)
            speechKey = try KeychainStore.read(endpoint: configuration.speechEndpoint)
            if speechKey.isEmpty && !endpoint.isLoopback { throw AppError("Save an API key for the speech service.") }
        }
        try Task.checkCancellation()
        return (speechKey, textKey)
    }

    private func beginActivity() {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: L("Transcribing audio"))
    }
    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func createRecord(source: AudioSource, file: URL?, configuration: AppSettings) throws -> UUID {
        let title = file?.deletingPathExtension().lastPathComponent ?? "\(source.title) · \(Localization.date(.now))"
        let speechModel: String
        switch configuration.speechProvider {
        case .whisper: speechModel = URL(fileURLWithPath: configuration.effectiveModelPath).deletingPathExtension().lastPathComponent
        case .nemotron: speechModel = configuration.nemotronModel.id
        case .gemini: speechModel = configuration.geminiSpeechModel
        case .compatible: speechModel = configuration.speechModel
        }
        var record = TranscriptRecord(title: title, source: source, language: configuration.recognitionLanguage, speechModel: speechModel)
        record.sourcePath = file?.path
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
        beginActivity()
        work = Task { [self] in
            var recordID: UUID?
            do {
                let keys = try await prepare(configuration)
                let chunks = try await capture.start(source: source, chunkSeconds: configuration.speechProvider == .nemotron ? 0.32 : 8) { [weak self] level, duration in
                    Task { @MainActor in
                        guard let self, self.phase == .recording else { return }
                        self.meter = level; self.elapsed = duration
                    }
                }
                try Task.checkCancellation()
                let id = try createRecord(source: source, file: nil, configuration: configuration)
                recordID = id
                phase = .recording; status = LocalizedText("Listening")
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    try await process(chunk, recordID: id, configuration: configuration, keys: keys)
                }
                phase = .finishing
                try await finishRecord(id, configuration: configuration, textKey: keys.textKey, summaryLanguage: summaryLanguage)
            } catch is CancellationError {
                if let recordID { finishInterrupted(recordID) }
            } catch {
                if let recordID { failRecord(recordID, error: error) }
                self.error = LocalizedText(error: error)
            }
            await capture.stop()
            translationWork?.cancel()
            await translationWork?.value
            await whisper.unload()
            await nemotron.unload()
            if discard, let recordID { deleteRecord(recordID) }
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
        translationWork?.cancel()
        status = LocalizedText("Stopping…")
        Task { await capture.stop() }
    }

    private func process(_ chunk: AudioChunk, recordID: UUID, configuration: AppSettings, keys: (speechKey: String, textKey: String)) async throws {
        let segments: [TranscriptSegment]
        var partial: TranscriptSegment?
        if configuration.speechProvider == .whisper {
            segments = try await whisper.transcribe(chunk, language: configuration.sourceLanguage, vocabulary: configuration.vocabulary)
        } else if configuration.speechProvider == .nemotron {
            let update = try await nemotron.accept(chunk)
            segments = update.finalized; partial = update.partial
        } else { segments = try await api.transcribe(chunk, settings: configuration, key: keys.speechKey) }
        try await saveSegments(segments, partial: partial, recordID: recordID, configuration: configuration, textKey: keys.textKey)
    }

    func saveSegments(_ segments: [TranscriptSegment], partial: TranscriptSegment? = nil,
                              recordID: UUID, configuration: AppSettings, textKey: String) async throws {
        try Task.checkCancellation()
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        var changed = false
        for segment in segments + (partial.map { [$0] } ?? []) {
            if let line = records[index].segments.firstIndex(where: { $0.id == segment.id }) {
                if records[index].segments[line].text != segment.text || records[index].segments[line].end != segment.end {
                    records[index].segments[line].text = segment.text
                    records[index].segments[line].end = segment.end
                    changed = true
                }
            } else { records[index].segments.append(segment); changed = true }
        }
        if changed { try store.save(records[index]) }
        if configuration.translate {
            for segment in segments {
                try Task.checkCancellation()
                guard let line = records[index].segments.first(where: { $0.id == segment.id }),
                      line.translation == nil, line.translationError == nil else { continue }
                if records[index].source == .file {
                    try await translateSegment(line, recordID: recordID, configuration: configuration, textKey: textKey)
                } else {
                    try enqueueTranslation(line, recordID: recordID, configuration: configuration, textKey: textKey)
                }
            }
        }
    }

    private func translateSegment(_ segment: TranscriptSegment, recordID: UUID, configuration: AppSettings, textKey: String) async throws {
        guard let record = records.first(where: { $0.id == recordID }) else { return }
        let context = record.segments.filter { $0.start < segment.start }.suffix(3).map(\.text).joined(separator: "\n")
        var translation: String?
        var failure: LocalizedText?
        do {
            translation = try await api.translate(segment.text, sourceLanguage: record.language, context: context, settings: configuration, key: textKey)
        } catch is CancellationError { throw CancellationError() }
        catch { failure = LocalizedText(error: error) }
        try Task.checkCancellation()
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              let line = records[index].segments.firstIndex(where: { $0.id == segment.id }) else { return }
        records[index].segments[line].translation = translation
        records[index].segments[line].translationError = failure
        try store.save(records[index])
    }

    private func enqueueTranslation(_ segment: TranscriptSegment, recordID: UUID, configuration: AppSettings, textKey: String) throws {
        guard translatingID != segment.id, !translationQueue.contains(where: { $0.id == segment.id }) else { return }
        // Text-service latency must not fill the audio queue or stop recognition.
        guard translationQueue.count < 8 else {
            if let index = records.firstIndex(where: { $0.id == recordID }),
               let line = records[index].segments.firstIndex(where: { $0.id == segment.id }) {
                records[index].segments[line].translationError = LocalizedText("Translation is falling behind. The original text was saved; translate it later from Library.")
                try store.save(records[index])
            }
            return
        }
        translationQueue.append(segment)
        pendingTranslations += 1
        guard translationWork == nil else { return }
        translationWork = Task {
            defer {
                translationQueue.removeAll(); translatingID = nil
                pendingTranslations = 0; translationWork = nil
            }
            while !translationQueue.isEmpty, !Task.isCancelled {
                let next = translationQueue.removeFirst()
                translatingID = next.id
                do { try await translateSegment(next, recordID: recordID, configuration: configuration, textKey: textKey) }
                catch is CancellationError { break }
                catch { self.error = LocalizedText(error: error); cancel(); break }
                pendingTranslations -= 1
            }
        }
    }

    func finishRecord(_ id: UUID, configuration: AppSettings, textKey: String, summaryLanguage: String = InterfaceLanguage.current.speechCode) async throws {
        if configuration.speechProvider == .nemotron {
            let tail = try await nemotron.finish()
            try await saveSegments(tail.finalized, recordID: id, configuration: configuration, textKey: textKey)
        }
        await translationWork?.value
        try Task.checkCancellation()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if configuration.summarize, !records[index].segments.isEmpty {
            status = LocalizedText("Creating summary…")
            do {
                let result = try await api.summarize(records[index].fullText, language: summaryLanguage, settings: configuration, key: textKey)
                try Task.checkCancellation()
                records[index].summary = result.summary
                records[index].summaryLanguage = summaryLanguage
                if let title = result.title, !title.isEmpty { records[index].title = title }
            } catch is CancellationError { throw CancellationError() }
            catch { records[index].error = LocalizedText(error: error, context: "Summary failed: ") }
        }
        records[index].status = .completed
        try store.save(records[index])
    }
    private func finishInterrupted(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = .interrupted
        persist(index)
    }
    private func failRecord(_ id: UUID, error: Error) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = .failed; records[index].error = LocalizedText(error: error)
        persist(index)
    }
    private func persist(_ index: Int) {
        do { try store.save(records[index]) } catch { self.error = LocalizedText(error: error) }
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
                    let decoder = MediaDecoder()
                    var recordID: UUID?
                    do {
                        status = LocalizedText(verbatim: queue[index].url.lastPathComponent)
                        let duration = try await decoder.open(queue[index].url)
                        if configuration.speechProvider == .nemotron { await nemotron.beginStream() }
                        let id = try createRecord(source: .file, file: queue[index].url, configuration: configuration)
                        recordID = id; queue[index].recordID = id
                        while let chunk = try await decoder.next() {
                            try await process(chunk, recordID: id, configuration: configuration, keys: keys)
                            queue[index].progress = duration > 0 ? min(0.99, (chunk.start + chunk.duration) / duration) : 0
                        }
                        try Task.checkCancellation()
                        try await finishRecord(id, configuration: configuration, textKey: keys.textKey, summaryLanguage: summaryLanguage)
                        queue[index].status = .completed; queue[index].progress = 1
                    } catch is CancellationError {
                        queue[index].status = .cancelled
                        if let recordID { finishInterrupted(recordID) }
                    } catch {
                        queue[index].status = .failed; queue[index].error = LocalizedText(error: error)
                        if let recordID { failRecord(recordID, error: error) }
                    }
                    await decoder.cancel()
                }
            } catch is CancellationError { /* Nothing was captured. */ }
            catch { self.error = LocalizedText(error: error) }
            await whisper.unload()
            await nemotron.unload()
            phase = .idle; queueRunning = false; work = nil; status = LocalizedText("Ready")
            endActivity()
        }
    }

    func renameRecord(_ id: UUID, title: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var copy = records[index]; copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try store.save(copy); records[index] = copy } catch { self.error = LocalizedText(error: error) }
    }
    func deleteRecord(_ id: UUID) {
        do {
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
        work = Task {
            defer { isPostProcessing = false; postProcessingID = nil; work = nil; status = LocalizedText("Ready") }
            do {
                let key = try KeychainStore.read(endpoint: configuration.textEndpoint)
                if summary {
                    let result = try await api.summarize(record.fullText, language: summaryLanguage, settings: configuration, key: key)
                    try Task.checkCancellation()
                    if let index = records.firstIndex(where: { $0.id == record.id }) {
                        records[index].summary = result.summary
                        records[index].summaryLanguage = summaryLanguage
                        if let title = result.title, !title.isEmpty { records[index].title = title }
                        records[index].error = nil
                        try store.save(records[index])
                    }
                } else {
                    // Replace a translation as one saved result, so failures never mix languages.
                    var updated = record
                    for (line, segment) in record.segments.enumerated() {
                        try Task.checkCancellation()
                        status = LocalizedText("Translating %@/%@", String(line + 1), String(record.segments.count))
                        let context = record.segments.prefix(line).suffix(3).map(\.text).joined(separator: "\n")
                        let translation = try await api.translate(segment.text, sourceLanguage: record.language, context: context, settings: configuration, key: key)
                        try Task.checkCancellation()
                        updated.segments[line].translation = translation
                        updated.segments[line].translationError = nil
                    }
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
