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
        let paths = AppPaths(root: root, recordings: root.appendingPathComponent("Documents/Recordings", isDirectory: true))
        let store = RecordStore(paths: paths)
        var record = TranscriptRecord(title: "Capture", source: .microphone, language: "en", speechModel: "test")
        record.hasRecording = true
        record.recordingFilename = AppPaths.recordingFilename(for: record)
        let sink = CaptureSink(recordingURL: paths.recording(record)) { _, _ in }
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
        let file = try AVAudioFile(forReading: paths.recording(record))
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 0.75, accuracy: 0.1)
        file.close()
        try store.save(record)
        XCTAssertEqual(try store.load().records.first?.hasRecording, true)

        // Upgrade a UUID-named recording. A failed move must retain both its transcript and audio;
        // reopening after the destination becomes available must finish the move without re-encoding.
        let audio = try Data(contentsOf: paths.recording(record))
        let legacy = root.appendingPathComponent("Recordings/\(record.id).m4a")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: paths.recording(record), to: legacy)
        record.recordingFilename = nil
        try store.save(record)
        try FileManager.default.removeItem(at: paths.recordings)
        try Data().write(to: paths.recordings) // A file blocks creation of the new recording directory.
        XCTAssertThrowsError(try store.relocateRecording(&record))
        let retained = try XCTUnwrap(store.load().records.first)
        XCTAssertEqual(paths.recording(retained), legacy)
        XCTAssertEqual(try Data(contentsOf: paths.recording(retained)), audio)
        try FileManager.default.removeItem(at: paths.recordings)
        try store.relocateRecording(&record)
        record = try XCTUnwrap(store.load().records.first)
        XCTAssertEqual(paths.recording(record).deletingLastPathComponent(), paths.recordings)
        XCTAssertEqual(try Data(contentsOf: paths.recording(record)), audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        try store.delete(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.recording(record).path))
        XCTAssertEqual(AppSettings().captionSize, 20)
        var settings = AppSettings(); settings.captionSize = 30
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).captionSize, 30)
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
