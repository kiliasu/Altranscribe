import XCTest
import SwiftUI
@testable import Altranscribe

@MainActor final class AppearanceTests: XCTestCase {
    func testAppearanceFadeDoesNotInterceptInputOrLeaveStaleOverlays() throws {
        _ = NSApplication.shared
        let previous = NSApp.appearance
        let content = Text("Appearance preview").frame(width: 360, height: 180).background(Color(nsColor: .windowBackgroundColor))
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        AppAppearance.apply("light", animated: false)
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); NSApp.appearance = previous }
        wait(0.15)
        let frame = try XCTUnwrap(window.contentView?.superview)
        let geometry = window.frame
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        AppAppearance.apply("dark", reduceMotion: false)
        wait(0.08)
        let overlay = try XCTUnwrap(frame.subviews.last as? NSImageView, "The old appearance must remain visible during the fade")
        XCTAssertNil(overlay.hitTest(NSPoint(x: 20, y: 20)), "The fade must never consume clicks")
        XCTAssertNotNil(overlay.image)
        let opacity = overlay.layer?.presentation()?.opacity ?? Float(overlay.alphaValue)
        XCTAssertGreaterThan(opacity, 0, "The old appearance should still be visible mid-transition")
        XCTAssertLessThan(opacity, 1, "The transition must interpolate instead of holding then snapping")
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        AppAppearance.apply("light", reduceMotion: false)
        wait(0.05)
        AppAppearance.apply("dark", reduceMotion: false)
        wait(0.4)
        XCTAssertFalse(frame.subviews.contains { $0 is NSImageView }, "Rapid changes must not leave snapshot layers behind")
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(window.frame, geometry, "Changing appearance must not resize the window or native controls")
        AppAppearance.apply("light", reduceMotion: true)
        wait(0.18)
        XCTAssertFalse(frame.subviews.contains { $0 is NSImageView }, "Reduce Motion uses a shorter fade")
        AppAppearance.apply("system")
        wait(0.2)
        XCTAssertNil(NSApp.appearance, "System mode must return appearance control to macOS")
    }

    private func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}
