import Foundation

/// The socket surface the session depends on. Production uses URLSession WebSockets; tests
/// script connections so renewal, draining and failure handling run without paid services.
protocol CloudSpeechSocket: AnyObject, Sendable {
    func resume()
    func send(_ text: String) async throws
    /// The next message, or nil for a frame type the session ignores.
    func receive() async throws -> Data?
    func ping() async throws
    func cancel()
    var httpStatus: Int? { get }
}

typealias CloudSpeechSocketFactory = @Sendable (URLRequest) -> any CloudSpeechSocket

final class URLSessionSpeechSocket: CloudSpeechSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    init(_ task: URLSessionWebSocketTask) { self.task = task }
    func resume() { task.resume() }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> Data? {
        switch try await task.receive() {
        case .data(let value): return value
        case .string(let value): return Data(value.utf8)
        @unknown default: return nil
        }
    }
    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func cancel() { task.cancel(with: .normalClosure, reason: nil) }
    var httpStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }
}

/// Timings that tests shorten. The defaults are the validated production values.
struct CloudSpeechTuning: Sendable {
    /// Paced trailing silence that releases Gemini's buffered final words before a stream ends.
    var trailingSilenceFrames = 30
    /// How long a direct translation drain waits after the last text before keeping the result.
    var directSettle: Duration = .seconds(2)
    /// Quiet time after which a direct translation line is finished and the next sentence starts a new one.
    var directSegmentGap: Duration = .seconds(2)
}

/// One recording across socket lifetimes. Each frame goes to exactly one connection;
/// retiring connections only drain. No automatic replay of paid inference requests.
public actor CloudSpeechSession {
    private final class Connection {
        let id = UUID(), socket: any CloudSpeechSocket
        let created = ContinuousClock.now
        var state: CloudSpeechState
        var delivering = 0
        var sending = false, activityOpen = false
        /// Set when the socket ended or the service rejected it. Fatal only for the live connection.
        var lost: AppError?
        var reader: Task<Void, Never>?, ping: Task<Void, Never>?
        init(socket: any CloudSpeechSocket, settings: AppSettings, tuning: CloudSpeechTuning) {
            self.socket = socket
            state = CloudSpeechState(provider: settings.speechProvider, direct: settings.usesDirectSpeechTranslation)
            state.directSegmentGap = tuning.directSegmentGap
        }
        func close() { reader?.cancel(); ping?.cancel(); socket.cancel() }
    }

    private static let renewalFailure = AppError("The cloud speech session could not be renewed before expiry. The received text was retained.")
    private static let connectionLost = AppError("The cloud speech connection was lost. The received text was retained.")

    private let settings: AppSettings, key: String
    private let session: URLSession?
    private let makeSocket: CloudSpeechSocketFactory
    private let tuning: CloudSpeechTuning
    private let onUpdate: @Sendable (CloudSpeechUpdate) async throws -> Void
    private let onFailure: @Sendable (AppError) -> Void
    private let renewAfter: Duration, renewBy: Duration, drainTimeout: Duration
    private var connections: [UUID: Connection] = [:]
    private var active: UUID?, candidate: UUID?
    private var retiring: [UUID: Task<Bool, Error>] = [:]
    private var renewTimer: Task<Void, Never>?, replacement: Task<Void, Never>?
    private var renewalDeadline: ContinuousClock.Instant?
    private var failure: AppError?
    private var stopping = false, cancelled = false, allConfirmed = true
    public private(set) var renewalCount = 0
    /// A renewed connection ended before confirming its final text. The recording continued on the new one.
    public private(set) var warning: AppError?

    public init(settings: AppSettings, key: String,
                renewAfter: Duration? = nil, renewBy: Duration? = nil, drainTimeout: Duration = .seconds(20),
                onUpdate: @escaping @Sendable (CloudSpeechUpdate) async throws -> Void,
                onFailure: @escaping @Sendable (AppError) -> Void = { _ in }) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        self.init(settings: settings, key: key, renewAfter: renewAfter, renewBy: renewBy, drainTimeout: drainTimeout,
                  tuning: CloudSpeechTuning(), session: session,
                  makeSocket: { URLSessionSpeechSocket(session.webSocketTask(with: $0)) },
                  onUpdate: onUpdate, onFailure: onFailure)
    }

    init(settings: AppSettings, key: String, renewAfter: Duration?, renewBy: Duration?, drainTimeout: Duration,
         tuning: CloudSpeechTuning, session: URLSession?, makeSocket: @escaping CloudSpeechSocketFactory,
         onUpdate: @escaping @Sendable (CloudSpeechUpdate) async throws -> Void,
         onFailure: @escaping @Sendable (AppError) -> Void) {
        self.settings = settings; self.key = key; self.onUpdate = onUpdate; self.onFailure = onFailure
        self.renewAfter = renewAfter ?? .seconds(settings.speechProvider == .gemini ? 540 : 3300)
        self.renewBy = renewBy ?? .seconds(settings.speechProvider == .gemini ? 570 : 3330)
        self.drainTimeout = drainTimeout; self.tuning = tuning
        self.session = session; self.makeSocket = makeSocket
    }
    deinit { session?.invalidateAndCancel() }

    public func start() async throws {
        guard settings.usesCloudLive, !key.isEmpty else { throw AppError("Save an API key for the speech service.") }
        do {
            let id = try await connect()
            try check()
            active = id; scheduleRenewal()
            handleExpiry(id) // A GoAway that arrived during setup.
        } catch { cancel(); throw error }
    }

    private func connect() async throws -> UUID {
        try check()
        let setup = try settings.cloudSetup()
        var request: URLRequest
        if settings.speechProvider == .gemini {
            request = URLRequest(url: URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!)
            // Google's native SDK uses a header; avoid credentials in CFNetwork diagnostic URLs.
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        } else {
            let endpoint = settings.usesDirectSpeechTranslation ?
                "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate" :
                "wss://api.openai.com/v1/realtime?intent=transcription"
            request = URLRequest(url: URL(string: endpoint)!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let socket = makeSocket(request)
        let connection = Connection(socket: socket, settings: settings, tuning: tuning), id = connection.id
        connections[id] = connection
        if active != nil { candidate = id }
        socket.resume()
        connection.reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let data = try await socket.receive() else { continue }
                    await self?.receive(data, from: id)
                }
            } catch { await self?.disconnected(id) }
        }
        do {
            try await send(setup, to: id)
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !connection.state.ready {
                try check()
                if let lost = connection.lost { throw lost }
                guard ContinuousClock.now < deadline else { throw AppError("The cloud speech connection did not become ready.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            connection.ping = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(15))
                        try await socket.ping()
                    }
                } catch { if !Task.isCancelled { await self?.disconnected(id) } }
            }
            return id
        } catch {
            connection.close(); connections.removeValue(forKey: id)
            if candidate == id { candidate = nil }
            throw error
        }
    }

    public func accept(_ chunk: AudioChunk) async throws {
        try check()
        guard !stopping, let id = active, let connection = connections[id], !chunk.samples.isEmpty else { return }
        connection.sending = true
        defer { connection.sending = false }
        connection.state.accept(chunk)
        do {
            if settings.speechProvider == .gemini && !settings.usesDirectSpeechTranslation && !connection.activityOpen {
                connection.activityOpen = true
                try await send(["realtimeInput": ["activityStart": [String: String]()]], to: id)
            }
            var samples = chunk.samples
            if settings.speechProvider == .compatible {
                // The capture stream is 16 kHz; OpenAI Realtime requires 24 kHz PCM16.
                samples = (0..<Int((Double(samples.count) * 1.5).rounded())).map { index in
                    let position = Double(index) / 1.5, lower = Int(position)
                    let left = chunk.samples[min(lower, chunk.samples.count - 1)]
                    let right = chunk.samples[min(lower + 1, chunk.samples.count - 1)]
                    return left + (right - left) * Float(position - Double(lower))
                }
            }
            try await sendAudio(Data(WaveEncoder.encode(samples).dropFirst(44)), to: id)
            if settings.speechProvider == .compatible && !settings.usesDirectSpeechTranslation && connection.state.windowShouldCommit {
                try await commit(id)
            } else if settings.speechProvider == .gemini && !settings.usesDirectSpeechTranslation && connection.state.activityShouldEnd {
                try await endActivity(id)
            }
        } catch is AppError where id != active {
            // The frame belonged to a connection that was retired while it was being sent; later
            // frames go to the new connection. Its drain may already have finished reporting a failure.
        }
        try check()
    }

    private func sendAudio(_ pcm: Data, to id: UUID) async throws {
        let event: [String: Any]
        if settings.speechProvider == .gemini {
            event = ["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]]
        } else {
            event = ["type": settings.usesDirectSpeechTranslation ? "session.input_audio_buffer.append" : "input_audio_buffer.append",
                     "audio": pcm.base64EncodedString()]
        }
        try await send(event, to: id)
    }

    private func commit(_ id: UUID) async throws {
        guard let connection = connections[id], connection.state.windowDuration > 0 else { return }
        let padding = Int(ceil((0.1 - connection.state.windowDuration) * 24000))
        if padding > 0 { try await sendAudio(Data(repeating: 0, count: padding * 2), to: id) }
        connection.state.commit()
        try await send(["type": "input_audio_buffer.commit"], to: id)
        if let error = connection.state.failure { reject(id, with: error); throw error }
    }

    private func endActivity(_ id: UUID) async throws {
        guard let connection = connections[id], connection.activityOpen else { return }
        connection.activityOpen = false
        connection.state.endActivity()
        try await send(["realtimeInput": ["activityEnd": [String: String]()]], to: id)
    }

    private func send(_ event: [String: Any], to id: UUID) async throws {
        try check()
        guard let connection = connections[id] else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: event)
        do { try await connection.socket.send(String(decoding: data, as: UTF8.self)) }
        catch {
            if Task.isCancelled || cancelled { throw CancellationError() }
            throw Self.connectionLost
        }
    }

    private func receive(_ data: Data, from id: UUID) async {
        guard !cancelled, let connection = connections[id] else { return }
        connection.delivering += 1
        defer { connection.delivering -= 1 }
        do {
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AppError("The API returned an invalid response.")
            }
            let updates = connection.state.receive(event)
            if let error = connection.state.failure { reject(id, with: error); return }
            if id == active || retiring[id] != nil {
                for update in updates { try await onUpdate(update) }
            }
            handleExpiry(id)
        } catch is CancellationError { }
        catch { reject(id, with: error as? AppError ?? AppError("The API returned an invalid response.")) }
    }

    /// A connection that ended or was rejected is fatal only while it carries the live audio.
    /// A retiring connection ends unconfirmed; a replacement that failed is reconnected by the renewal.
    private func reject(_ id: UUID, with error: AppError) {
        guard let connection = connections[id] else { return }
        connection.lost = error
        if id == active { fail(error) }
    }

    private func handleExpiry(_ id: UUID) {
        guard let connection = connections[id], let remaining = connection.state.expiringIn,
              !stopping, retiring[id] == nil, let active else { return }
        connection.state.expiringIn = nil
        if id == active {
            // Switch as soon as a replacement is ready while leaving the drain its budget. A late
            // notice still gets a best-effort switch instead of ending the recording outright.
            let budget = Duration.seconds(remaining) - drainTimeout - .seconds(4)
            requestRenewal(deadline: .now.advanced(by: max(budget, .zero)))
        } else {
            // A replacement that is already expiring must not go live; the renewal reconnects.
            connection.lost = Self.renewalFailure
        }
    }

    private func disconnected(_ id: UUID) {
        guard !cancelled, let connection = connections[id] else { return }
        if connection.state.closed || (connection.state.finishing && connection.state.generationComplete) { return }
        let status = connection.socket.httpStatus
        if status == 429 { reject(id, with: AppError("HTTP %@. Rate limit or quota exceeded.", "429")) }
        else if status == 401 || status == 403 { reject(id, with: AppError("HTTP %@. Check the API key and model access.", String(status!))) }
        else { reject(id, with: Self.connectionLost) }
    }

    private func scheduleRenewal() {
        renewTimer?.cancel(); renewalDeadline = nil
        guard !stopping, let active, let connection = connections[active] else { return }
        let prepareAt = connection.created.advanced(by: renewAfter)
        let switchBy = connection.created.advanced(by: renewBy)
        renewTimer = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: prepareAt)
                await self?.requestRenewal(deadline: switchBy)
            } catch { }
        }
    }

    private func requestRenewal(deadline: ContinuousClock.Instant) {
        guard !stopping, !cancelled, failure == nil else { return }
        renewalDeadline = min(renewalDeadline ?? deadline, deadline)
        guard replacement == nil else { return }
        replacement = Task { [weak self] in await self?.replaceConnection() }
    }

    private func replaceConnection() async {
        defer { replacement = nil }
        do {
            guard retiring.isEmpty else { throw Self.renewalFailure }
            var next = try await connectWithRetry()
            // Switch at a quiet boundary, or at the deadline whatever the audio is doing. A frame
            // still being sent stays with the old connection; later frames go to the new one.
            while true {
                try check()
                if stopping { close(next); return }
                if connections[next]?.lost != nil { close(next); next = try await connectWithRetry(); continue }
                guard let active, let previous = connections[active] else { close(next); return }
                if (!previous.sending && previous.state.quietBoundary) || ContinuousClock.now >= (renewalDeadline ?? .now) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let previous = active else { close(next); return }
            active = next; candidate = nil; renewalCount += 1
            retiring[previous] = Task { try await drain(previous) }
            scheduleRenewal()
            Task { [weak self] in await self?.finishRetiring(previous) }
        } catch is CancellationError { }
        catch { fail(error as? AppError ?? Self.renewalFailure) }
    }

    /// Opening the replacement is not a paid inference request, so a transient failure is retried
    /// while the old connection still has time left. Rejected credentials are not retried.
    private func connectWithRetry() async throws -> UUID {
        var attempt = 1
        while true {
            do { return try await connect() }
            catch let error as AppError where attempt < 3 && !error.message.key.hasPrefix("HTTP") &&
                    ContinuousClock.now.advanced(by: .seconds(2)) < (renewalDeadline ?? .now) {
                attempt += 1
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func finishRetiring(_ id: UUID) async {
        guard let task = retiring[id] else { return }
        do { let confirmed = try await task.value; allConfirmed = allConfirmed && confirmed }
        catch is CancellationError { }
        catch { unconfirmedRenewal() }
        retiring.removeValue(forKey: id)
    }

    /// The audio already moved to the new connection; the recording continues with a note.
    private func unconfirmedRenewal() {
        allConfirmed = false
        warning = AppError("A renewed cloud connection ended before its final text was confirmed. Review the text around that point.")
    }

    public func finish() async throws -> Bool {
        stopping = true; renewTimer?.cancel(); replacement?.cancel()
        if let candidate { close(candidate); self.candidate = nil }
        defer { cancel() }
        try check()
        if let active { let confirmed = try await drain(active); allConfirmed = allConfirmed && confirmed }
        for task in retiring.values {
            do { let confirmed = try await task.value; allConfirmed = allConfirmed && confirmed }
            catch is CancellationError { throw CancellationError() }
            catch { unconfirmedRenewal() }
        }
        try check()
        return allConfirmed
    }

    private func drain(_ id: UUID) async throws -> Bool {
        guard let connection = connections[id] else { throw CancellationError() }
        connection.state.finishing = true; connection.state.generationComplete = false
        defer { close(id) }
        let sendDeadline = ContinuousClock.now.advanced(by: drainTimeout)
        while connection.sending {
            try check()
            if let lost = connection.lost { throw lost }
            guard ContinuousClock.now < sendDeadline else { throw Self.connectionLost }
            try await Task.sleep(for: .milliseconds(20))
        }
        if settings.speechProvider == .gemini && connection.state.first != nil {
            // Both Gemini speech pipelines need paced trailing silence to release buffered final words.
            for _ in 0..<tuning.trailingSilenceFrames {
                try await sendAudio(Data(repeating: 0, count: 3200), to: id)
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        if settings.speechProvider == .compatible {
            if settings.usesDirectSpeechTranslation { try await send(["type": "session.close"], to: id) }
            else { try await commit(id) }
        } else if settings.usesDirectSpeechTranslation { try await send(["realtimeInput": ["audioStreamEnd": true]], to: id) }
        else { try await endActivity(id) }
        let ended = ContinuousClock.now, deadline = ended.advanced(by: drainTimeout)
        while true {
            try check()
            if let lost = connection.lost { throw lost }
            let state = connection.state
            if connection.delivering > 0 {
                // The final event is not saved until the consumer finishes its update.
            } else if settings.speechProvider == .compatible {
                if settings.usesDirectSpeechTranslation ? state.closed : (state.pending == 0 && state.commits.isEmpty) { return true }
            } else if settings.usesDirectSpeechTranslation {
                let line = state.lines[state.directKey]
                let hasText = !state.hasVoice || (!(line?.text.isEmpty ?? true) && !(line?.translation?.isEmpty ?? true))
                if hasText && max(ended, state.lastText).duration(to: .now) >= tuning.directSettle {
                    for key in connection.state.lines.keys.sorted() {
                        let range = (connection.state.lines[key]!.start, connection.state.lines[key]!.end)
                        try await onUpdate(connection.state.emit(key, finalized: true, range: range))
                    }
                    return state.generationComplete
                }
            } else if !state.awaitingOutput && !state.mayOweText {
                return true
            }
            guard ContinuousClock.now < deadline else {
                let incomplete = AppError("Cloud speech ended before all audio was confirmed. The received text was retained.")
                if settings.speechProvider == .gemini && !settings.usesDirectSpeechTranslation &&
                    !state.turnHasText && connection.delivering == 0 {
                    // No reply can mean noise or delayed speech. Keep listening for the entire drain
                    // budget, then retain the received text without claiming the service confirmed it.
                    warning = incomplete
                    return false
                }
                throw incomplete
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func check() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
    }
    private func fail(_ error: AppError) {
        guard failure == nil, !cancelled else { return }
        failure = error; renewTimer?.cancel(); replacement?.cancel(); onFailure(error)
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.close() }
    public func cancel() {
        cancelled = true; renewTimer?.cancel(); replacement?.cancel()
        for connection in connections.values { connection.close() }
        connections.removeAll()
        for task in retiring.values { task.cancel() }
        retiring.removeAll()
    }
}
