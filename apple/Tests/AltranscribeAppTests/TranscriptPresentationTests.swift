import XCTest
import SwiftUI
@testable import Altranscribe
import AltranscribeCore

@MainActor private final class TranscriptFixture: ObservableObject {
    @Published var active = true
    @Published var live: LiveState? = .recording
    @Published var highlight = ""
    @Published var record = TranscriptRecord(title: "Rendering", source: .microphone, language: "en", speechModel: "fixture")

    /// One line arriving the way a session delivers it: the text, a provisional translation, the final one.
    func speak(wait: (Double) -> Void) {
        let index = record.segments.count
        var line = TranscriptSegment(start: Double(index * 4), end: Double(index * 4 + 4),
            text: "Line \(index). Words continue to arrive while the transcript window is somewhere behind the others.")
        record.segments.append(line); wait(0.002)
        line.translation = "这是在后台生成的译文，"
        line.translationIsProvisional = true
        record.segments[index] = line; wait(0.002)
        record.segments[index].translation = "这是在后台生成的译文，修订完成后仍应完整显示在这一行的下面。"
        record.segments[index].translationIsProvisional = nil
    }
}

private struct TranscriptFixtureView: View {
    @ObservedObject var fixture: TranscriptFixture
    var body: some View {
        TranscriptScroll(record: fixture.record, live: fixture.live, highlight: fixture.highlight) { _ in EmptyView() }
            .environment(\.appearsActive, fixture.active)
    }
}

/// A growing transcript rests on its latest line and stays there: in front, behind another app, when
/// many lines arrive at once, and while its window changes size. Nothing is held back while the app is
/// in the background, so there is nothing to catch up with, or to scroll through, when it returns.
@MainActor final class TranscriptPresentationTests: XCTestCase {
    private var scroll: NSScrollView!
    /// How far the view is from the end of the transcript. Zero when the last line rests on the bottom edge.
    private var distance: CGFloat {
        (scroll.documentView?.frame.height ?? 0) + scroll.contentInsets.bottom - scroll.contentView.bounds.maxY
    }
    private var offset: CGFloat { scroll.contentView.bounds.origin.y }
    private var height: CGFloat { scroll.documentView?.frame.height ?? 0 }

    func testAGrowingTranscriptStaysOnItsLatestLine() throws {
        _ = NSApplication.shared
        let fixture = TranscriptFixture()
        let host = NSHostingView(rootView: TranscriptFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        wait(0.2)
        scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)

        // In front: every line lands with the view on the end.
        for _ in 0..<40 { fixture.speak(wait: wait) }
        wait(0.1)
        XCTAssertGreaterThan(height, scroll.contentView.bounds.height * 2, "The transcript must be longer than its window for this test")
        XCTAssertEqual(distance, 0, accuracy: 1, "An active transcript follows its latest line")

        // What the session is doing changes the line under the text, never its height.
        let settled = height
        for state: LiveState in [.paused, .transcribing, .translating, .summarizing, .recording] {
            fixture.live = state; wait(0.3)
            XCTAssertEqual(height, settled, accuracy: 0.25, "Status changes must not resize the transcript")
            XCTAssertEqual(distance, 0, accuracy: 1)
        }

        // Behind another app: lines are laid out as they arrive, and the view stays on the latest one.
        for count in [120, 600] {
            fixture.active = false; wait(0.05)
            let before = height
            for index in 0..<count {
                fixture.speak(wait: wait)
                if index % 60 == 59 {
                    wait(0.02)
                    XCTAssertEqual(distance, 0, accuracy: 1, "Line \(index) of \(count) in the background")
                }
            }
            wait(0.05)
            XCTAssertGreaterThan(height, before + CGFloat(count) * 20, "Text that arrives in the background is laid out then, not on return")
            XCTAssertEqual(distance, 0, accuracy: 1)
            // Coming back changes nothing: no text to catch up with, no position to correct, no scrolling to replay.
            let resting = (offset: offset, height: height)
            fixture.active = true
            for _ in 0..<25 {
                wait(0.01)
                XCTAssertEqual(height, resting.height, accuracy: 0.5, "No height correction after returning")
                XCTAssertEqual(offset, resting.offset, accuracy: 0.5, "No scrolling after returning")
            }
            XCTAssertEqual(distance, 0, accuracy: 1)
        }

        // Many lines in one update, as after a stalled recognizer: the next layout is already on the end.
        for active in [false, true] {
            fixture.active = active; wait(0.03)
            let first = fixture.record.segments.count
            fixture.record.segments.append(contentsOf: (0..<400).map { index in
                var line = TranscriptSegment(start: Double((first + index) * 4), end: Double((first + index) * 4 + 4),
                                             text: "Burst line \(first + index), delivered together with hundreds of others.")
                if index % 3 != 0 { line.translation = "与其他数百行一起送达的一行。" }
                return line
            })
            wait(0.1)
            XCTAssertEqual(distance, 0, accuracy: 1, "A burst of lines while \(active ? "active" : "inactive")")
        }

        // A window that changes size keeps the latest line on its bottom edge.
        for size in [NSSize(width: 560, height: 380), NSSize(width: 900, height: 640), NSSize(width: 760, height: 520)] {
            window.setContentSize(size); wait(0.7)
            XCTAssertEqual(distance, 0, accuracy: 1, "After resizing to \(size)")
            fixture.speak(wait: wait); wait(0.05)
            XCTAssertEqual(distance, 0, accuracy: 1, "Still following after resizing to \(size)")
        }

        // The reader scrolls away with the scroll bar, as an assistive app does: the lines being read stay put.
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        scroller.setAccessibilityValue(NSNumber(value: 0.5)); wait(0.2)
        let reading = offset
        XCTAssertGreaterThan(distance, 1_000)
        for _ in 0..<30 { fixture.speak(wait: wait) }
        wait(0.1)
        XCTAssertEqual(offset, reading, accuracy: 0.5, "New lines must not move a reader who scrolled away")
        // Back at the end, the view follows again.
        scroller.setAccessibilityValue(NSNumber(value: 1)); wait(0.2)
        for _ in 0..<10 { fixture.speak(wait: wait) }
        wait(0.1)
        XCTAssertEqual(distance, 0, accuracy: 1, "Reaching the end resumes following")

        // A session that ends in the background leaves its last line where it was, without the status line.
        fixture.active = false; wait(0.03)
        let listening = height
        fixture.live = nil; fixture.record.status = .completed; wait(0.05)
        fixture.active = true; wait(0.1)
        XCTAssertLessThan(height, listening - 10, "The line that says what the session is doing leaves with the session")
        XCTAssertEqual(distance, 0, accuracy: 1)
    }

    func testASavedTranscriptOpensAtItsFirstLineAndKeepsItsPlace() throws {
        _ = NSApplication.shared
        let fixture = TranscriptFixture()
        fixture.live = nil; fixture.record.status = .completed
        fixture.record.segments = (0..<300).map {
            TranscriptSegment(start: Double($0 * 4), end: Double($0 * 4 + 4), text: "Saved line \($0) of a transcript that is read from its beginning.")
        }
        let host = NSHostingView(rootView: TranscriptFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        wait(0.3)
        scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let top = offset
        XCTAssertGreaterThan(distance, 1_000, "A saved transcript opens at its first line")
        // Translations filling in later, as a retranslation does, leave the first line where it is.
        for index in 0..<40 { fixture.record.segments[index].translation = "后来补上的译文。"; wait(0.005) }
        wait(0.1)
        XCTAssertEqual(offset, top, accuracy: 0.5)
        // The scroll bar can jump anywhere in a long transcript, to lines that were never laid out.
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        for value in [0.3, 0.9, 0.05, 1, 0.5, 0, 0.75, 1, 0] {
            scroller.setAccessibilityValue(NSNumber(value: value)); wait(0.08)
        }
        XCTAssertEqual(offset, top, accuracy: 0.5)
    }

    func testSearchedWordsBringTheirFirstLineIntoView() throws {
        _ = NSApplication.shared
        let fixture = TranscriptFixture()
        fixture.live = nil; fixture.record.status = .completed
        fixture.record.segments = (0..<300).map {
            TranscriptSegment(start: Double($0 * 4), end: Double($0 * 4 + 4), text: "Saved line \($0) of a transcript that is read from its beginning.")
        }
        fixture.record.segments[180].text = "Here the lecturer explains the Subnet mask."
        fixture.record.segments[240].translation = "这里再次提到 subnet。"
        // Opened from a search: the line with the words is already in view.
        fixture.highlight = "subnet"
        let host = NSHostingView(rootView: TranscriptFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        wait(0.5)
        scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let line = height / 300, viewport = scroll.contentView.bounds.height
        XCTAssertEqual(offset + viewport / 2, 180.5 * line, accuracy: line * 3, "The first line with the words rests in the middle of the view")
        // Another search while the transcript is open goes to its own first line; clearing it moves nothing.
        fixture.highlight = "line 42 "; wait(0.4)
        XCTAssertEqual(offset + viewport / 2, 42.5 * line, accuracy: line * 3)
        let place = offset
        fixture.highlight = ""; wait(0.3)
        XCTAssertEqual(offset, place, accuracy: 0.5)
        fixture.highlight = "words that appear nowhere"; wait(0.3)
        XCTAssertEqual(offset, place, accuracy: 0.5)
    }

    private func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
