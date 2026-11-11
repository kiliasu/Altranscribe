import Foundation

public struct CloudSpeechUpdate: Sendable {
    public let segment: TranscriptSegment
    public let finalized: Bool
}

extension AppSettings {
    public var usesCloudLive: Bool {
        speechProvider == .gemini || (speechProvider == .compatible && URL(string: speechEndpoint)?.host?.lowercased() == "api.openai.com")
    }
    public var usesDirectSpeechTranslation: Bool { usesCloudLive && translate && (cloudDirectTranslation ?? true) }
    public var liveSpeechModel: String { Self.liveSpeechModel(provider: speechProvider, direct: usesDirectSpeechTranslation) }
    /// The fixed Realtime / Live API models. File transcription models are chosen separately.
    public static func liveSpeechModel(provider: SpeechProvider, direct: Bool) -> String {
        if provider == .gemini { return direct ? "gemini-3.5-live-translate-preview" : "gemini-3.5-transcribe-live" }
        return direct ? "gpt-realtime-translate" : "gpt-live-transcribe"
    }

    func cloudSetup() throws -> [String: Any] {
        let direct = usesDirectSpeechTranslation
        if speechProvider == .compatible {
            if direct {
                return ["type": "session.update", "session": ["audio": [
                    "input": ["transcription": ["model": "gpt-realtime-whisper"]],
                    "output": ["language": targetLanguage]]]]
            }
            guard vocabularyTerms.allSatisfy({ !$0.contains("<") && !$0.contains(">") }) else {
                throw AppError("Vocabulary hints for this model cannot contain < or >.")
            }
            var transcription: [String: Any] = ["model": liveSpeechModel]
            if sourceLanguage != "auto" { transcription["languages"] = [sourceLanguage] }
            if !vocabularyTerms.isEmpty { transcription["keywords"] = vocabularyTerms }
            return ["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": 24000], "transcription": transcription, "turn_detection": NSNull()]]]]
        }
        guard direct || vocabularyTerms.count <= 1000 else { throw AppError("Gemini accepts up to 1,000 vocabulary terms.") }
        var transcription: [String: Any] = ["languageCodes": sourceLanguage == "auto" ? [] : [geminiLanguage]]
        if !vocabularyTerms.isEmpty { transcription["customVocabulary"] = vocabularyTerms }
        var setup: [String: Any] = ["model": "models/\(liveSpeechModel)",
                                  "inputAudioTranscription": direct ? [:] : transcription]
        if direct {
            setup["generationConfig"] = ["responseModalities": ["AUDIO"], "translationConfig": [
                "targetLanguageCode": targetLanguage == "zh" ? "zh-Hans" : targetLanguage, "echoTargetLanguage": true]]
            // These fields belong at setup root (as in the official SDK), not generationConfig.
            setup["outputAudioTranscription"] = [String: String]()
        } else {
            setup["generationConfig"] = ["responseModalities": ["TEXT"]]
            // Automatic VAD can end a turn and then miss resumed speech. Explicit activity
            // boundaries keep subsequent audio in the transcription pipeline.
            setup["realtimeInputConfig"] = ["automaticActivityDetection": ["disabled": true]]
        }
        return ["setup": setup]
    }
}

/// Protocol state is separate from socket lifetime so final, interim and duplicate events
/// are reconciled exactly as in Flutter. All times are capture estimates, not word timings.
struct CloudSpeechState {
    /// Local quiet time that ends an OpenAI window or a Gemini activity.
    static let quietBoundarySeconds = 0.6
    /// OpenAI windows commit at least this often, so text keeps arriving while speech continues.
    static let maxWindowSeconds = 20.0
    /// Gemini finalizes an activity only when it ends; continuous sound must not keep one open for minutes.
    static let maxActivitySeconds = 30.0

    let provider: SpeechProvider
    let direct: Bool
    var directSegmentGap: Duration = .seconds(2)
    var ready = false, closed = false, finishing = false, generationComplete = false
    var failure: AppError?
    var expiringIn: Double?
    var first: Double?, end = 0.0, windowStart = 0.0, windowDuration = 0.0, quiet = 0.0
    var hasVoice = false, windowHasVoice = false, awaitingOutput = false, turnHasText = false
    var unansweredActivities = 0, pending = 0, sequence = 0
    var lastText = ContinuousClock.now, lastAudio = ContinuousClock.now
    var commits: [(Double, Double)] = []
    var ranges: [String: (Double, Double)] = [:]
    var lines: [String: TranscriptSegment] = [:]
    var completed: Set<String> = [], eventIDs: Set<String> = []

    var quietBoundary: Bool { quiet >= Self.quietBoundarySeconds || !hasVoice || lastAudio.duration(to: .now) >= .milliseconds(600) }
    var mayOweText: Bool { provider == .gemini && !direct && unansweredActivities > 0 }
    var windowShouldCommit: Bool { windowDuration >= Self.maxWindowSeconds || (windowHasVoice && quiet >= Self.quietBoundarySeconds) }
    var activityShouldEnd: Bool { windowHasVoice && (quiet >= Self.quietBoundarySeconds || windowDuration >= Self.maxActivitySeconds) }
    /// Direct translation has no turn events, so lines are cut where both streams paused after a sentence.
    var directKey: String { "stream:\(sequence)" }

    mutating func accept(_ chunk: AudioChunk) {
        if first == nil { first = chunk.start; windowStart = chunk.start }
        end = chunk.start + chunk.duration; lastAudio = .now
        let voice = !chunk.samples.isEmpty && sqrt(chunk.samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(chunk.samples.count)) >= 0.002
        if voice {
            if !windowHasVoice { unansweredActivities += 1 }
            hasVoice = true; windowHasVoice = true; awaitingOutput = true
        }
        quiet = voice ? 0 : quiet + chunk.duration
        windowDuration += chunk.duration
    }

    mutating func commit() {
        commits.append((windowStart, end)); pending += 1
        windowStart = end; windowDuration = 0; quiet = 0; windowHasVoice = false
        if pending > 8 { failure = AppError("Cloud transcription could not keep up. The received text was retained.") }
    }

    /// Silent activities need no response. Voice energy may be speech or noise; only a response can confirm it.
    mutating func endActivity() {
        windowHasVoice = false; windowDuration = 0
    }

    mutating func emit(_ key: String, text: String? = nil, translation: String? = nil,
                       finalized: Bool = false, range: (Double, Double)? = nil) -> CloudSpeechUpdate {
        let range = range ?? ranges[key] ?? (windowStart, end)
        var line = lines[key] ?? TranscriptSegment(start: range.0, end: range.1, text: "", estimated: true)
        line.start = range.0; line.end = max(range.0, range.1)
        if let text { line.text = text }
        if let translation { line.translation = translation }
        lines[key] = line
        return CloudSpeechUpdate(segment: line, finalized: finalized)
    }

    mutating func receive(_ event: [String: Any]) -> [CloudSpeechUpdate] {
        if let id = event["event_id"] as? String {
            guard eventIDs.insert(id).inserted else { return [] }
            if eventIDs.count > 4096 { eventIDs = [id] }
        }
        if event["type"] as? String == "error" || (event["error"] != nil && !(event["error"] is NSNull)) {
            let code = (event["error"] as? [String: Any])?["code"]
            let rateLimited = ["rate_limit_exceeded", "insufficient_quota", "429"].contains(String(describing: code ?? ""))
            failure = rateLimited ? AppError("HTTP %@. Rate limit or quota exceeded.", "429") : AppError("The cloud speech service rejected the request. Check the model, language and credentials.")
            return []
        }
        if event["type"] as? String == "session.updated" || event["setupComplete"] != nil { ready = true }
        if provider == .compatible {
            switch event["type"] as? String {
            case "input_audio_buffer.committed":
                guard let id = event["item_id"] as? String, !commits.isEmpty else { return invalid() }
                ranges[id] = commits.removeFirst()
                return lines[id] == nil ? [] : [emit(id, finalized: completed.contains(id))]
            case "conversation.item.input_audio_transcription.delta":
                guard let id = event["item_id"] as? String, let delta = event["delta"] as? String else { return invalid() }
                guard !completed.contains(id) else { return [] }
                return [emit(id, text: (lines[id]?.text ?? "") + delta, range: ranges[id] ?? commits.first ?? (windowStart, end))]
            case "conversation.item.input_audio_transcription.completed":
                guard let id = event["item_id"] as? String, let text = event["transcript"] as? String else { return invalid() }
                guard completed.insert(id).inserted else { return [] }
                pending = max(0, pending - 1)
                return [emit(id, text: text, finalized: true, range: ranges[id] ?? commits.first ?? (windowStart, end))]
            case "conversation.item.input_audio_transcription.failed":
                failure = AppError("The cloud speech service rejected the request. Check the model, language and credentials.")
            case "session.input_transcript.delta", "session.output_transcript.delta":
                guard let delta = event["delta"] as? String else { return invalid() }
                let input = event["type"] as? String == "session.input_transcript.delta"
                let key: String, range: (Double, Double)
                if let elapsed = event["elapsed_ms"] as? Double, elapsed.isFinite, elapsed >= 0 {
                    let bucket = Int(elapsed / 5000)
                    key = "window:\(bucket)"
                    let start = (first ?? 0) + Double(bucket * 5)
                    range = (start, max(start, min(end, start + 5)))
                } else { key = rolledDirectKey(); range = (windowStart, end) }
                lastText = .now
                return [emit(key, text: input ? (lines[key]?.text ?? "") + delta : nil,
                             translation: input ? nil : (lines[key]?.translation ?? "") + delta, range: range)]
            case "session.closed":
                closed = true
                return lines.keys.sorted().map { emit($0, finalized: true, range: (lines[$0]!.start, lines[$0]!.end)) }
            default: break
            }
            return []
        }
        if let away = event["goAway"] as? [String: Any], !finishing {
            let value = away["timeLeft"] as? String ?? ""
            expiringIn = value.hasSuffix("s") ? (Double(value.dropLast()) ?? 0) : 0
        }
        guard let content = event["serverContent"] as? [String: Any] else { return [] }
        let interim = (content["interimInputTranscription"] as? [String: Any])?["text"] as? String
        let input = (content["inputTranscription"] as? [String: Any])?["text"] as? String
        let output = (content["outputTranscription"] as? [String: Any])?["text"] as? String
        var updates: [CloudSpeechUpdate] = []
        if direct {
            if input != nil || output != nil {
                let key = rolledDirectKey()
                lastText = .now
                updates.append(emit(key, text: (lines[key]?.text ?? "") + (input ?? ""),
                                    translation: (lines[key]?.translation ?? "") + (output ?? ""), range: (windowStart, end)))
            }
        } else {
            if interim != nil || input != nil { turnHasText = true; lastText = .now }
            if let interim {
                if !interim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { awaitingOutput = true }
                updates.append(emit(String(sequence), text: interim)) // Interim text replaces, never appends.
            }
            if let input {
                updates.append(emit(String(sequence), text: input, finalized: true))
                sequence += 1; windowStart = end
            }
        }
        if content["generationComplete"] as? Bool == true || content["turnComplete"] as? Bool == true {
            awaitingOutput = false; generationComplete = true
            // A turn's text answers one activity; a second signal for the same turn does not.
            if turnHasText { unansweredActivities = max(0, unansweredActivities - 1) }
            turnHasText = false
        }
        if content["interrupted"] as? Bool == true { failure = AppError("Cloud speech ended before all audio was confirmed. The received text was retained.") }
        // modelTurn audio is deliberately ignored. This application never plays cloud output.
        return updates
    }

    /// Start a new direct translation line once both streams stayed quiet after a finished sentence,
    /// so captions and the record read sentence by sentence instead of as one growing paragraph.
    private mutating func rolledDirectKey() -> String {
        let key = directKey
        guard let line = lines[key], !(line.translation ?? "").isEmpty, Self.endsSentence(line.text),
              lastText.duration(to: .now) >= directSegmentGap else { return key }
        sequence += 1; windowStart = end
        return directKey
    }
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".。!！?？…".contains(last)
    }

    private mutating func invalid() -> [CloudSpeechUpdate] {
        failure = AppError("The API returned an invalid response."); return []
    }
}
