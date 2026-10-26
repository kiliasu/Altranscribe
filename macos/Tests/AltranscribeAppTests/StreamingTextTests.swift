import XCTest
import SwiftUI
@testable import Altranscribe
import AltranscribeCore

@MainActor private final class StreamingFixture: ObservableObject {
    @Published var text = "Stable "
}

private struct StreamingFixtureView: View {
    @ObservedObject var fixture: StreamingFixture
    let animated: Bool
    var body: some View {
        StreamingText(fixture.text, active: animated)
            .font(.system(size: 24, design: .monospaced))
            .foregroundStyle(.black)
            .frame(width: 420, height: 100, alignment: .topLeading)
            .padding(12)
            .background(.white)
    }
}

@MainActor final class StreamingTextTests: XCTestCase {
    func testStreamingChangesKeepPrefixAndLayoutStableWithoutDelayingFinalText() throws {
        _ = NSApplication.shared
        XCTAssertEqual(StreamingText.commonPrefix("Hello worl", "Hello world"), 10)
        XCTAssertEqual(StreamingText.commonPrefix("turn left", "turn right"), 5)
        XCTAssertEqual(StreamingText.commonPrefix("你好世界", "你好"), 2)
        XCTAssertEqual(StreamingText.commonPrefix("👨‍👩‍👧‍👦 and", "👨‍👩‍👧‍👦 or"), 2)
        XCTAssertEqual(StreamingText.commonPrefix("café", "cafe\u{301}!"), 4)

        for reduced in [false, true] {
            let fixture = StreamingFixture()
            let host = NSHostingView(rootView: StreamingFixtureView(fixture: fixture, animated: !reduced))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 444, height: 124),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            wait(0.2)
            let frame = window.frame
            fixture.text = "Stable words"
            wait(0.04)
            let early = try snapshot(host)
            wait(0.22)
            let final = try snapshot(host)
            XCTAssertEqual(window.frame, frame, "Streaming must not resize the native window")
            XCTAssertEqual(early.size, final.size, "Animation must not change the layout's measured size")
            XCTAssertEqual(try pixels(early, width: 80), try pixels(final, width: 80), "Previously displayed letters must not flash")
            if reduced { XCTAssertEqual(try pixels(early), try pixels(final), "Disabled effects must show complete text immediately") }
            else { XCTAssertNotEqual(try pixels(early), try pixels(final), "The appended suffix must actually animate") }

            // Revisions can arrive before an earlier animation completes; no queued typing may restore stale text.
            fixture.text = "Stable words that were wrong"
            wait(0.03)
            fixture.text = "Stable corrected 中文 👨‍👩‍👧‍👦"
            wait(0.03)
            fixture.text = "Stable final"
            wait(0.25)
            let latest = try snapshot(host)
            wait(0.25)
            XCTAssertEqual(try pixels(latest), try pixels(snapshot(host)), "An older update must not reappear")
        }
    }

    func testLiveAndCaptionWindowsHandleRevisionsTranslationsAndRollover() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root))
        model.settings.translate = false; model.settings.captionSize = 22
        model.phase = .recording; model.status = LocalizedText("Listening")
        var record = TranscriptRecord(title: "Caption motion preview", source: .microphone, language: "en", speechModel: "preview")
        record.segments = [TranscriptSegment(start: 0, end: 2, text: "We are")]
        model.records = [record]; model.activeRecordID = record.id
        let main = NSWindow(contentViewController: NSHostingController(rootView: NavigationStack { LiveView(model: model) }))
        main.isReleasedWhenClosed = false
        main.setContentSize(NSSize(width: 860, height: 580)); main.orderFront(nil)
        let captions = CaptionWindow(model: model)
        model.captions = captions
        captions.show()
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.title == L("Altranscribe Captions") })
        defer { main.close(); panel.close(); model.captions = nil }
        wait(0.4)
        let frame = main.frame
        model.records[0].segments[0].text = "We are testing live captions."
        wait(0.04)
        model.records[0].segments[0].translation = "我们正在测试"
        model.records[0].segments[0].translationIsProvisional = true
        wait(0.1)
        model.records[0].segments[0].translation = "我们正在测试实时字幕。"
        model.records[0].segments[0].translationIsProvisional = nil
        for (i, text) in ["New words arrive while the previous sentence stays steady.",
                          "The caption panel keeps the latest three sentences.",
                          "Corrections appear immediately, without a typing queue."].enumerated() {
            var line = TranscriptSegment(start: Double(i + 1) * 3, end: Double(i + 2) * 3, text: text)
            line.translation = ["新文字出现时，前面的内容保持稳定。", "悬浮字幕保留最近三个片段。", "修订立即出现，无需等待逐字播放。"][i]
            model.records[0].segments.append(line)
            wait(0.08)
        }
        wait(0.5)
        XCTAssertEqual(main.frame, frame)
        XCTAssertEqual(model.captionSegments.count, 3)
        panel.setContentSize(NSSize(width: 420, height: 200))
        model.settings.captionSize = 36; model.settings.captionTranslationOnly = true
        model.phase = .paused; model.status = LocalizedText("Paused")
        wait(0.4)
        XCTAssertEqual(panel.frame.width, 420, accuracy: 1)
        model.phase = .idle
        wait(0.5)
        XCTAssertTrue(model.captionSegments.isEmpty)
    }

    private func wait(_ duration: Double) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }

    private func pixels(_ image: NSBitmapImageRep, width: Int? = nil) throws -> Data {
        let bytes = try XCTUnwrap(image.bitmapData)
        var data = Data()
        let rowSize = width.map { min($0, image.pixelsWide) * image.bitsPerPixel / 8 } ?? image.bytesPerRow
        for y in 0..<image.pixelsHigh { data.append(bytes.advanced(by: y * image.bytesPerRow), count: rowSize) }
        return data
    }

}
