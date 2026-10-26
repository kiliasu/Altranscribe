import XCTest
@testable import AltranscribeCore

/// A scripted Live API endpoint. It answers setup, activity ends and audio the way the real
/// services do, with knobs for the failures a long recording must survive. No network is used.
private final class FakeSpeechServer: @unchecked Sendable {
    struct Options {
        /// 1-based connection indexes whose handshake drops instead of completing.
        var failConnections: Set<Int> = []
        /// Connections that never answer an activity end.
        var silentConnections: Set<Int> = []
        /// Activities (1-based per connection) the service hears as noise: like the real service, it sends
        /// no event at all for them, not even a completion.
        var noiseTurns: Set<Int> = []
        var allNoise = false
        /// Connections that receive a GoAway with this timeLeft once their first audio frame arrives.
        var goAwayAfterAudio: [Int: String] = [:]
    }
    private let lock = NSLock()
    private let options: Options
    private var sockets: [FakeSocket] = []
    init(_ options: Options = Options()) { self.options = options }

    var factory: CloudSpeechSocketFactory { { [self] _ in self.open() as any CloudSpeechSocket } }
    var connectionCount: Int { lock.withLock { sockets.count } }
    func socket(_ index: Int) -> FakeSocket { lock.withLock { sockets[index - 1] } }

    private func open() -> FakeSocket {
        lock.withLock {
            let socket = FakeSocket(index: sockets.count + 1, server: self)
            sockets.append(socket)
            return socket
        }
    }

    func handle(_ event: [String: Any], from socket: FakeSocket) {
        if event["setup"] != nil {
            if options.failConnections.contains(socket.index) { socket.drop(); return }
            socket.push(["setupComplete": [String: String]()])
            return
        }
        guard let input = event["realtimeInput"] as? [String: Any] else { return }
        if input["audio"] != nil, let timeLeft = options.goAwayAfterAudio[socket.index], socket.markGoAwaySent() {
            socket.push(["goAway": ["timeLeft": timeLeft]])
        }
        if input["activityEnd"] != nil {
            guard !options.silentConnections.contains(socket.index) else { return }
            let turn = socket.nextTurn()
            guard !options.allNoise, !options.noiseTurns.contains(turn) else { return }
            socket.push(["serverContent": ["interimInputTranscription": ["text": "turn \(turn)"]]])
            socket.push(["serverContent": ["inputTranscription": ["text": "turn \(turn) on \(socket.index)"]]])
            socket.push(["serverContent": ["generationComplete": true]])
        }
    }
}

private final class FakeSocket: CloudSpeechSocket, @unchecked Sendable {
    let index: Int
    private weak var server: FakeSpeechServer?
    private let lock = NSLock()
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private var closed: Error?
    private var turns = 0, goAwaySent = false
    private var sent: [[String: Any]] = []
    var httpStatus: Int? { nil }

    init(index: Int, server: FakeSpeechServer) { self.index = index; self.server = server }
    func resume() {}
    func send(_ text: String) async throws {
        if let closed = lock.withLock({ self.closed }) { throw closed }
        let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        lock.withLock { sent.append(event) }
        server?.handle(event, from: self)
    }
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let data = queue.removeFirst(); lock.unlock(); continuation.resume(returning: data)
            } else if let closed {
                lock.unlock(); continuation.resume(throwing: closed)
            } else { waiter = continuation; lock.unlock() }
        }
    }
    func ping() async throws {}
    func cancel() { close(with: CancellationError()) }
    /// The server dropped the connection.
    func drop() { close(with: URLError(.networkConnectionLost)) }

    func push(_ event: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: event)
        lock.lock()
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: data) }
        else { queue.append(data); lock.unlock() }
    }
    func nextTurn() -> Int { lock.withLock { () -> Int in turns += 1; return turns } }
    func markGoAwaySent() -> Bool {
        lock.withLock { () -> Bool in
            if goAwaySent { return false }
            goAwaySent = true; return true
        }
    }
    func count(_ key: String) -> Int {
        lock.withLock { sent.filter { ($0["realtimeInput"] as? [String: Any])?[key] != nil }.count }
    }
    private func close(with error: Error) {
        lock.lock(); closed = error; let waiter = self.waiter; self.waiter = nil; lock.unlock()
        waiter?.resume(throwing: error)
    }
}

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [UUID: TranscriptSegment] = [:]
    private var failures: [AppError] = []
    func accept(_ update: CloudSpeechUpdate) { lock.withLock { lines[update.segment.id] = update.segment } }
    func fail(_ error: AppError) { lock.withLock { failures.append(error) } }
    var text: String { lock.withLock { lines.values.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ") } }
    var failureCount: Int { lock.withLock { failures.count } }
}

final class CloudSessionTests: XCTestCase {
    private func gemini() -> AppSettings {
        var settings = AppSettings(); settings.speechProvider = .gemini; settings.sourceLanguage = "en"
        return settings
    }
    private func session(_ server: FakeSpeechServer, capture: Capture,
                         renewAfter: Duration = .seconds(600), renewBy: Duration = .seconds(630),
                         drainTimeout: Duration = .seconds(5)) -> CloudSpeechSession {
        var tuning = CloudSpeechTuning()
        tuning.trailingSilenceFrames = 1; tuning.settle = .milliseconds(200); tuning.noiseSettle = .milliseconds(200)
        tuning.directSettle = .milliseconds(200); tuning.directSegmentGap = .milliseconds(50)
        return CloudSpeechSession(settings: gemini(), key: "test-key", renewAfter: renewAfter, renewBy: renewBy,
                                  drainTimeout: drainTimeout, tuning: tuning, session: nil, makeSocket: server.factory,
                                  onUpdate: { capture.accept($0) }, onFailure: { capture.fail($0) })
    }
    /// Feeds 100 ms frames of flat tone (above the local voice gate) or silence, as the capture pipeline does.
    @discardableResult
    private func feed(_ speech: CloudSpeechSession, seconds: Double, voice: Bool, from start: Double) async throws -> Double {
        var at = start
        for _ in 0..<Int((seconds * 10).rounded()) {
            try await speech.accept(AudioChunk(samples: Array(repeating: voice ? 0.1 : 0, count: 1600), start: at))
            at += 0.1
        }
        return at
    }
    private func wait(for condition: @escaping @Sendable () async -> Bool, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail("The session did not reach the expected state in time") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testNoiseOnlyActivitiesAreNotCountedAgainstTheStop() {
        var state = CloudSpeechState(provider: .gemini, direct: false)
        let voice = AudioChunk(samples: Array(repeating: 0.1, count: 1600), start: 0)
        state.accept(voice); state.endActivity() // Noise: the service never answers this activity.
        XCTAssertEqual(state.pending, 0)
        XCTAssertTrue(state.awaitingOutput); XCTAssertFalse(state.turnHasText)
        state.accept(voice); state.endActivity() // Speech.
        _ = state.receive(["serverContent": ["interimInputTranscription": ["text": "hel"]]])
        XCTAssertTrue(state.turnHasText)
        _ = state.receive(["serverContent": ["inputTranscription": ["text": "hello"]]])
        _ = state.receive(["serverContent": ["generationComplete": true]])
        _ = state.receive(["serverContent": ["turnComplete": true]]) // The same turn's second signal.
        XCTAssertFalse(state.awaitingOutput); XCTAssertFalse(state.turnHasText)
        XCTAssertEqual(state.pending, 0)
    }

    func testNoiseOnlyTurnsStillLetTheStopConfirm() async throws {
        let server = FakeSpeechServer(.init(allNoise: true)), capture = Capture()
        let speech = session(server, capture: capture, drainTimeout: .seconds(3))
        try await speech.start()
        var at = 0.0
        for _ in 0..<3 {
            at = try await feed(speech, seconds: 1, voice: true, from: at)
            at = try await feed(speech, seconds: 0.7, voice: false, from: at)
        }
        XCTAssertEqual(server.socket(1).count("activityEnd"), 3)
        let began = ContinuousClock.now
        let confirmed = try await speech.finish()
        XCTAssertTrue(confirmed)
        XCTAssertLessThan(began.duration(to: .now), .seconds(2), "Stop must not run into the drain timeout after noise-only turns")
        XCTAssertEqual(capture.failureCount, 0)
    }

    func testSpeechAroundNoiseTurnsConfirmsWithItsOwnCompletion() async throws {
        // The first and the last spoken activity are noise the service never answers, as is the
        // silence-only activity the stop closes; only the speech between them is answered.
        let server = FakeSpeechServer(.init(noiseTurns: [1, 3, 4])), capture = Capture()
        let speech = session(server, capture: capture, drainTimeout: .seconds(3))
        try await speech.start()
        var at = 0.0
        for _ in 0..<3 {
            at = try await feed(speech, seconds: 1, voice: true, from: at)
            at = try await feed(speech, seconds: 0.7, voice: false, from: at)
        }
        let began = ContinuousClock.now
        let confirmed = try await speech.finish()
        XCTAssertTrue(confirmed)
        XCTAssertLessThan(began.duration(to: .now), .seconds(2))
        XCTAssertEqual(capture.text, "turn 2 on 1")
        XCTAssertEqual(capture.failureCount, 0)
    }

    func testContinuousSoundEndsActivitiesAtTheCap() async throws {
        let server = FakeSpeechServer(), capture = Capture()
        let speech = session(server, capture: capture)
        try await speech.start()
        try await feed(speech, seconds: 65, voice: true, from: 0)
        XCTAssertEqual(server.socket(1).count("activityEnd"), 2, "Continuous sound must still produce final text every 30 seconds")
        XCTAssertTrue(capture.text.contains("turn 2 on 1"), capture.text)
        await speech.cancel()
    }

    func testGoAwayWithLittleTimeLeftSwitchesToTheReplacement() async throws {
        // Production budget: a 30-second notice against the default 20-second drain window.
        let server = FakeSpeechServer(.init(goAwayAfterAudio: [1: "30s"])), capture = Capture()
        let speech = session(server, capture: capture, drainTimeout: .seconds(20))
        try await speech.start()
        var at = try await feed(speech, seconds: 0.5, voice: true, from: 0)
        at = try await feed(speech, seconds: 0.7, voice: false, from: at)
        try await wait(for: { await speech.renewalCount == 1 })
        at = try await feed(speech, seconds: 1, voice: true, from: at)
        _ = try await feed(speech, seconds: 0.7, voice: false, from: at)
        let confirmed = try await speech.finish()
        XCTAssertTrue(confirmed)
        XCTAssertEqual(server.connectionCount, 2)
        XCTAssertEqual(capture.failureCount, 0, "A short GoAway budget must switch, not end the recording")
        XCTAssertTrue(capture.text.contains("on 1") && capture.text.contains("on 2"), capture.text)
    }

    func testRenewalRetriesAfterAFailedReplacementHandshake() async throws {
        let server = FakeSpeechServer(.init(failConnections: [2])), capture = Capture()
        let speech = session(server, capture: capture, renewAfter: .milliseconds(300), renewBy: .seconds(8))
        try await speech.start()
        var at = try await feed(speech, seconds: 0.5, voice: true, from: 0)
        at = try await feed(speech, seconds: 0.7, voice: false, from: at)
        try await wait(for: { await speech.renewalCount == 1 }, timeout: .seconds(6))
        XCTAssertEqual(server.connectionCount, 3, "A dropped replacement is retried while the old connection has time left")
        at = try await feed(speech, seconds: 1, voice: true, from: at)
        _ = try await feed(speech, seconds: 0.7, voice: false, from: at)
        let confirmed = try await speech.finish()
        XCTAssertTrue(confirmed)
        XCTAssertEqual(capture.failureCount, 0)
        XCTAssertTrue(capture.text.contains("on 3"), capture.text)
    }

    func testARetiringConnectionThatDiesLeavesANoteInsteadOfStopping() async throws {
        let server = FakeSpeechServer(.init(silentConnections: [1])), capture = Capture()
        let speech = session(server, capture: capture, renewAfter: .milliseconds(300), renewBy: .seconds(8), drainTimeout: .seconds(3))
        try await speech.start()
        var at = try await feed(speech, seconds: 0.8, voice: true, from: 0)
        at = try await feed(speech, seconds: 0.7, voice: false, from: at)
        try await wait(for: { await speech.renewalCount == 1 }, timeout: .seconds(6))
        server.socket(1).drop()
        at = try await feed(speech, seconds: 1, voice: true, from: at)
        _ = try await feed(speech, seconds: 0.7, voice: false, from: at)
        let confirmed = try await speech.finish()
        let warning = await speech.warning
        XCTAssertFalse(confirmed)
        XCTAssertNotNil(warning)
        XCTAssertEqual(capture.failureCount, 0, "Losing a retiring connection must not stop the recording")
        XCTAssertTrue(capture.text.contains("on 2"), capture.text)
    }

    func testDirectTranslationStartsANewLineAfterAPause() async throws {
        var state = CloudSpeechState(provider: .gemini, direct: true)
        state.directSegmentGap = .milliseconds(50)
        state.accept(AudioChunk(samples: Array(repeating: 0.1, count: 1600), start: 0))
        let first = try XCTUnwrap(state.receive(["serverContent": ["inputTranscription": ["text": "Hello world"]]]).first)
        _ = state.receive(["serverContent": ["outputTranscription": ["text": "你好，世界"]]])
        try await Task.sleep(for: .milliseconds(100))
        // An unfinished sentence keeps growing on its line however long the pause.
        let same = try XCTUnwrap(state.receive(["serverContent": ["inputTranscription": ["text": ", friends."]]]).first)
        XCTAssertEqual(same.segment.id, first.segment.id)
        XCTAssertEqual(same.segment.text, "Hello world, friends.")
        try await Task.sleep(for: .milliseconds(100))
        state.accept(AudioChunk(samples: Array(repeating: 0.1, count: 1600), start: 1))
        let next = try XCTUnwrap(state.receive(["serverContent": ["inputTranscription": ["text": "Second sentence."]]]).first)
        XCTAssertNotEqual(next.segment.id, first.segment.id)
        XCTAssertEqual(next.segment.start, 1.1, accuracy: 0.001)
        XCTAssertEqual(next.segment.text, "Second sentence.")
        // Its translation joins the new line when it follows without a pause.
        let output = try XCTUnwrap(state.receive(["serverContent": ["outputTranscription": ["text": "第二句。"]]]).first)
        XCTAssertEqual(output.segment.id, next.segment.id)
        XCTAssertEqual(output.segment.translation, "第二句。")
        XCTAssertEqual(state.lines.count, 2)
    }
}
