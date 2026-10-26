import XCTest
@testable import Altranscribe
import AltranscribeCore

private final class WorkflowProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((WorkflowProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func reply(_ text: String, status: Int = 200) {
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": "stop"]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class ResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [WorkflowProtocol] = []
    func receive(_ request: WorkflowProtocol) { lock.withLock { requests.append(request) } }
    var count: Int { lock.withLock { requests.count } }
    func reply(_ text: String) { lock.withLock { requests.first }?.reply(text) }
}

@MainActor final class WorkflowTests: XCTestCase {
    override func setUp() async throws {
        // Settings pages read API keys; keep them away from the person's real Keychain items.
        KeychainStore.service = "app.altranscribe.mac.api.tests"
    }

    private func app(at root: URL) -> AppModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkflowProtocol.self]
        return AppModel(paths: AppPaths(root: root), api: APIClient(session: URLSession(configuration: config)))
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "The operation did not settle")
    }

    func testLiveTranslationKeepsUpAndPreservesLatePunctuation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); WorkflowProtocol.handler = nil }
        let app = app(at: root)
        var record = TranscriptRecord(title: "Live", source: .microphone, language: "en", speechModel: "nemotron-en-0.6b")
        record.targetLanguage = "zh"
        app.records = [record]; app.activeRecordID = record.id; try app.store.save(record)
        var settings = AppSettings()
        settings.sourceLanguage = "auto"; settings.targetLanguage = "zh"
        settings.translate = true; settings.textModel = "test-model"
        let gate = ResponseGate()
        WorkflowProtocol.handler = { gate.receive($0) }
        var line = TranscriptSegment(start: 0, end: 1, text: "Hello")
        let partial = TranscriptSegment(start: 2, end: 3, text: "Next sentence")
        let firstLine = line, configuration = settings
        let feed = Task {
            try await app.saveSegments([firstLine], recordID: record.id, configuration: configuration, textKey: "")
            try await app.saveSegments([], partial: partial, recordID: record.id, configuration: configuration, textKey: "")
        }
        try await waitUntil { gate.count == 1 }
        XCTAssertEqual(app.records.first?.segments.count, 2, "A slow translation must not block recognition of the next sentence")
        gate.reply("你好")
        try await feed.value
        try await waitUntil { app.records.first?.segments.first?.translation == "你好" }
        XCTAssertEqual(app.currentCaptionTranslation?.id, line.id, "Keep the latest completed translation visible while the next sentence is partial")

        line.text += "."
        WorkflowProtocol.handler = { $0.reply("failed", status: 503) }
        try await app.saveSegments([line], recordID: record.id, configuration: settings, textKey: "")
        XCTAssertEqual(app.records.first?.segments.first?.text, "Hello.")
        XCTAssertEqual(app.records.first?.segments.first?.translation, "你好", "Late punctuation must preserve an existing translation")
        // English Nemotron overrides an earlier Chinese source selection.
        settings.sourceLanguage = "zh"
        let next = TranscriptSegment(start: 4, end: 5, text: "Thank you")
        WorkflowProtocol.handler = { $0.reply("谢谢") }
        try await app.saveSegments([next], recordID: record.id, configuration: settings, textKey: "")
        try await waitUntil { app.records.first?.segments.last?.translation != nil }
        XCTAssertEqual(app.records.first?.segments.last?.translation, "谢谢", "Use the record's English source, not the stale Chinese setting")
        XCTAssertEqual(try app.store.load().records.first?.segments, app.records.first?.segments)

        let backlog = ResponseGate()
        WorkflowProtocol.handler = { backlog.receive($0) }
        try await app.saveSegments([TranscriptSegment(start: 6, end: 7, text: "Waiting")], recordID: record.id, configuration: settings, textKey: "")
        try await waitUntil { backlog.count == 1 }
        WorkflowProtocol.handler = { $0.reply("已翻译") }
        for i in 0..<10 {
            let segment = TranscriptSegment(start: Double(i + 8), end: Double(i + 9), text: "Retain original \(i)")
            try await app.saveSegments([segment], recordID: record.id, configuration: settings, textKey: "")
        }
        XCTAssertEqual(app.pendingTranslations, 9, "Keep a bounded backlog of eight waiting translations plus the active one")
        XCTAssertNotNil(app.records.first?.segments.last?.translationError)
        XCTAssertEqual(app.records.first?.segments.last?.text, "Retain original 9")
        let finishingSettings = settings
        let finish = Task { try await app.finishRecord(record.id, configuration: finishingSettings, textKey: "") }
        await Task.yield()
        XCTAssertEqual(app.records.first?.status, .inProgress, "Stop and Save must wait for pending translations")
        backlog.reply("等待")
        try await finish.value
        XCTAssertEqual(app.pendingTranslations, 0)
        XCTAssertEqual(app.records.first?.status, .completed)
        XCTAssertEqual(try app.store.load().records.first?.segments, app.records.first?.segments)
    }

    func testRetranslationIsAtomicAndUsesRecordedLanguage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); WorkflowProtocol.handler = nil }
        let app = app(at: root)
        var record = TranscriptRecord(title: "Saved", source: .file, language: "en", speechModel: "whisper")
        record.status = .completed; record.targetLanguage = "zh"
        var first = TranscriptSegment(start: 0, end: 1, text: "Hello")
        first.translation = "你好"
        var second = TranscriptSegment(start: 1, end: 2, text: "Goodbye")
        second.translation = "再见"
        record.segments = [first, second]
        app.records = [record]; try app.store.save(record)
        let saved = try app.store.load().records.first
        app.settings.sourceLanguage = "en"; app.settings.targetLanguage = "fr"; app.settings.textModel = "test-model"
        var requests = 0
        WorkflowProtocol.handler = { request in
            requests += 1
            request.reply("Bonjour", status: requests == 1 ? 200 : 503)
        }
        app.postProcess(record, summary: false)
        try await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertEqual(app.records.first?.segments, record.segments, "A failed replacement must retain all previous translations")
        XCTAssertEqual(app.records.first?.targetLanguage, "zh")
        XCTAssertEqual(try app.store.load().records.first, saved)

        app.error = nil
        app.settings.sourceLanguage = "fr"
        WorkflowProtocol.handler = { $0.reply("French translation") }
        app.postProcess(record, summary: false)
        try await waitUntil { !app.busy }
        XCTAssertNil(app.error)
        XCTAssertEqual(app.records.first?.segments.map(\.translation), ["French translation", "French translation"])
        XCTAssertEqual(app.records.first?.targetLanguage, "fr")
        XCTAssertEqual(try app.store.load().records.first?.segments, app.records.first?.segments)

        let translated = try XCTUnwrap(app.records.first)
        let cancelled = ResponseGate()
        WorkflowProtocol.handler = { cancelled.receive($0) }
        app.settings.targetLanguage = "de"
        app.postProcess(translated, summary: false)
        try await waitUntil { cancelled.count == 1 }
        app.cancel()
        try await waitUntil { !app.busy }
        XCTAssertNil(app.error)
        XCTAssertEqual(app.records.first, translated, "Cancelling must preserve the earlier translation")
        XCTAssertEqual(try app.store.load().records.first?.segments, translated.segments)
    }

    func testDirectSpeechUpdatesPersistWithoutCallingTextService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); WorkflowProtocol.handler = nil }
        let app = app(at: root)
        let record = TranscriptRecord(title: "Cloud", source: .system, language: "en", speechModel: "gpt-realtime-translate")
        app.records = [record]; app.activeRecordID = record.id
        var settings = AppSettings(); settings.speechProvider = .compatible; settings.translate = true
        WorkflowProtocol.handler = { _ in XCTFail("Direct translation must not require or call the text service") }
        var line = TranscriptSegment(start: 5, end: 6, text: "Hello", estimated: true)
        try await app.saveSegments([], partial: line, recordID: record.id, configuration: settings, textKey: "")
        line.translation = "你好"; line.text = "Hello."; line.start = 0; line.end = 7
        try await app.saveSegments([line], recordID: record.id, configuration: settings, textKey: "")
        XCTAssertEqual(app.records[0].segments, [line])
        let silent = TranscriptSegment(start: 8, end: 9, text: "")
        try await app.saveSegments([silent], recordID: record.id, configuration: settings, textKey: "")
        try await app.finishRecord(record.id, configuration: settings, textKey: "")
        XCTAssertEqual(app.records[0].segments, [line])
        XCTAssertEqual(app.pendingTranslations, 0)
        XCTAssertEqual(try app.store.load().records.first?.segments, [line])
    }

    func testInterimTextIsWrittenLazilyAndFinalTextImmediately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = app(at: root)
        let record = TranscriptRecord(title: "Live", source: .microphone, language: "en", speechModel: "gpt-live-transcribe")
        app.records = [record]; app.activeRecordID = record.id; try app.store.save(record)
        let settings = AppSettings()
        var line = TranscriptSegment(start: 0, end: 1, text: "Hel", estimated: true)
        try await app.saveSegments([], partial: line, recordID: record.id, configuration: settings, textKey: "")
        XCTAssertEqual(app.records[0].segments.map(\.text), ["Hel"])
        XCTAssertEqual(try app.store.load().records.first?.segments.count, 0, "Interim text is coalesced instead of rewriting the record on every delta")
        line.text = "Hello."
        try await app.saveSegments([line], recordID: record.id, configuration: settings, textKey: "")
        XCTAssertEqual(try app.store.load().records.first?.segments, [line], "Final text is written immediately")
        try await app.saveSegments([], partial: TranscriptSegment(start: 2, end: 3, text: "Nex", estimated: true), recordID: record.id, configuration: settings, textKey: "")
        try await waitUntil { (try? app.store.load().records.first?.segments.count) == 2 }
        XCTAssertEqual(try app.store.load().records.first?.segments.last?.text, "Nex", "A lone interim update still reaches the disk within about a second")
    }

    func testStartWaitsForTheModelsTheSessionNeeds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = app(at: root)
        app.settings.speechProvider = .compatible; app.settings.speechBaseURL = "https://api.openai.com/v1"
        XCTAssertTrue(app.canStart(live: true)); XCTAssertNil(app.modelIssue)
        app.settings.summarize = true; app.settings.textModel = ""
        XCTAssertFalse(app.canStart(live: true), "A summary needs a text model before the session starts")
        app.settings.summarize = false; app.settings.translate = true
        XCTAssertTrue(app.canStart(live: true), "Live direct translation needs only the speech service")
        XCTAssertFalse(app.canStart(live: false), "File translation needs the text model")
        app.settings.textModel = "gpt-6.1-sol"
        XCTAssertTrue(app.canStart(live: false))
        app.settings.speechProvider = .whisper; app.settings.modelPath = ""
        XCTAssertFalse(app.canStart(live: true))
        XCTAssertEqual(app.modelIssue?.rendered(language: .english), "No Whisper model is selected.")
        app.settings.modelPath = root.appendingPathComponent("missing.bin").path
        XCTAssertEqual(app.modelIssue?.rendered(language: .english), "The selected Whisper model file is missing.")
    }

    func testBrokenSettingsDoNotHideSavedTranscripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordStore(paths: AppPaths(root: root))
        let record = TranscriptRecord(title: "Retained", source: .file, language: "en", speechModel: "nemotron-en-0.6b")
        try store.save(record)
        let broken = Data("{broken settings".utf8)
        try broken.write(to: store.paths.settings)
        let app = app(at: root)
        XCTAssertEqual(app.records.first?.id, record.id)
        XCTAssertEqual(app.records.first?.status, .interrupted)
        XCTAssertNotNil(app.error)
        XCTAssertEqual(try Data(contentsOf: store.paths.settings), broken)
    }
}
