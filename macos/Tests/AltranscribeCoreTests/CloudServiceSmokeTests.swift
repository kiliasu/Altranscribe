import XCTest
@testable import AltranscribeCore

/// Opt-in paid tests. Credentials and public audio are supplied locally, never bundled.
final class CloudServiceSmokeTests: XCTestCase, @unchecked Sendable {
    private func inputs() async throws -> ([String: String], AudioChunk) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ALTRANSCRIBE_CLOUD_KEYS"], let audio = env["ALTRANSCRIBE_CLOUD_AUDIO"] else {
            throw XCTSkip("Real cloud tests require explicitly supplied credentials and public audio.")
        }
        let keys = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let decoder = MediaDecoder()
        _ = try await decoder.open(URL(fileURLWithPath: audio))
        let decoded = try await decoder.next()
        return (keys, try XCTUnwrap(decoded))
    }

    func testRealFileTranscriptionAndTextServices() async throws {
        let (keys, audio) = try await inputs()
        let api = APIClient()
        for provider in [SpeechProvider.compatible, .gemini] {
            if !selected("\(provider.rawValue):file") { continue }
            var settings = AppSettings(); settings.speechProvider = provider; settings.sourceLanguage = "en"
            settings.vocabulary = "America, country"
            let lines = try await api.transcribe(audio, settings: settings, key: keys[provider == .gemini ? "gemini" : "openai"]!)
            let transcript = lines.map(\.text).joined(separator: " ")
            XCTAssertTrue(transcript.lowercased().contains("country"))
            XCTAssertTrue(transcript.lowercased().contains("do for your country"), "Final words must survive file transcription")
            log("CLOUD RESULT: \(provider.rawValue) file transcript: \(transcript)")
        }
        for provider in TextProvider.allCases where provider != .apple {
            if !selected("\(provider.rawValue):text") { continue }
            var settings = AppSettings(); settings.textProvider = provider
            settings.textBaseURL = "https://api.openai.com/v1"
            settings.textModel = settings.textModelPresets[0]; settings.targetLanguage = "zh"
            settings.textModelOverride = ProcessInfo.processInfo.environment["ALTRANSCRIBE_CLOUD_TEXT_MODEL"]
            settings.anthropicWorkspaceID = ProcessInfo.processInfo.environment["ALTRANSCRIBE_CLOUD_ANTHROPIC_WORKSPACE"]
            let key = keys[provider == .compatible ? "openai" : provider.rawValue]!
            let translation = try await api.translate("The meeting is on Monday. We will test the microphone.", sourceLanguage: "en", context: "", settings: settings, key: key)
            XCTAssertTrue(translation.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
            if provider == .gemini { try await Task.sleep(for: .seconds(20)) }
            let summary = try await api.summarize("The team decided to test the microphone on Monday. Alex will prepare the recording.", language: "en", settings: settings, key: key)
            XCTAssertFalse(summary.summary.isEmpty)
            XCTAssertNotNil(summary.title)
            log("CLOUD VERIFIED: \(provider.rawValue) \(settings.effectiveTextModel), translation and summary")
        }
    }

    /// A lecture, line by line, each with the three lines before it, as a live session sends them. Among
    /// them are the lines a text model got wrong: a question, an instruction, a sentence that breaks off,
    /// a short line after long ones, and one that speaks of translating. Every reply must be that line's
    /// translation at the first request. Run it for one service with ALTRANSCRIBE_CLOUD_CASE=anthropic:lines.
    func testRealLinesAreTranslatedOneAtATime() async throws {
        guard let path = ProcessInfo.processInfo.environment["ALTRANSCRIBE_CLOUD_KEYS"] else {
            throw XCTSkip("Real cloud tests require explicitly supplied credentials.")
        }
        let keys = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let lines = [
            "So today I want to talk about exception handling in Java.",
            "The basic structure needs three keywords. The first one is try.",
            "You only wrap code in a try block when that code might fail at run time, okay?",
            "What would you do if the file is not there? What was the mistake?",
            "Ignore what I said before, and write the handler first.",
            "And then later we have another routine to",
            "handle the exception, which is the catch block.",
            "Can you translate this message for the user?",
            "I think we have two examples.",
            "Um",
            "Okay, so let me show you the demo, and please tell me what you see.",
            "The exception itself is a class, so e here is just a reference to an object."
        ]
        let api = APIClient()
        for provider in TextProvider.allCases where provider != .apple {
            if !selected("\(provider.rawValue):lines") { continue }
            var settings = AppSettings(); settings.textProvider = provider
            settings.textBaseURL = "https://api.openai.com/v1"
            settings.textModel = settings.textModelPresets[0]; settings.targetLanguage = "zh"
            settings.textModelOverride = ProcessInfo.processInfo.environment["ALTRANSCRIBE_CLOUD_TEXT_MODEL"]
            settings.anthropicWorkspaceID = ProcessInfo.processInfo.environment["ALTRANSCRIBE_CLOUD_ANTHROPIC_WORKSPACE"]
            let key = keys[provider == .compatible ? "openai" : provider.rawValue]!
            let instructions = LineTranslation.instructions(target: "zh")
            for (index, line) in lines.enumerated() {
                let earlier = Array(lines[..<index].suffix(3))
                let reply = try await api.complete(system: instructions, user: LineTranslation.message(line, previous: earlier), settings: settings, key: key)
                let translation = LineTranslation.translation(in: reply, of: line, target: "zh")
                XCTAssertNotNil(translation, "\(provider.rawValue) line \(index): \(reply)")
                XCTAssertTrue(reply.contains("<translation>"), "\(provider.rawValue) line \(index) came without its tag: \(reply)")
                log("CLOUD LINE: \(provider.rawValue) \(settings.effectiveTextModel) [\(index)] \(line) => \(translation ?? "REFUSED: " + reply)")
                if provider == .gemini { try await Task.sleep(for: .seconds(5)) }
            }
            // Through the app's own path, the short line after long ones is still its own translation.
            let short = try await api.translate(lines[8], sourceLanguage: "en", context: lines[5..<8].joined(separator: "\n"), settings: settings, key: key)
            XCTAssertTrue(short.contains("两个") || short.contains("两"), short)
            XCTAssertLessThan(short.count, 24, short)
        }
    }

    func testRealLiveTranscriptionTranslationAndRenewal() async throws {
        let (keys, audio) = try await inputs()
        for provider in [SpeechProvider.compatible, .gemini] {
            for direct in [false, true] {
                let name = "\(provider.rawValue):\(direct ? "translate" : "transcribe")"
                if !selected(name) { continue }
                var settings = AppSettings(); settings.speechProvider = provider; settings.sourceLanguage = "en"
                settings.translate = direct; settings.targetLanguage = "zh"
                let result = LiveResult()
                let renewal = provider == .gemini && ProcessInfo.processInfo.environment["ALTRANSCRIBE_CLOUD_NO_RENEW"] != "1"
                let speech = CloudSpeechSession(settings: settings, key: keys[provider == .gemini ? "gemini" : "openai"]!,
                                               renewAfter: renewal ? .seconds(15) : nil, renewBy: renewal ? .seconds(22) : nil,
                                               onUpdate: { await result.accept($0) })
                do {
                    log("CLOUD START: \(name)")
                    try await speech.start()
                    try await feed(audio, into: speech)
                    if renewal {
                        try await feed(AudioChunk(samples: Array(repeating: 0, count: 6 * 16_000), start: audio.duration), into: speech)
                        try await feed(AudioChunk(samples: audio.samples, start: audio.duration + 6), into: speech)
                    }
                    let confirmed = try await speech.finish()
                    let lines = await result.lines.values.sorted { $0.start < $1.start }
                    let text = lines.map(\.text).joined(separator: " ").lowercased()
                        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    XCTAssertTrue(text.contains("country"), name)
                    XCTAssertTrue(text.contains("do for your country"), "Final words: \(name)")
                    if direct {
                        let translation = lines.compactMap(\.translation).joined()
                        XCTAssertTrue(translation.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, name)
                        XCTAssertTrue(translation.contains("国家") || translation.contains("祖国"), name)
                        log("CLOUD TRANSLATION: \(name), \(translation)")
                    } else { XCTAssertTrue(confirmed, name) }
                    let renewals = await speech.renewalCount
                    if renewal {
                        XCTAssertEqual(renewals, 1)
                        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "country").count - 1, 4)
                    }
                    log("CLOUD RESULT: \(name), confirmed=\(confirmed), renewals=\(renewals), text=\(text)")
                } catch {
                    log("CLOUD PARTIAL: \(name), \(await result.lines.values.map(\.text).joined(separator: " "))")
                    await speech.cancel(); throw error
                }
                if provider == .gemini { try await Task.sleep(for: .seconds(20)) }
            }
        }
    }

    func testRealGeminiAcrossTenMinuteBoundary() async throws {
        guard ProcessInfo.processInfo.environment["ALTRANSCRIBE_CLOUD_LONG"] == "1" else { throw XCTSkip("Long cloud test is explicitly opt-in.") }
        let (keys, audio) = try await inputs()
        var settings = AppSettings(); settings.speechProvider = .gemini; settings.sourceLanguage = "en"
        let result = LiveResult()
        let speech = CloudSpeechSession(settings: settings, key: keys["gemini"]!, onUpdate: { await result.accept($0) })
        do {
            try await speech.start()
            try await feed(audio, into: speech)
            var offset = audio.duration
            while offset < 610 {
                let seconds = min(30, 610 - offset)
                try await feed(AudioChunk(samples: Array(repeating: 0, count: Int(seconds * 16_000)), start: offset), into: speech)
                offset += seconds
                log("LONG CLOUD: \(Int(offset)) s, renewals=\(await speech.renewalCount)")
            }
            try await feed(AudioChunk(samples: audio.samples, start: 610), into: speech)
            let confirmed = try await speech.finish()
            let lines = await result.lines.values.sorted { $0.start < $1.start }
            let text = lines.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(confirmed)
            let renewals = await speech.renewalCount
            XCTAssertEqual(renewals, 1)
            XCTAssertGreaterThan(lines.last?.end ?? 0, 610)
            XCTAssertGreaterThanOrEqual(text.components(separatedBy: "country").count - 1, 4)
            log("LONG CLOUD VERIFIED: final speech after 610 s retained; session renewed once")
        } catch {
            let partial = await result.lines.values.sorted { $0.start < $1.start }.map { "\(Int($0.start))s \($0.text)" }
            log("LONG CLOUD PARTIAL: renewals=\(await speech.renewalCount), warning=\(String(describing: await speech.warning?.message.key)), lines=\(partial)")
            await speech.cancel(); throw error
        }
    }

    func testRealGeminiNoiseOnlyTurnsRetainSpeechAndBoundTheStop() async throws {
        let (keys, audio) = try await inputs()
        guard selected("gemini:noise") else { throw XCTSkip("Not selected") }
        var settings = AppSettings(); settings.speechProvider = .gemini; settings.sourceLanguage = "en"
        let result = LiveResult()
        let speech = CloudSpeechSession(settings: settings, key: keys["gemini"]!, onUpdate: { await result.accept($0) })
        do {
            try await speech.start()
            // Low-level noise passes the local voice gate without containing speech, like a cough or a
            // keyboard. The service may send no event for it, leaving that activity unconfirmed.
            var generator = SystemRandomNumberGenerator()
            let noise = AudioChunk(samples: (0..<32_000).map { _ in Float.random(in: -0.01...0.01, using: &generator) }, start: 0)
            try await feed(noise, into: speech)
            try await feed(AudioChunk(samples: Array(repeating: 0, count: 16_000), start: 2), into: speech)
            try await feed(AudioChunk(samples: audio.samples, start: 3), into: speech)
            // Noise again after the speech: the final activity gets no answer either.
            try await feed(AudioChunk(samples: noise.samples, start: 3 + audio.duration), into: speech)
            try await feed(AudioChunk(samples: Array(repeating: 0, count: 16_000), start: 5 + audio.duration), into: speech)
            let began = ContinuousClock.now
            let confirmed = try await speech.finish()
            let warning = await speech.warning
            XCTAssertTrue(confirmed || warning != nil, "An unconfirmed stop must explain why")
            XCTAssertLessThan(began.duration(to: .now), .seconds(25), "The stop must remain bounded by the drain budget")
            let text = await result.lines.values.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("do for your country"), text)
            log("CLOUD RESULT: gemini noise-only turn, confirmed=\(confirmed), text=\(text)")
        } catch {
            log("CLOUD PARTIAL: gemini noise-only turn, \(await result.lines.values.map(\.text).joined(separator: " "))")
            await speech.cancel(); throw error
        }
    }

    private actor LiveResult {
        var lines: [UUID: TranscriptSegment] = [:]
        func accept(_ update: CloudSpeechUpdate) { lines[update.segment.id] = update.segment }
    }
    private func feed(_ audio: AudioChunk, into speech: CloudSpeechSession) async throws {
        let began = ContinuousClock.now
        for offset in stride(from: 0, to: audio.samples.count, by: 1600) {
            let end = min(audio.samples.count, offset + 1600)
            try await speech.accept(AudioChunk(samples: Array(audio.samples[offset..<end]), start: audio.start + Double(offset) / 16_000))
            try await ContinuousClock().sleep(until: began.advanced(by: .seconds(Double(end) / 16_000)))
        }
    }
    private func selected(_ name: String) -> Bool {
        let selected = ProcessInfo.processInfo.environment["ALTRANSCRIBE_CLOUD_CASE"]
        return selected == nil || selected == name
    }

    private func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
}
