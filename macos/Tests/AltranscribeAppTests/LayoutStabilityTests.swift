import XCTest
import SwiftUI
@testable import Altranscribe
import AltranscribeCore

/// The main window with the inspector open, at narrow and full sizes, on each page and while opening
/// Settings from the home controls. A layout feedback loop makes AppKit raise "more Update Constraints
/// in Window passes than there are views", which XCTest reports here instead of the app crashing.
@MainActor final class LayoutStabilityTests: XCTestCase {
    override func setUp() async throws {
        // Settings pages read API keys; keep them away from the person's real Keychain items.
        KeychainStore.service = "app.altranscribe.mac.api.tests"
    }

    func testMainWindowWithInspectorSettlesAtEachSizeAndPage() throws {
        let sizes = [NSSize(width: 860, height: 600), NSSize(width: 1040, height: 700), NSSize(width: 1316, height: 855)]
        let configurations: [(String, (inout AppSettings) -> Void)] = [
            ("cloud translation", { $0.speechProvider = .compatible; $0.speechBaseURL = "https://api.openai.com/v1"; $0.translate = true }),
            ("missing models", { $0.speechProvider = .whisper; $0.modelPath = ""; $0.summarize = true; $0.textModel = "" })
        ]
        // The inspector's visibility is persisted; set it explicitly so a stored value cannot hide the case.
        let previous = UserDefaults.standard.object(forKey: "showInspector")
        UserDefaults.standard.set(true, forKey: "showInspector")
        defer { UserDefaults.standard.set(previous, forKey: "showInspector") }
        for (name, configure) in configurations {
            for size in sizes {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = AppModel(paths: AppPaths(root: root))
                configure(&model.settings)
                let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(model: model)))
                window.styleMask.insert(.fullSizeContentView) // As in the app's SwiftUI window.
                window.setContentSize(size)
                window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                settle(0.5)
                for (destination, page) in [(Destination.settings, SettingsPage.speech), (.live, nil), (.files, nil),
                                            (.settings, .text), (.live, nil)] {
                    if let page { model.settingsPage = page }
                    model.destination = destination
                    settle(0.6)
                }
                XCTAssertTrue(window.isVisible, "\(name) at \(size)")
            }
        }
    }

    private func settle(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}
