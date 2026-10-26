import XCTest
import SwiftUI
@testable import Altranscribe
import AltranscribeCore

@MainActor final class SettingsNavigationTests: XCTestCase {
    func testChangingSettingsPagesKeepsTheToolbarAndScrollContainer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root))
        let host = NSHostingController(rootView: SettingsView(model: model, embedded: true))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 700, height: 620))
        window.orderFront(nil)
        defer { window.close() }
        settle()

        let original = try XCTUnwrap(views(in: window).compactMap { $0 as? NSSegmentedControl }.first)
        let scroll = try XCTUnwrap(views(in: window).compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(original.segmentCount, 3)
        for page in [SettingsPage.speech, .text, .general, .text, .speech] {
            model.settingsPage = page
            settle()
            let current = try XCTUnwrap(views(in: window).compactMap { $0 as? NSSegmentedControl }.first)
            XCTAssertTrue(current === original, "Changing the page must not recreate the toolbar control")
            XCTAssertTrue(views(in: window).compactMap { $0 as? NSScrollView }.first === scroll,
                          "Changing the page must keep the scroll container that supplies the toolbar edge effect")
        }
    }

    private func views(in window: NSWindow) -> [NSView] {
        func descendants(of view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants(of: $0) }
        }
        return window.contentView?.superview.map { descendants(of: $0) } ?? []
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}
