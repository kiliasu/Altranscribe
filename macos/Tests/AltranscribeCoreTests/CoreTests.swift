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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
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
        StubProtocol.handler = { _ in (200, Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"private reasoning"},{"text":"translation"}]}}]}"#.utf8)) }
        let result = try await client().complete(system: "translate", user: "text", settings: settings, key: "test-key")
        XCTAssertEqual(result, "translation")
        StubProtocol.handler = { _ in (200, Data(#"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"partial"}]}}]}"#.utf8)) }
        do {
            _ = try await client().complete(system: "translate", user: "text", settings: settings, key: "test-key")
            XCTFail("Truncated output must not be marked complete")
        } catch { XCTAssertTrue(error is AppError) }
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
