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
