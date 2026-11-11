import XCTest
import SwiftUI
@testable import Altranscribe
import AltranscribeCore

@MainActor final class SettingsNavigationTests: XCTestCase {
    override func setUp() async throws {
        // Settings pages read API keys; keep them away from the person's real Keychain items.
        KeychainStore.service = "app.altranscribe.mac.api.tests"
    }

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

    /// Opening Settings in the main window hides the inspector, and the hiding finishes a moment later. Leaving
    /// Settings before then must neither turn the saved inspector preference off nor leave the inspector closed.
    func testLeavingSettingsQuicklyKeepsTheInspector() throws {
        let previous = UserDefaults.standard.object(forKey: "showInspector")
        UserDefaults.standard.set(true, forKey: "showInspector")
        defer { UserDefaults.standard.set(previous, forKey: "showInspector") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root))
        let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(model: model)))
        window.styleMask.insert(.fullSizeContentView)
        window.setContentSize(NSSize(width: 1316, height: 855))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        wait(0.6)
        XCTAssertTrue(inspectorIsOpen(in: window))
        for destination in [Destination.live, .files, .live] {
            model.destination = .settings
            wait(0.3)
            model.destination = destination
            wait(1.2)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: "showInspector"), "Saved preference after leaving Settings for \(destination)")
            XCTAssertTrue(inspectorIsOpen(in: window), "Inspector after leaving Settings for \(destination)")
        }
    }

    private func inspectorIsOpen(in window: NSWindow) -> Bool {
        views(in: window).contains {
            String(describing: type(of: $0)).contains("InspectorStyleContext") && !$0.isHiddenOrHasHiddenAncestor
                && $0.visibleRect.width > 100
        }
    }

    private func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

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
