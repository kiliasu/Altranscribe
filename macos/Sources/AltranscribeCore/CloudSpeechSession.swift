import Foundation

/// One recording across socket lifetimes. Each frame goes to exactly one connection;
/// retiring connections only drain. No automatic replay of paid inference requests.
public actor CloudSpeechSession {
    private final class Connection {
        let id = UUID(), socket: URLSessionWebSocketTask
        let created = ContinuousClock.now
        var state: CloudSpeechState
        var delivering = 0
        var sending = false, activityOpen = false
        var reader: Task<Void, Never>?, ping: Task<Void, Never>?
        init(socket: URLSessionWebSocketTask, settings: AppSettings) {
            self.socket = socket
            state = CloudSpeechState(provider: settings.speechProvider, direct: settings.usesDirectSpeechTranslation)
        }
        func close() { reader?.cancel(); ping?.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
    }

    private let settings: AppSettings, key: String
    private let session: URLSession
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

    public init(settings: AppSettings, key: String,
                renewAfter: Duration? = nil, renewBy: Duration? = nil, drainTimeout: Duration = .seconds(20),
                onUpdate: @escaping @Sendable (CloudSpeechUpdate) async throws -> Void,
                onFailure: @escaping @Sendable (AppError) -> Void = { _ in }) {
        self.settings = settings; self.key = key; self.onUpdate = onUpdate; self.onFailure = onFailure
        self.renewAfter = renewAfter ?? .seconds(settings.speechProvider == .gemini ? 540 : 3300)
        self.renewBy = renewBy ?? .seconds(settings.speechProvider == .gemini ? 570 : 3330)
        self.drainTimeout = drainTimeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func start() async throws {
        guard settings.usesCloudLive, !key.isEmpty else { throw AppError("Save an API key for the speech service.") }
        do {
            let id = try await connect()
            try check()
            active = id; scheduleRenewal()
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
        let socket = session.webSocketTask(with: request)
        let connection = Connection(socket: socket, settings: settings), id = connection.id
        connections[id] = connection
        if active != nil { candidate = id }
        socket.resume()
        connection.reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    await self?.receive(data, from: id)
                }
            } catch { await self?.disconnected(id) }
        }
        do {
            try await send(setup, to: id)
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !connection.state.ready {
                try check()
                guard ContinuousClock.now < deadline else { throw AppError("The cloud speech connection did not become ready.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            connection.ping = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(15))
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            socket.sendPing { error in
                                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                            }
                        }
                    }
                } catch { if !Task.isCancelled { await self?.disconnected(id) } }
            }
            return id
        } catch { connection.close(); connections.removeValue(forKey: id); throw error }
    }

    public func accept(_ chunk: AudioChunk) async throws {
        try check()
        guard !stopping, let id = active, let connection = connections[id], !chunk.samples.isEmpty else { return }
        connection.sending = true
        defer { connection.sending = false }
        connection.state.accept(chunk)
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
        if settings.speechProvider == .compatible && !settings.usesDirectSpeechTranslation &&
            (connection.state.windowDuration >= 20 || (connection.state.windowHasVoice && connection.state.quiet >= 0.6)) {
            try await commit(id)
        } else if settings.speechProvider == .gemini && !settings.usesDirectSpeechTranslation &&
                    connection.state.windowHasVoice && connection.state.quiet >= 0.6 {
            try await endActivity(id)
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
        if let error = connection.state.failure { fail(error); throw error }
    }

    private func endActivity(_ id: UUID) async throws {
        guard let connection = connections[id], connection.activityOpen else { return }
        connection.activityOpen = false
        connection.state.endActivity()
        try await send(["realtimeInput": ["activityEnd": [String: String]()]], to: id)
        guard connection.state.pending <= 8 else { throw AppError("Cloud transcription could not keep up. The received text was retained.") }
    }

    private func send(_ event: [String: Any], to id: UUID) async throws {
        try check()
        guard let connection = connections[id] else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: event)
        do { try await connection.socket.send(.string(String(decoding: data, as: UTF8.self))) }
        catch {
            if Task.isCancelled || cancelled { throw CancellationError() }
            throw AppError("The cloud speech connection was lost. The received text was retained.")
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
            if let error = connection.state.failure { fail(error); return }
            if id == active || retiring[id] != nil {
                for update in updates { try await onUpdate(update) }
            }
            if let remaining = connection.state.expiringIn, !stopping, retiring[id] == nil {
                connection.state.expiringIn = nil
                guard id == active, remaining > Double(drainTimeout.components.seconds) + 19 else {
                    throw AppError("The cloud speech session could not be renewed before expiry. The received text was retained.")
                }
                requestRenewal(deadline: .now.advanced(by: .seconds(remaining) - drainTimeout - .seconds(4)))
            }
        } catch is CancellationError { }
        catch { fail(error as? AppError ?? AppError("The API returned an invalid response.")) }
    }

    private func disconnected(_ id: UUID) {
        guard !cancelled, let connection = connections[id] else { return }
        if connection.state.closed || (connection.state.finishing && connection.state.generationComplete) { return }
        let status = (connection.socket.response as? HTTPURLResponse)?.statusCode
        if status == 429 { fail(AppError("HTTP %@. Rate limit or quota exceeded.", "429")) }
        else if status == 401 || status == 403 { fail(AppError("HTTP %@. Check the API key and model access.", String(status!))) }
        else { fail(AppError("The cloud speech connection was lost. The received text was retained.")) }
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
            guard retiring.isEmpty else { throw AppError("The cloud speech session could not be renewed before expiry. The received text was retained.") }
            let next = try await connect()
            while !stopping, let active, let previous = connections[active],
                  previous.sending || (!previous.state.quietBoundary && ContinuousClock.now < (renewalDeadline ?? .now)) {
                if previous.sending && ContinuousClock.now >= (renewalDeadline ?? .now) {
                    throw AppError("The cloud speech session could not be renewed before expiry. The received text was retained.")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check()
            guard !stopping, let previous = active else { close(next); return }
            active = next; candidate = nil; renewalCount += 1
            retiring[previous] = Task { try await drain(previous) }
            scheduleRenewal()
            Task { [weak self] in await self?.finishRetiring(previous) }
        } catch is CancellationError { }
        catch { fail(error as? AppError ?? AppError("The cloud speech session could not be renewed before expiry. The received text was retained.")) }
    }

    private func finishRetiring(_ id: UUID) async {
        guard let task = retiring[id] else { return }
        do { let confirmed = try await task.value; allConfirmed = allConfirmed && confirmed }
        catch is CancellationError { }
        catch { fail(error as? AppError ?? AppError("Cloud speech ended before all audio was confirmed. The received text was retained.")) }
        retiring.removeValue(forKey: id)
    }

    public func finish() async throws -> Bool {
        stopping = true; renewTimer?.cancel(); replacement?.cancel()
        if let candidate { close(candidate); self.candidate = nil }
        defer { cancel() }
        try check()
        if let active { let confirmed = try await drain(active); allConfirmed = allConfirmed && confirmed }
        for task in retiring.values { let confirmed = try await task.value; allConfirmed = allConfirmed && confirmed }
        try check()
        return allConfirmed
    }

    private func drain(_ id: UUID) async throws -> Bool {
        guard let connection = connections[id] else { throw CancellationError() }
        connection.state.finishing = true; connection.state.generationComplete = false
        defer { close(id) }
        if settings.speechProvider == .gemini && connection.state.first != nil {
            // Both Gemini speech pipelines need paced trailing silence to release buffered final words.
            for _ in 0..<30 {
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
            let state = connection.state
            if connection.delivering > 0 {
                // The final event is not saved until the consumer finishes its update.
            } else if settings.speechProvider == .compatible {
                if settings.usesDirectSpeechTranslation ? state.closed : (state.pending == 0 && state.commits.isEmpty) { return true }
            } else if settings.usesDirectSpeechTranslation {
                let quietFrom = max(ended, state.lastText)
                let hasText = !state.hasVoice || (!(state.lines["stream"]?.text.isEmpty ?? true) && !(state.lines["stream"]?.translation?.isEmpty ?? true))
                if hasText && quietFrom.duration(to: .now) >= .seconds(2) {
                    for key in connection.state.lines.keys.sorted() {
                        try await onUpdate(connection.state.emit(key, finalized: true, range: (state.first ?? 0, state.end)))
                    }
                    return state.generationComplete
                }
            } else if !state.awaitingOutput && state.pending == 0 {
                if !state.mayOweText || max(ended, state.lastText).duration(to: .now) >= .seconds(3) { return true }
            }
            guard ContinuousClock.now < deadline else {
                throw AppError("Cloud speech ended before all audio was confirmed. The received text was retained.")
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
