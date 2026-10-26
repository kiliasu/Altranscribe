import XCTest
@preconcurrency import AVFoundation
@testable import AltranscribeCore

final class CoreTests: XCTestCase {
    func testEndpointRejectsCredentialLeaksAndNonLocalHTTP() throws {
        for invalid in ["http://example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/#secret", "file:///tmp/model", "http://localhost.example.com/v1"] {
            XCTAssertThrowsError(try APIEndpoint(invalid), invalid)
        }
        XCTAssertTrue(try APIEndpoint("http://127.0.0.1:11434/v1").isLoopback)
        XCTAssertTrue(try APIEndpoint("http://[::1]:11434/v1").isLoopback)
        XCTAssertEqual(try APIEndpoint("https://EXAMPLE.COM/api/v1/").url("chat/completions").absoluteString, "https://example.com/api/v1/chat/completions")
    }

    func testWaveHeaderAndClamping() {
        let wave = WaveEncoder.encode([-2, -1, 0, 1, 2, .nan])
        XCTAssertEqual(wave.count, 56)
        XCTAssertEqual(String(data: wave[0..<4], encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: wave[8..<16], encoding: .utf8), "WAVEfmt ")
        XCTAssertEqual(Array(wave[24..<28]), [0x80, 0x3e, 0, 0])
        XCTAssertEqual(Array(wave[44..<46]), [0x00, 0x80])
        XCTAssertEqual(Array(wave[50..<52]), [0xff, 0x7f])
        XCTAssertEqual(Array(wave[54..<56]), [0, 0])
    }

    func testChunkerKeepsFinalWordsAndMonotonicOffsets() {
        var chunker = AudioChunker(seconds: 1)
        XCTAssertTrue(chunker.append([Float](repeating: 0.1, count: 10_000)).isEmpty)
        let chunks = chunker.append([Float](repeating: 0.2, count: 23_000))
        XCTAssertEqual(chunks.map(\.start), [0, 1])
        XCTAssertEqual(chunks.map { $0.samples.count }, [16_000, 16_000])
        let tail = chunker.flush()
        XCTAssertEqual(tail?.samples.count, 1000)
        XCTAssertEqual(tail?.start, 2)
        XCTAssertNil(chunker.flush())
        XCTAssertEqual(chunker.duration, 2.0625)
        XCTAssertEqual(chunker.append([Float](repeating: 1, count: 16_000)).first?.start, 2.0625)
    }

    func testAtomicPersistenceRecoverySearchAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordStore(paths: AppPaths(root: root))
        var record = TranscriptRecord(title: "Lecture", source: .file, language: "en", speechModel: "tiny")
        var segment = TranscriptSegment(start: 0, end: 2, text: "A capacitor")
        segment.translation = "一个电容器"
        record.segments = [segment]
        try store.save(record)
        try Data("broken".utf8).write(to: store.paths.records.appendingPathComponent("broken.json"))
        let recovered = try store.load()
        XCTAssertEqual(recovered.unreadable, 1)
        XCTAssertEqual(recovered.records.first?.status, .interrupted)
        XCTAssertEqual(recovered.records.first?.segments, [segment])
        XCTAssertTrue(record.matches("CAPACITOR"))
        XCTAssertTrue(record.matches("电容"))
        XCTAssertFalse(record.matches("inductor"))
        record.status = .completed
        try store.save(record)
        XCTAssertEqual(try store.load().records.count, 1)
        XCTAssertEqual(try store.load().records.first?.status, .completed)
        try store.delete(record.id)
        XCTAssertTrue(try store.load().records.isEmpty)
    }

    func testExportsEscapeHTMLAndRetainBilingualContent() {
        var record = TranscriptRecord(title: "<script>alert('x')</script>", source: .file, language: "en", speechModel: "tiny")
        var segment = TranscriptSegment(start: 65, end: 70, text: "A & B < C", estimated: true)
        segment.translation = "甲和乙"
        record.segments = [segment]
        let html = TranscriptExport.render(record, as: .html)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("A &amp; B &lt; C"))
        for format in ExportFormat.allCases {
            let result = TranscriptExport.render(record, as: format)
            XCTAssertTrue(result.contains("甲和乙"))
            XCTAssertTrue(result.contains("01:05"))
            XCTAssertTrue(result.contains("≈"))
        }
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: Self.headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class APITests: XCTestCase, @unchecked Sendable {
    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
    private func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return APIClient(session: URLSession(configuration: config))
    }
    func testAuthenticationIsScopedAndLocalServiceNeedsNoKey() throws {
        let api = client()
        XCTAssertThrowsError(try api.request(endpoint: "https://example.com/v1", path: "models", key: ""))
        let local = try api.request(endpoint: "http://localhost:11434/v1", path: "chat/completions", key: "")
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"))
        let google = try api.request(endpoint: "https://generativelanguage.googleapis.com/v1beta", path: "models", key: "test-key", auth: "google")
        XCTAssertEqual(google.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertNil(google.value(forHTTPHeaderField: "Authorization"))
    }
    func testOpenAITranscriptionRequestAndEstimatedTimes() async throws {
        let names = OpenAITranscriptionModel.allCases.map(\.rawValue) + ["local-whisper"]
        for name in names {
            var settings = AppSettings(); settings.speechProvider = .compatible
            settings.speechModelOverride = " \(name) "
            settings.sourceLanguage = "en"; settings.vocabulary = "Codex，Altranscribe\nSwift"
            StubProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
                XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
                let body = String(decoding: try self.requestBody(request), as: UTF8.self)
                XCTAssertTrue(body.contains("name=\"model\"\r\n\r\n\(name)\r\n"))
                XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson\r\n"))
                XCTAssertEqual(body.contains("name=\"languages[]\""), name == "gpt-transcribe")
                XCTAssertEqual(body.contains("name=\"language\""), name != "gpt-transcribe")
                XCTAssertEqual(body.contains("name=\"keywords[]\""), name == "gpt-transcribe")
                let hasPrompt = name != "gpt-transcribe" && name != "gpt-4o-transcribe-diarize" && name != "local-whisper"
                XCTAssertEqual(body.contains("name=\"prompt\""), hasPrompt)
                XCTAssertEqual(body.contains("name=\"chunking_strategy\"\r\n\r\nauto\r\n"), name == "gpt-4o-transcribe-diarize")
                if name == "gpt-transcribe" {
                    for keyword in ["Codex", "Altranscribe", "Swift"] {
                        XCTAssertTrue(body.contains("name=\"keywords[]\"\r\n\r\n\(keyword)\r\n"))
                    }
                }
                return (200, Data(#"{"text":"Hello world."}"#.utf8))
            }
            let output = try await client().transcribe(AudioChunk(samples: [Float](repeating: 0, count: 16_000), start: 8), settings: settings, key: "test-key")
            XCTAssertEqual(output.first?.text, "Hello world.")
            XCTAssertEqual(output.first?.start, 8)
            XCTAssertEqual(output.first?.end, 9)
            XCTAssertEqual(output.first?.estimated, true)
        }
        StubProtocol.handler = { _ in XCTFail("Invalid settings must not send a paid request"); return (200, Data()) }
        for name in ["", "gpt-live-transcribe", "gpt-realtime-whisper", "gpt-transcribe"] {
            var settings = AppSettings(); settings.speechProvider = .compatible
            settings.speechModelOverride = name; settings.vocabulary = "<invalid>"
            do {
                _ = try await client().transcribe(AudioChunk(samples: [0], start: 0), settings: settings, key: "test-key")
                XCTFail("Expected unsupported model or invalid vocabulary")
            } catch { XCTAssertTrue(error is AppError) }
        }
    }
    func testGeminiRejectsTruncatedResultsAndExcludesThoughts() async throws {
        var settings = AppSettings(); settings.textProvider = .gemini; settings.textModel = "gemini-2.5-flash"
        StubProtocol.handler = { _ in (200, Data(#"{"status":"completed","steps":[{"type":"thought","content":[{"type":"text","text":"private reasoning"}]},{"type":"model_output","content":[{"type":"text","text":"translation"}]}]}"#.utf8)) }
        let result = try await client().complete(system: "translate", user: "text", settings: settings, key: "test-key")
        XCTAssertEqual(result, "translation")
        StubProtocol.handler = { _ in (200, Data(#"{"status":"incomplete","steps":[{"type":"model_output","content":[{"type":"text","text":"partial"}]}]}"#.utf8)) }
        do {
            _ = try await client().complete(system: "translate", user: "text", settings: settings, key: "test-key")
            XCTFail("Truncated output must not be marked complete")
        } catch { XCTAssertTrue(error is AppError) }
    }
    func testGeminiUploadUsesInteractionsAndDeletesAfterFailure() async throws {
        defer { StubProtocol.headers = [:] }
        for completed in [true, false] {
            var deleted = false
            StubProtocol.headers = ["x-goog-upload-url": "https://generativelanguage.googleapis.com/upload/fixture?upload_id=test"]
            StubProtocol.handler = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
                switch request.url!.path {
                case "/upload/v1beta/files":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Protocol"), "resumable")
                    return (200, Data("{}".utf8))
                case "/upload/fixture":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Command"), "upload, finalize")
                    return (200, Data(#"{"file":{"name":"files/fixture","uri":"https://generativelanguage.googleapis.com/v1beta/files/fixture","state":"ACTIVE"}}"#.utf8))
                case "/v1beta/interactions":
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: self.requestBody(request)) as? [String: Any])
                    XCTAssertEqual(body["model"] as? String, "gemini-3.5-transcribe")
                    let config = (body["generation_config"] as? [String: Any])?["transcription_config"] as? [String: Any]
                    XCTAssertEqual(config?["language_codes"] as? [String], ["cmn-Hans-CN"])
                    XCTAssertEqual(config?["custom_vocabulary"] as? [String], ["Altranscribe"])
                    let status = completed ? "completed" : "incomplete"
                    return (200, try JSONSerialization.data(withJSONObject: ["status": status, "steps": [["type": "model_output", "content": [["type": "text", "text": "Hello"]]]]]))
                case "/v1beta/files/fixture":
                    XCTAssertEqual(request.httpMethod, "DELETE"); deleted = true
                    return (200, Data("{}".utf8))
                default: XCTFail("Unexpected API route"); return (500, Data())
                }
            }
            var settings = AppSettings(); settings.speechProvider = .gemini; settings.sourceLanguage = "zh"
            settings.geminiSpeechModel = "gemini-2.5-flash"; settings.vocabulary = "Altranscribe"
            do {
                let lines = try await client().transcribe(AudioChunk(samples: [0], start: 0), settings: settings, key: "test-key")
                XCTAssertTrue(completed); XCTAssertEqual(lines.first?.text, "Hello")
            } catch { XCTAssertFalse(completed) }
            XCTAssertTrue(deleted, "Both success and failure must delete uploaded audio")
        }
    }
    func testTextModelOverridesRouteToSelectedProviderAndPersist() async throws {
        for provider in TextProvider.allCases {
            var settings = AppSettings(); settings.textProvider = provider
            settings.textBaseURL = "https://api.openai.com/v1"
            settings.textModel = try XCTUnwrap(settings.textModelPresets.first)
            let selected = try XCTUnwrap(settings.textModelPresets.last)
            settings.textModelOverride = " \(selected) "
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored, settings)
            StubProtocol.handler = { request in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: self.requestBody(request)) as? [String: Any])
                switch provider {
                case .compatible:
                    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
                    XCTAssertEqual(body["model"] as? String, selected)
                    XCTAssertNil(body["temperature"])
                    XCTAssertEqual(body["store"] as? Bool, false)
                    return (200, Data(#"{"status":"completed","error":null,"output":[{"type":"message","content":[{"type":"output_text","text":"translation"}]}]}"#.utf8))
                case .gemini:
                    XCTAssertEqual(request.url?.path, "/v1beta/interactions")
                    XCTAssertEqual(body["model"] as? String, selected)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
                    return (200, Data(#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"translation"}]}]}"#.utf8))
                case .anthropic:
                    XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
                    XCTAssertEqual(body["model"] as? String, selected)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
                    return (200, Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"translation"}]}"#.utf8))
                }
            }
            let output = try await client().translate("Hello", sourceLanguage: "en", context: "", settings: restored, key: "test-key")
            XCTAssertEqual(output, "translation")
            settings.textModelOverride = nil
            XCTAssertEqual(settings.effectiveTextModel, settings.textModel)
        }
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        old.removeValue(forKey: "speechModelOverride"); old.removeValue(forKey: "textModelOverride")
        old["speechProvider"] = "compatible"; old["speechModel"] = "custom-speech"
        old["textModel"] = "custom-text"
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(migrated.effectiveSpeechModel, "custom-speech")
        XCTAssertEqual(migrated.effectiveTextModel, "custom-text")
        XCTAssertNil(migrated.speechModelOverride); XCTAssertNil(migrated.textModelOverride)
    }
    func testAPIFailureDoesNotExposeProviderBodyOrRetry() async throws {
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; return (401, Data(#"{"error":{"message":"secret-key and transcript"}}"#.utf8)) }
        var settings = AppSettings(); settings.textModel = "model"
        do {
            _ = try await client().complete(system: "test", user: "input", settings: settings, key: "test-key")
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("secret-key"))
        }
        XCTAssertEqual(calls, 1)
    }
    func testSummaryUsesCapturedInterfaceLanguageInsteadOfTranslationTarget() async throws {
        var settings = AppSettings(); settings.textModel = "test-model"; settings.targetLanguage = "ja"
        for language in ["en", "zh"] {
            StubProtocol.handler = { request in
                let data: Data
                if let body = request.httpBody { data = body }
                else {
                    let stream = try XCTUnwrap(request.httpBodyStream)
                    stream.open(); defer { stream.close() }
                    var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                    data = body
                }
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
                XCTAssertTrue(messages[0]["content"]!.contains("factually in \(language)."))
                XCTAssertFalse(messages[0]["content"]!.contains("factually in ja."))
                return (200, Data(#"{"choices":[{"message":{"content":"{\"title\":\"Title\",\"summary\":\"Summary\"}"},"finish_reason":"stop"}]}"#.utf8))
            }
            let output = try await client().summarize("Transcript", language: language, settings: settings, key: "")
            XCTAssertEqual(output.summary, "Summary")
        }
    }
}

final class MediaTests: XCTestCase, @unchecked Sendable {
    func testDecodePreservesFinalPartialChunk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = (0..<336_000).map { Float(sin(Double($0) * 0.03) * 0.1) }
        try WaveEncoder.encode(samples).write(to: url)
        let decoder = MediaDecoder()
        let duration = try await decoder.open(url)
        XCTAssertEqual(duration, 21, accuracy: 0.02)
        let first = try await decoder.next()
        let final = try await decoder.next()
        let end = try await decoder.next()
        XCTAssertEqual(first?.samples.count, 320_000)
        XCTAssertEqual(final?.samples.count, 16_000)
        XCTAssertEqual(final?.start, 20)
        XCTAssertNil(end)
        await decoder.cancel()
    }

    func testDecodeStereo48kHzIntoMono16kHz() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<48_000 {
            buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.03) * 0.2)
            buffer.floatChannelData![1][i] = buffer.floatChannelData![0][i]
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let decoder = MediaDecoder()
        _ = try await decoder.open(url)
        let chunk = try await decoder.next()
        // AVAssetReader's resampler can trim a few filter-delay samples at EOF.
        XCTAssertEqual(chunk?.duration ?? 0, 1, accuracy: 0.001)
        XCTAssertGreaterThan(chunk?.samples.map(abs).max() ?? 0, 0.1)
        await decoder.cancel()
    }

    func testDecodeMovieWithDelayedAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("source.wav")
        try WaveEncoder.encode([Float](repeating: 0.1, count: 32_000)).write(to: wav)
        let asset = AVURLAsset(url: wav)
        let source = try await asset.loadTracks(withMediaType: .audio)[0]
        let composition = AVMutableComposition()
        let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 16_000)), of: source, at: CMTime(seconds: 3, preferredTimescale: 16_000))
        let movie = folder.appendingPathComponent("delayed.mov")
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await exporter.export(to: movie, as: .mov)
        let decoder = MediaDecoder()
        _ = try await decoder.open(movie)
        let chunk = try await decoder.next()
        let decoded = try XCTUnwrap(chunk)
        let onset = try XCTUnwrap(decoded.samples.firstIndex { abs($0) > 0.05 })
        // Some containers materialize the edit-list gap as silence; both representations must align.
        XCTAssertEqual(decoded.start + Double(onset) / 16_000, 3, accuracy: 0.02)
        XCTAssertEqual(decoded.start + decoded.duration, 5, accuracy: 0.02)
        await decoder.cancel()
    }

    func testRealLocalWhisperPipeline() async throws {
        guard let path = ProcessInfo.processInfo.environment["ALTRANSCRIBE_TEST_MODEL"],
              let audio = ProcessInfo.processInfo.environment["ALTRANSCRIBE_TEST_AUDIO"] else {
            throw XCTSkip("Set ALTRANSCRIBE_TEST_MODEL and ALTRANSCRIBE_TEST_AUDIO to run local inference.")
        }
        let whisper = NativeWhisper()
        try await whisper.load(model: path, useGPU: true)
        let decoder = MediaDecoder()
        _ = try await decoder.open(URL(fileURLWithPath: audio))
        var segments: [TranscriptSegment] = []
        while let chunk = try await decoder.next() {
            segments += try await whisper.transcribe(chunk, language: "en", vocabulary: "")
        }
        await whisper.unload()
        await decoder.cancel()
        let text = segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("ask not"), text)
        XCTAssertTrue(text.contains("country"), text)
        XCTAssertTrue(segments.allSatisfy { $0.start >= 0 && $0.end >= $0.start })
    }
}
