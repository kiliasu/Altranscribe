import XCTest
@preconcurrency import AVFoundation
@testable import Altranscribe
import AltranscribeCore

@MainActor final class NemotronTests: XCTestCase {
    func testEnglishDefaultAndExistingSettings() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.speechProvider, .nemotron)
        XCTAssertFalse(settings.nemotronModel.multilingual)
        settings.sourceLanguage = "zh"
        XCTAssertEqual(settings.recognitionLanguage, "en")
        settings.nemotronModelID = NemotronModel.catalog[1].id
        XCTAssertEqual(settings.recognitionLanguage, "zh")

        settings.speechProvider = .whisper
        settings.modelPath = "/existing/ggml-small.bin"
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        old.removeValue(forKey: "nemotronModelID")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(restored.speechProvider, .whisper)
        XCTAssertEqual(restored.modelPath, settings.modelPath)
        XCTAssertEqual(restored.sourceLanguage, "zh")
        XCTAssertFalse(restored.nemotronModel.multilingual)
    }

    func testRealStreamingTailAndFileQueue() async throws {
        guard let root = ProcessInfo.processInfo.environment["ALTRANSCRIBE_TEST_NEMOTRON_ROOT"],
              let audio = ProcessInfo.processInfo.environment["ALTRANSCRIBE_TEST_AUDIO"] else {
            throw XCTSkip("Set ALTRANSCRIBE_TEST_NEMOTRON_ROOT and ALTRANSCRIBE_TEST_AUDIO for the real-model smoke test.")
        }
        let paths = AppPaths(root: URL(fileURLWithPath: root))
        try paths.prepare()
        let decoder = MediaDecoder()
        _ = try await decoder.open(URL(fileURLWithPath: audio))
        var samples: [Float] = []
        while let chunk = try await decoder.next() { samples += chunk.samples }
        await decoder.cancel()
        let models = ProcessInfo.processInfo.environment["ALTRANSCRIBE_TEST_MULTILINGUAL"] == "1"
            ? NemotronModel.catalog : [NemotronModel.catalog[0]]

        for item in models {
            let directory = try await item.download(to: paths.models)
            let engine = NativeNemotron()
            try await engine.load(model: item, directory: directory, language: item.multilingual ? "auto" : "en")
            let sink = CaptureSink(chunkSeconds: 0.32) { _, _ in }
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            sink.microphone(buffer)
            await sink.finish()

            let started = Date()
            var finalized: [TranscriptSegment] = []
            var sawPartial = false
            var capturedSamples = 0
            func merge(_ update: NemotronUpdate) {
                sawPartial = sawPartial || update.partial != nil
                for line in update.finalized {
                    if let index = finalized.firstIndex(where: { $0.id == line.id }) { finalized[index] = line }
                    else { finalized.append(line) }
                }
            }
            for try await chunk in sink.stream {
                capturedSamples += chunk.samples.count
                merge(try await engine.accept(chunk))
            }
            merge(try await engine.finish())
            XCTAssertTrue(sawPartial, "Streaming must produce text before Stop")
            XCTAssertEqual(capturedSamples, samples.count, "Capture must preserve the final short buffer")
            let text = finalized.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("ask not"), text)
            XCTAssertTrue(text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).hasSuffix("country"), text)
            XCTAssertTrue(finalized.allSatisfy { $0.start >= 0 && $0.end <= Double(samples.count) / 16_000 })
            let again = try await engine.finish()
            XCTAssertTrue(again.finalized.isEmpty, "Finishing twice must not duplicate the last sentence")
            print("Nemotron \(item.id): \(String(format: "%.2f", Double(samples.count) / 16_000)) s audio / \(String(format: "%.2f", Date().timeIntervalSince(started))) s CPU processing; \(text)")
            await engine.unload()

            // Exercise the app's file queue, upserts, EOF flush and persisted record together.
            let app = AppModel(paths: paths)
            app.settings = AppSettings()
            app.settings.nemotronModelID = item.id
            app.addFiles([URL(fileURLWithPath: audio)])
            app.startQueue()
            let deadline = Date().addingTimeInterval(90)
            while app.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if app.busy { app.cancel(); XCTFail("File transcription timed out"); return }
            XCTAssertNil(app.error)
            XCTAssertEqual(app.queue.first?.status, .completed)
            let record = try XCTUnwrap(app.activeRecord)
            XCTAssertEqual(record.speechModel, item.id)
            XCTAssertEqual(record.status, .completed)
            XCTAssertEqual(record.language, item.multilingual ? "auto" : "en")
            XCTAssertTrue(record.fullText.lowercased().contains("ask not"), record.fullText)
            XCTAssertEqual(record.segments.count, Set(record.segments.map(\.id)).count)
            let stored = try XCTUnwrap(app.store.load().records.first { $0.id == record.id })
            XCTAssertEqual(stored.fullText, record.fullText)
            XCTAssertTrue(TranscriptExport.render(stored, as: .text).contains(record.segments.last?.text ?? "missing"))
        }
    }
}
