import XCTest
import SwiftUI
@testable import Altranscribe
import AltranscribeCore

@MainActor final class TransportLayoutTests: XCTestCase {
    func testAudioSourceTransitionKeepsSelectionFocusAndGeometry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root))
        let window = NSWindow(contentViewController: NSHostingController(rootView: TransportBar(model: model).padding(20)))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        func findPicker(_ view: NSView) -> NSSegmentedControl? {
            (view as? NSSegmentedControl) ?? view.subviews.compactMap(findPicker).first
        }
        let control = try XCTUnwrap(findPicker(try XCTUnwrap(window.contentView)))
        let frame = control.frame
        XCTAssertTrue(window.makeFirstResponder(control))
        let responder = window.firstResponder
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.24
        for index in [1, 0, 1] {
            control.selectedSegment = index
            control.sendAction(control.action, to: control.target)
            XCTAssertEqual(model.source, index == 0 ? .microphone : .system)
            let fade = try XCTUnwrap(control.layer?.animation(forKey: kCATransition) as? CATransition)
            XCTAssertEqual(fade.type, .fade)
            XCTAssertEqual(fade.duration, duration)
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            XCTAssertTrue(window.firstResponder === responder, "Changing source must keep keyboard focus on the existing control")
            XCTAssertEqual(control.frame, frame, "The source transition must not resize native controls")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(control.layer?.animation(forKey: kCATransition))
        let coordinator = try XCTUnwrap(control.target as? AudioSourcePicker.Coordinator)
        coordinator.reduceMotion = true
        control.selectedSegment = 0
        control.sendAction(control.action, to: control.target)
        XCTAssertEqual(control.layer?.animation(forKey: kCATransition)?.duration, 0.1)
        model.queueRunning = true
        model.phase = .files
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(control.isEnabled, "A busy file queue must still lock the live source selector")
        XCTAssertEqual(control.accessibilityLabel(), L("Audio Source"))
    }

    /// The bars report their size to the window, whose columns take their minimum widths from it. A bar
    /// that asks for more than `ViewThatFits` did makes the window need more room than its minimum size
    /// allows, and AppKit then loops through layout passes until it stops the app.
    func testBarLayoutReportsTheSizesOfTheArrangementsItReplaces() throws {
        struct Status: View {
            var body: some View {
                HStack(spacing: 10) {
                    Color.red.frame(width: 9, height: 9)
                    Text("12:34").monospacedDigit()
                    Text("A status that can be truncated when the bar is narrow").lineLimit(1)
                }
            }
        }
        struct Actions: View {
            var body: some View {
                HStack(spacing: 8) {
                    Text("A device name that shortens").lineLimit(1).frame(minWidth: 60)
                    Color.blue.frame(width: 120, height: 28)
                }
            }
        }
        let bar = NSHostingController(rootView: BarLayout { HStack(spacing: 0) { Status() }; HStack(spacing: 0) { Actions() } })
        let reference = NSHostingController(rootView: ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { Status(); Spacer(minLength: 16); Actions() }
            VStack(spacing: 12) { Status(); Actions() }
        })
        // Zero is what the window asks to learn the least a bar can be.
        var proposals = [CGSize.zero, CGSize(width: 10_000, height: 10_000)]
        proposals += stride(from: 40.0, through: 900, by: 20).map { CGSize(width: $0, height: 200) }
        for proposal in proposals {
            let size = bar.sizeThatFits(in: proposal), expected = reference.sizeThatFits(in: proposal)
            XCTAssertEqual(size.width, expected.width, accuracy: 0.5, "Width when offered \(proposal)")
            XCTAssertEqual(size.height, expected.height, accuracy: 0.5, "Height when offered \(proposal)")
        }
        // A group with nothing in it takes no room, on one line or stacked.
        let lone = NSHostingController(rootView: BarLayout { HStack(spacing: 0) { EmptyView() }; HStack(spacing: 0) { Actions() } })
        let alone = NSHostingController(rootView: Actions())
        for width in [80.0, 200, 600] {
            let proposal = CGSize(width: width, height: 200)
            XCTAssertEqual(lone.sizeThatFits(in: proposal).height, alone.sizeThatFits(in: proposal).height, accuracy: 0.5)
        }
    }

    func testRecordingControlsFitTheMinimumDetailColumn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root))
        model.settings.translate = true
        model.phase = .recording
        let view = NSHostingController(rootView: TransportBar(model: model).padding(.horizontal, 20))
        // 860-point window minus the 220-point sidebar and 250-point inspector.
        let minimum = view.sizeThatFits(in: CGSize(width: 390, height: 200))
        let wide = view.sizeThatFits(in: CGSize(width: 800, height: 200))
        XCTAssertGreaterThan(minimum.width, 100)
        XCTAssertGreaterThan(minimum.height, wide.height, "Narrow windows must place controls on two rows")
        XCTAssertLessThanOrEqual(minimum.width, 390, "The transport must not force the split view wider during live translation")
    }
}
