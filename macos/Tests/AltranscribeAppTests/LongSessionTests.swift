import XCTest
import SwiftUI
@testable import Altranscribe
import AltranscribeCore

@MainActor final class LongSessionTests: XCTestCase {
    func testLongTranscriptUpdatesAndCleanup() async throws {
        guard let path = ProcessInfo.processInfo.environment["ALTRANSCRIBE_LONG_RECORD"] else {
            throw XCTSkip("Opt in with a retained long transcript; no audio or model is used.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(TranscriptRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        record.id = UUID(); record.status = .inProgress
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(paths: AppPaths(root: root))
        app.records = [record]; app.activeRecordID = record.id; app.phase = .recording
        var settings = AppSettings(); settings.translate = false
        let window = NSWindow(contentViewController: NSHostingController(rootView: LiveView(model: app)))
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        var durations: [Double] = []
        var line = TranscriptSegment(start: record.duration + 1, end: record.duration + 2, text: "A growing sentence")
        for i in 0..<360 {
            line.text = "A growing sentence with the latest words \(i)."
            line.end += 0.32
            let start = Date()
            if i % 12 == 11 {
                try await app.saveSegments([line], recordID: record.id, configuration: settings, textKey: "")
                line = TranscriptSegment(start: line.end, end: line.end + 0.32, text: "Next sentence")
            } else {
                try await app.saveSegments([], partial: line, recordID: record.id, configuration: settings, textKey: "")
            }
            durations.append(Date().timeIntervalSince(start))
            try await Task.sleep(for: .milliseconds(5))
        }
        try await app.finishRecord(record.id, configuration: settings, textKey: "")
        XCTAssertEqual(app.records[0].segments.count, record.segments.count + 30)
        XCTAssertEqual(try app.store.load().records[0].segments, app.records[0].segments)
        XCTAssertEqual(app.pendingTranslations, 0)
        durations.sort()
        print("LONG_SESSION rows=\(record.segments.count) updates=360 median_ms=\(durations[180] * 1000) p99_ms=\(durations[356] * 1000) max_ms=\(durations.last! * 1000)")
    }
}
