import XCTest
@preconcurrency import AVFoundation
@testable import Altranscribe
import AltranscribeCore

final class CaptureTests: XCTestCase, @unchecked Sendable {
    private func buffer(seconds: Double, rate: Double = 16_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.03) * 0.1) }
        return buffer
    }

    func testPauseResumeAndStopKeepTailWithoutCapturingPausedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root), store = RecordStore(paths: AppPaths(root: root))
        var record = TranscriptRecord(title: "Capture", source: .microphone, language: "en", speechModel: "test")
        record.hasRecording = true
        let sink = CaptureSink(recordingURL: paths.recording(record.id)) { _, _ in }
        sink.microphone(buffer(seconds: 0.5))
        sink.setPaused(true)
        sink.microphone(buffer(seconds: 1))
        sink.setPaused(false)
        sink.microphone(buffer(seconds: 0.25))
        record.recordingDuration = await sink.finish()
        var chunks: [AudioChunk] = []
        for try await chunk in sink.stream { chunks.append(chunk) }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map(\.start), [0, 0.5])
        XCTAssertEqual(chunks.map(\.duration), [0.5, 0.25])
        XCTAssertEqual(record.recordingDuration ?? 0, 0.75, accuracy: 0.01)
        let file = try AVAudioFile(forReading: paths.recording(record.id))
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 0.75, accuracy: 0.1)
        file.close()
        try store.save(record)
        XCTAssertEqual(try store.load().records.first?.hasRecording, true)
        try store.delete(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.recording(record.id).path))
        await sink.finish() // Teardown is idempotent.
    }

    func testLiveResampling() async throws {
        let sink = CaptureSink { _, _ in }
        sink.microphone(buffer(seconds: 1, rate: 48_000))
        await sink.finish()
        var count = 0
        for try await chunk in sink.stream { count += chunk.samples.count }
        XCTAssertEqual(Double(count) / 16_000, 1, accuracy: 0.01)
    }

    func testBackpressureFailsInsteadOfSilentlyDroppingAudio() async throws {
        for (seconds, automatic, expected) in [(8.0, false, 8), (4.0, true, 16)] {
            let sink = CaptureSink(chunkSeconds: seconds, automaticChunks: automatic) { _, _ in }
            sink.microphone(buffer(seconds: 72))
            await sink.finish()
            var delivered = 0
            do {
                for try await _ in sink.stream { delivered += 1 }
                XCTFail("An overrun must be reported")
            } catch { XCTAssertTrue(error is AppError) }
            XCTAssertEqual(delivered, expected, "Automatic slicing must keep the same 64-second buffering limit")
        }
    }
}
