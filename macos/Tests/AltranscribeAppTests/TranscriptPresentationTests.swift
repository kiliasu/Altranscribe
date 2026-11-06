import XCTest
import SwiftUI
@testable import Altranscribe
import AltranscribeCore

@MainActor private final class TranscriptFixture: ObservableObject {
    @Published var active = true
    @Published var live: LiveState? = .recording
    @Published var record = TranscriptRecord(title: "Rendering", source: .microphone, language: "en", speechModel: "fixture")
}

private struct TranscriptFixtureView: View {
    @ObservedObject var fixture: TranscriptFixture
    var body: some View {
        TranscriptScroll(record: fixture.record, live: fixture.live) { _ in EmptyView() }
            .environment(\.appearsActive, fixture.active)
    }
}

@MainActor final class TranscriptPresentationTests: XCTestCase {
    func testBackgroundUpdatesReturnAsOneSettledTranscript() throws {
        _ = NSApplication.shared
        let fixture = TranscriptFixture()
        let host = NSHostingView(rootView: TranscriptFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        wait(0.2)
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let indicatorHeight = table.rect(ofRow: 0).height
        for state: LiveState in [.paused, .transcribing, .translating, .summarizing, .recording] {
            fixture.live = state; wait(0.3)
            XCTAssertEqual(table.rect(ofRow: 0).height, indicatorHeight, accuracy: 0.25,
                           "Status changes must not resize the transcript's last row")
        }
        // Keep the old native layout while updates accumulate. A longer background interval must
        // not add more native row updates or extend a sequence of height corrections after return.
        for count in [120, 600] {
            fixture.active = false; wait(0.05)
            let previousRows = table.numberOfRows
            let previousHeight = table.frame.height
            for _ in 0..<count {
                let i = fixture.record.segments.count
                var line = TranscriptSegment(start: Double(i * 4), end: Double(i * 4 + 4),
                    text: "Line \(i). Words continue to arrive while the transcript window is in the background.")
                fixture.record.segments.append(line); wait(0.002)
                line.translation = "这是后台生成的译文，修订完成后仍应完整显示。"
                line.translationIsProvisional = true
                fixture.record.segments[i] = line; wait(0.002)
                fixture.record.segments[i].translationIsProvisional = nil
            }
            XCTAssertEqual(table.numberOfRows, previousRows, "Inactive native rows must not be diffed for every result")
            XCTAssertEqual(table.frame.height, previousHeight, accuracy: 0.25)
            fixture.active = true; wait(0.05)
            XCTAssertTrue(descendants(host).contains { $0 === table }, "Returning must retain the native list and reading state")
            XCTAssertEqual(table.numberOfRows, fixture.record.segments.count + 2, "All accumulated text must appear on return")
            let height = table.frame.height
            let offset = scroll.contentView.bounds.origin.y
            for _ in 0..<25 {
                wait(0.01)
                XCTAssertEqual(table.frame.height, height, accuracy: 0.5, "No deferred height correction sequence")
                XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 0.5, "No replayed scroll sequence")
            }
            XCTAssertLessThanOrEqual(table.rect(ofRow: table.numberOfRows - 1).maxY,
                                     scroll.documentVisibleRect.maxY + 1, "Following must reach the actual last row")
        }
        // A task that finishes in the background must also publish its final state, without a stale spinner.
        fixture.active = false; wait(0.03)
        fixture.live = nil; fixture.record.status = .completed; wait(0.03)
        fixture.active = true; wait(0.05)
        XCTAssertEqual(table.numberOfRows, fixture.record.segments.count + 1)
    }

    private func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
