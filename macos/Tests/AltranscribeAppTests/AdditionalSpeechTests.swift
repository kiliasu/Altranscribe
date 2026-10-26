import XCTest
@preconcurrency import AVFoundation
@testable import Altranscribe
import AltranscribeCore

@MainActor final class AdditionalSpeechTests: XCTestCase {
    func testRealLocalEnginesCaptureTailCancellationAndFileQueue() async throws {
        guard let root = ProcessInfo.processInfo.environment["ALTRANSCRIBE_TEST_ADDITIONAL_ROOT"],
              let audio = ProcessInfo.processInfo.environment["ALTRANSCRIBE_TEST_AUDIO"] else {
            throw XCTSkip("Set ALTRANSCRIBE_TEST_ADDITIONAL_ROOT and ALTRANSCRIBE_TEST_AUDIO for real-engine validation.")
        }
        let paths = AppPaths(root: URL(fileURLWithPath: root))
        try paths.prepare()
        let decoder = MediaDecoder()
        _ = try await decoder.open(URL(fileURLWithPath: audio))
        let decoded = try await decoder.next()
        let chunk = try XCTUnwrap(decoded)
        await decoder.cancel()
        try await FluidAudioModel.english.download(to: paths.models)
        try await FluidAudioModel.multilingual.download(to: paths.models)
        try await NativeAppleSpeech.install(locale: "en-US")

        for (provider, fluidModel) in [(SpeechProvider.fluidAudio, FluidAudioModel.english),
                                      (.fluidAudio, .multilingual), (.appleSpeech, .english)] {
            let fluid = NativeFluidAudio(), apple = NativeAppleSpeech()
            if provider == .fluidAudio { try await fluid.load(model: fluidModel, models: paths.models) }
            else { try await apple.load(locale: "en-US") }
            let sink = CaptureSink(chunkSeconds: 8) { _, _ in }
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count))!
            buffer.frameLength = buffer.frameCapacity
            chunk.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            sink.microphone(buffer)
            await sink.finish()
            var segments: [TranscriptSegment] = []
            var capturedSamples = 0
            for try await part in sink.stream {
                capturedSamples += part.samples.count
                let lines = provider == .fluidAudio
                    ? try await fluid.transcribe(part) : try await apple.transcribe(part, vocabulary: "")
                XCTAssertTrue(lines.allSatisfy { $0.start >= part.start && $0.end <= part.start + part.duration })
                segments += lines
            }
            XCTAssertEqual(capturedSamples, chunk.samples.count)
            let text = segments.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("ask not"), text)
            XCTAssertTrue(text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).hasSuffix("country"), text)
            print("\(provider.rawValue) capture including tail: \(text)")

            let inference = Task {
                if provider == .fluidAudio { return try await fluid.transcribe(chunk) }
                return try await apple.transcribe(chunk, vocabulary: "")
            }
            try await Task.sleep(for: .milliseconds(20))
            inference.cancel()
            do { _ = try await inference.value; XCTFail("Cancelled inference returned a result") }
            catch is CancellationError { }
            await fluid.unload(); await apple.unload()

            let app = AppModel(paths: paths)
            app.settings = AppSettings()
            app.settings.speechProvider = provider
            app.settings.fluidAudioModelID = fluidModel.id
            app.addFiles([URL(fileURLWithPath: audio)])
            app.startQueue()
            let deadline = Date().addingTimeInterval(90)
            while app.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if app.busy { app.cancel(); XCTFail("File transcription timed out"); return }
            XCTAssertNil(app.error)
            XCTAssertEqual(app.queue.first?.status, .completed, app.queue.first?.error?.text ?? "")
            let record = try XCTUnwrap(app.activeRecord)
            XCTAssertEqual(record.status, .completed)
            XCTAssertEqual(record.language, provider == .fluidAudio && fluidModel == .multilingual ? "auto" : "en")
            XCTAssertTrue(record.fullText.lowercased().contains("ask not"), record.fullText)
            let stored = try XCTUnwrap(app.store.load().records.first { $0.id == record.id })
            XCTAssertEqual(stored.fullText, record.fullText)
            print("\(provider.rawValue) saved file: \(record.fullText)")
        }
    }
}
