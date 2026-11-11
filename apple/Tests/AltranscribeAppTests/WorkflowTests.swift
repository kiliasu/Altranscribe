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
        replyJSON(["choices": [["message": ["content": text], "finish_reason": "stop"]]], status: status)
    }
    func replyJSON(_ object: [String: Any], status: Int = 200) {
        let data = try! JSONSerialization.data(withJSONObject: object)
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
    func reply(_ text: String, index: Int = 0) { lock.withLock { requests.indices.contains(index) ? requests[index] : nil }?.reply(text) }
    func replyEcho(index: Int) throws {
        let request = try XCTUnwrap(lock.withLock { requests.indices.contains(index) ? requests[index] : nil })
        var data = request.request.httpBody ?? Data()
        if let stream = request.request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        // The line to translate is in the message's <source> tag, after the lines that came before it.
        let message = try XCTUnwrap(messages.last?["content"])
        let line = try XCTUnwrap(message.components(separatedBy: "<source>\n").last?.components(separatedBy: "\n</source>").first)
        request.reply("Translated: " + line)
    }
    var last: WorkflowProtocol? { lock.withLock { requests.last } }
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
        app.phase = .recording // Captions follow a live session only while it is captured.
        XCTAssertEqual(app.currentCaptionTranslation?.id, line.id, "Keep the latest completed translation visible while the next sentence is partial")
        app.phase = .idle

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
        for i in 0..<10 {
            let segment = TranscriptSegment(start: Double(i + 8), end: Double(i + 9), text: "Retain original \(i)")
            try await app.saveSegments([segment], recordID: record.id, configuration: settings, textKey: "")
        }
        try await waitUntil { backlog.count == 2 }
        XCTAssertEqual(app.pendingTranslations, 10, "Keep two active translations and at most eight waiting")
        WorkflowProtocol.handler = { $0.reply("已翻译") }
        XCTAssertNotNil(app.records.first?.segments.last?.translationError)
        XCTAssertEqual(app.records.first?.segments.last?.text, "Retain original 9")
        let finishingSettings = settings
        let finish = Task { try await app.finishRecord(record.id, configuration: finishingSettings, textKey: "") }
        await Task.yield()
        XCTAssertEqual(app.records.first?.status, .inProgress, "Stop and Save must wait for pending translations")
        backlog.reply("先完成的第二句", index: 1)
        try await waitUntil { app.records.first?.segments.contains(where: { $0.translation == "先完成的第二句" }) == true }
        XCTAssertEqual(app.records.first?.status, .inProgress, "A later translation must arrive while the first is still pending")
        backlog.reply("等待")
        try await finish.value
        XCTAssertEqual(app.pendingTranslations, 0)
        XCTAssertEqual(app.records.first?.status, .completed)
        XCTAssertEqual(try app.store.load().records.first?.segments, app.records.first?.segments)
    }

    func testStreamingPartialTranslationRemainsProvisionalUntilFinal() async throws {
        for provider in SpeechProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); WorkflowProtocol.handler = nil }
        let app = app(at: root)
        let record = TranscriptRecord(title: "Draft", source: .microphone, language: "en", speechModel: "Apple SpeechTranscriber")
        app.records = [record]
        var settings = AppSettings(); settings.speechProvider = provider; settings.translate = true; settings.textModel = "test-model"
        settings.cloudDirectTranslation = false
        WorkflowProtocol.handler = { $0.reply("初步译文") }
        var line = TranscriptSegment(start: 0, end: 2, text: "This is an early phrase")
        try await app.saveSegments([], partial: line, recordID: record.id, configuration: settings, textKey: "")
        try await waitUntil { app.records[0].segments[0].translationIsProvisional == true }
        XCTAssertNil(try app.store.load().records.first?.segments.first?.translation, "Do not persist a draft as the final translation")
        WorkflowProtocol.handler = { $0.reply("完整译文") }
        line.text += " followed by the final words."
        try await app.saveSegments([line], recordID: record.id, configuration: settings, textKey: "")
        XCTAssertEqual(app.records[0].segments[0].translation, "初步译文", "Keep the provisional translation visible during revision")
        try await app.finishRecord(record.id, configuration: settings, textKey: "")
        XCTAssertEqual(app.records[0].segments[0].translation, "完整译文")
        XCTAssertNil(app.records[0].segments[0].translationIsProvisional)
        XCTAssertEqual(try app.store.load().records.first?.segments.first?.translation, "完整译文")
        if provider != .nemotron {
            let opening = TranscriptSegment(start: 8, end: 10, text: "The maximum number of.")
            let ending = TranscriptSegment(start: 10.2, end: 12, text: "packets in flight determines the window size.")
            try await app.saveSegments([opening], recordID: record.id, configuration: settings, textKey: "")
            try await app.saveSegments([], partial: ending, recordID: record.id, configuration: settings, textKey: "")
            XCTAssertEqual(app.records[0].segments.count, 2, "A batch or streaming boundary must not become an incomplete short sentence")
            XCTAssertEqual(app.records[0].segments.last?.text, "The maximum number of packets in flight determines the window size.")
            try await app.saveSegments([ending], recordID: record.id, configuration: settings, textKey: "")
            try await app.finishRecord(record.id, configuration: settings, textKey: "")
            XCTAssertEqual(app.records[0].segments.last?.translation, "完整译文")
            var correction = opening; correction.text = "The maximum permitted number of"
            try await app.saveSegments([correction], recordID: record.id, configuration: settings, textKey: "")
            try await app.finishRecord(record.id, configuration: settings, textKey: "")
            XCTAssertEqual(app.records[0].segments.count, 2)
            XCTAssertEqual(app.records[0].segments.last?.text, "The maximum permitted number of packets in flight determines the window size.")
            if provider == .compatible || provider == .gemini {
                settings.cloudDirectTranslation = true
                var direct = TranscriptSegment(start: 20, end: 21, text: "A direct sentence")
                direct.translation = "直译草稿"
                try await app.saveSegments([], partial: direct, recordID: record.id, configuration: settings, textKey: "")
                direct.text += "."; direct.translation = "直译定稿"
                try await app.saveSegments([direct], recordID: record.id, configuration: settings, textKey: "")
                XCTAssertNil(app.records[0].segments.last?.translationIsProvisional)
                XCTAssertEqual(try app.store.load().records.first?.segments.last?.translation, "直译定稿")
            }
        }
        }
    }

    func testRevisedLiveTextCannotReceiveAnOlderTranslation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); WorkflowProtocol.handler = nil }
        let app = app(at: root)
        let record = TranscriptRecord(title: "Revision", source: .microphone, language: "en", speechModel: "whisper")
        app.records = [record]
        var settings = AppSettings(); settings.translate = true; settings.textModel = "test-model"
        let gate = ResponseGate(); WorkflowProtocol.handler = { gate.receive($0) }
        var line = TranscriptSegment(start: 0, end: 2, text: "The rate is 1.5")
        try await app.saveSegments([line], recordID: record.id, configuration: settings, textKey: "")
        try await waitUntil { gate.count == 1 }
        line.text = "The rate is 15"
        try await app.saveSegments([line], recordID: record.id, configuration: settings, textKey: "")
        gate.reply("旧译文")
        try await waitUntil { gate.count == 2 }
        XCTAssertNil(app.records[0].segments[0].translation, "Stale text must never overwrite the correction")
        gate.reply("修正后的译文", index: 1)
        try await app.finishRecord(record.id, configuration: settings, textKey: "")
        XCTAssertEqual(app.records[0].segments[0].translation, "修正后的译文")
        for (before, after) in [("Set it to -10", "Set it to 10"), ("Use C++", "Use C"), ("It is now here", "It is nowhere")] {
            var revised = TranscriptSegment(start: 4, end: 6, text: before)
            WorkflowProtocol.handler = { $0.reply("原译文") }
            try await app.saveSegments([revised], recordID: record.id, configuration: settings, textKey: "")
            try await waitUntil { app.records[0].segments.last?.translation == "原译文" }
            WorkflowProtocol.handler = { $0.reply("更新后的译文") }
            revised.text = after
            try await app.saveSegments([revised], recordID: record.id, configuration: settings, textKey: "")
            try await app.finishRecord(record.id, configuration: settings, textKey: "")
            XCTAssertEqual(app.records[0].segments.last?.translation, "更新后的译文", "A meaningful symbol or word boundary change must invalidate the old translation")
            XCTAssertEqual(try app.store.load().records.first?.segments.last?.translation, "更新后的译文")
        }
    }

    func testRetranslationIsAtomicAndUsesRecordedLanguage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); WorkflowProtocol.handler = nil }
        let app = app(at: root)
        var record = TranscriptRecord(title: "Saved", source: .file, language: "en", speechModel: "whisper")
        let imported = root.appendingPathComponent("original.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: imported)
        record.sourcePath = imported.path
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

        // Remote file and history translation share four bounded lanes; replies may finish out of order.
        app.settings.textBaseURL = "https://translation.example/v1"
        try await KeychainStore.save("fixture", endpoint: app.settings.textEndpoint)
        defer { Task { try? await KeychainStore.save("", endpoint: "https://translation.example/v1") } }
        record.segments = (0..<6).map { TranscriptSegment(start: Double($0), end: Double($0 + 1), text: "Sentence \($0)") }
        record.segments[0].translationIsProvisional = true
        app.records = [record]; try app.store.save(record)
        let parallel = ResponseGate()
        WorkflowProtocol.handler = { parallel.receive($0) }
        app.postProcess(record, summary: false)
        try await waitUntil { parallel.count == 4 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(parallel.count, 4)
        for i in (0..<4).reversed() { try parallel.replyEcho(index: i) }
        try await waitUntil { parallel.count == 6 }
        for i in (4..<6).reversed() { try parallel.replyEcho(index: i) }
        try await waitUntil { !app.busy }
        XCTAssertNil(app.error)
        XCTAssertEqual(app.records[0].segments.map(\.translation), record.segments.map { "Translated: " + $0.text })
        XCTAssertEqual(try app.store.load().records.first?.segments, app.records[0].segments)
        let previous = app.records[0]
        let failed = ResponseGate(); WorkflowProtocol.handler = { failed.receive($0) }
        app.postProcess(previous, summary: false)
        try await waitUntil { failed.count == 4 }
        failed.last?.reply("limited", status: 429)
        try await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertEqual(app.records[0], previous)
        app.error = nil
        let cancelParallel = ResponseGate(); WorkflowProtocol.handler = { cancelParallel.receive($0) }
        app.postProcess(previous, summary: false)
        try await waitUntil { cancelParallel.count == 4 }
        app.cancel(); try await waitUntil { !app.busy }
        XCTAssertEqual(app.records[0], previous)
        XCTAssertEqual(cancelParallel.count, 4)
        let fileGate = ResponseGate(); WorkflowProtocol.handler = { fileGate.receive($0) }
        app.records = [record]
        app.settings.translate = true
        let configuration = app.settings, lines = record.segments
        app.records[0].segments = []
        let feed = Task { try await app.saveSegments(lines, recordID: record.id, configuration: configuration, textKey: "fixture") }
        try await waitUntil { fileGate.count == 4 }
        for i in (0..<4).reversed() { try fileGate.replyEcho(index: i) }
        try await waitUntil { fileGate.count == 6 }
        for i in (4..<6).reversed() { try fileGate.replyEcho(index: i) }
        try await feed.value
        XCTAssertEqual(app.records[0].segments.map(\.translation), lines.map { "Translated: " + $0.text })
        XCTAssertEqual(try app.store.load().records.first?.segments, app.records[0].segments)
        app.renameRecord(record.id, title: "New transcript title")
        XCTAssertEqual(try Data(contentsOf: imported), Data("source".utf8))
        XCTAssertEqual(app.records[0].sourcePath, imported.path)

        app.settings.textBaseURL = "http://127.0.0.1:11434/v1"
        var recorded = app.records[0]; recorded.source = .microphone; recorded.hasRecording = true
        recorded.recordingDirectory = root.appendingPathComponent("Audio").path
        recorded.recordingFilename = AppPaths.recordingFilename(for: recorded)
        let audio = app.paths.recording(recorded)
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("recording".utf8).write(to: audio)
        app.records = [recorded]; try app.store.save(recorded)
        WorkflowProtocol.handler = { $0.reply("{\"title\":\"Network lecture\",\"summary\":\"Notes\"}") }
        app.postProcess(recorded, summary: true)
        try await waitUntil { !app.busy }
        XCTAssertNil(app.error)
        XCTAssertEqual(app.records[0].title, "Network lecture")
        XCTAssertTrue(app.paths.recording(app.records[0]).lastPathComponent.hasPrefix("Network lecture · "))
        XCTAssertEqual(try Data(contentsOf: app.paths.recording(app.records[0])), Data("recording".utf8))
        var summarySettings = app.settings; summarySettings.summarize = true
        WorkflowProtocol.handler = { $0.reply("{\"title\":\"Final summary title\",\"summary\":\"Notes\"}") }
        try await app.finishRecord(record.id, configuration: summarySettings, textKey: "")
        XCTAssertTrue(app.paths.recording(app.records[0]).lastPathComponent.hasPrefix("Final summary title · "))
        XCTAssertEqual(try app.store.load().records.first?.recordingFilename, app.records[0].recordingFilename)
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

    func testCaptionsAreEmptyWhenIdleAndNeverShowFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = app(at: root)
        var live = TranscriptRecord(title: "Live", source: .microphone, language: "en", speechModel: "nemotron-en-0.6b")
        live.segments = [TranscriptSegment(start: 0, end: 1, text: "Last words of the session")]
        app.records = [live]; app.activeRecordID = live.id
        for phase: SessionPhase in [.recording, .paused, .finishing] {
            app.phase = phase
            XCTAssertEqual(app.currentCaption?.text, "Last words of the session", "\(phase)")
        }
        app.records[0].segments += (1...4).map { TranscriptSegment(start: Double($0), end: Double($0 + 1), text: "Sentence \($0)") }
        XCTAssertEqual(app.captionSegments.map(\.text), ["Sentence 2", "Sentence 3", "Sentence 4"])
        app.settings.captionSentenceCount = 1
        XCTAssertEqual(app.captionSegments.map(\.text), ["Sentence 4"])
        app.settings.captionSentenceCount = 8
        XCTAssertEqual(app.captionSegments.count, 5)
        app.phase = .idle
        XCTAssertTrue(app.captionSegments.isEmpty)
        XCTAssertNil(app.currentCaption, "An ended session must not linger in idle captions")
        var file = TranscriptRecord(title: "Lecture", source: .file, language: "en", speechModel: "whisper")
        file.segments = [TranscriptSegment(start: 0, end: 1, text: "File text")]
        app.records.append(file); app.activeRecordID = file.id
        for phase: SessionPhase in [.files, .finishing, .idle] {
            app.phase = phase
            XCTAssertNil(app.currentCaption, "File transcription never drives the captions (\(phase))")
        }
    }

    func testFileQueueReportsProgressStagesThenClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); WorkflowProtocol.handler = nil }
        let audio = root.appendingPathComponent("lecture.wav")
        try WaveEncoder.encode([Float](repeating: 0.05, count: 32_000)).write(to: audio)
        let app = app(at: root)
        // A loopback speech and text service needs no key; the protocol stub answers both.
        app.settings.speechProvider = .compatible; app.settings.speechBaseURL = "http://127.0.0.1:9/v1"
        app.settings.textBaseURL = "http://127.0.0.1:9/v1"; app.settings.textModel = "test-model"
        app.settings.translate = true; app.settings.targetLanguage = "zh"
        let gate = ResponseGate()
        WorkflowProtocol.handler = { gate.receive($0) }
        app.addFiles([audio])
        app.startQueue()

        try await waitUntil { gate.count == 1 }
        let run = try XCTUnwrap(app.fileRun)
        XCTAssertEqual(run.stage, .transcribing); XCTAssertEqual(run.fileName, "lecture.wav")
        XCTAssertEqual(run.duration, 2, accuracy: 0.05); XCTAssertEqual(run.processed, 0)
        XCTAssertEqual(app.queue.first?.recordID, run.recordID)
        XCTAssertNil(app.currentCaption, "A file being transcribed never drives the captions")
        XCTAssertTrue(gate.last?.request.url?.path.hasSuffix("audio/transcriptions") == true)
        gate.last?.replyJSON(["text": "A sentence from the file."])

        try await waitUntil { gate.count == 2 }
        XCTAssertEqual(app.fileRun?.stage, .translating, "Translating a finished chunk is its own stage")
        XCTAssertEqual(app.records.first?.segments.first?.text, "A sentence from the file.")
        gate.last?.reply("文件里的一句话。")

        try await waitUntil { !app.busy }
        XCTAssertNil(app.fileRun, "The progress clears when the queue stops")
        XCTAssertEqual(app.queue.first?.status, .completed)
        XCTAssertEqual(app.records.first?.segments.first?.translation, "文件里的一句话。")
    }

    func testInspectorListsInstalledModelsAndSwitchesInPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = app(at: root)
        try app.paths.prepare()
        for name in ["ggml-tiny.bin", "ggml-base.bin"] { try Data([0]).write(to: app.paths.models.appendingPathComponent(name)) }
        app.settings.speechProvider = .whisper; app.settings.modelPath = ""
        XCTAssertEqual(app.speechModelChoices.map(\.title), ["Tiny", "Base"], "Only downloaded models are offered in place")
        XCTAssertFalse(app.modelReady)
        let base = app.paths.models.appendingPathComponent("ggml-base.bin").path
        app.selectedSpeechModel = base
        XCTAssertEqual(app.settings.modelPath, base)
        XCTAssertTrue(app.modelReady); XCTAssertNil(app.modelIssue)
        let custom = root.appendingPathComponent("custom.bin")
        try Data([0]).write(to: custom)
        app.settings.modelPath = custom.path
        XCTAssertEqual(app.speechModelChoices.last?.id, custom.path, "A model chosen from disk stays selectable")
        app.settings.speechProvider = .nemotron
        XCTAssertTrue(app.speechModelChoices.isEmpty); XCTAssertNotNil(app.modelIssue)
        app.settings.speechProvider = .compatible; app.settings.speechModelOverride = "my-model"
        XCTAssertEqual(app.speechModelChoices.count, OpenAITranscriptionModel.allCases.count)
        app.selectedSpeechModel = "whisper-1"
        XCTAssertEqual(app.settings.effectiveSpeechModel, "whisper-1")
        XCTAssertNil(app.settings.speechModelOverride, "Choosing a listed model clears a custom name")
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
        app.settings.speechProvider = .compatible; app.settings.textProvider = .apple
        app.settings.cloudDirectTranslation = false
        XCTAssertEqual(app.canStart(live: true), NativeAppleText.availabilityIssue == nil)
        XCTAssertEqual(app.textIssue(live: false), NativeAppleText.availabilityIssue)
        app.settings.translate = false
        XCTAssertTrue(app.canStart(live: true), "Unavailable text intelligence must not block transcription by itself")
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
