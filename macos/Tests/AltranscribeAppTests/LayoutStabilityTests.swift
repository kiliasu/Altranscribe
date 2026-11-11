import XCTest
import SwiftUI
import OSLog
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
                var record = TranscriptRecord(title: "Saved lecture", source: .file, language: "en", speechModel: "nemotron-en-0.6b")
                record.segments = [TranscriptSegment(start: 0, end: 4, text: "A saved line with a translation")]
                record.segments[0].translation = "一句带译文的已保存文本"
                record.status = .completed
                model.records = [record]
                let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(model: model)))
                window.styleMask.insert(.fullSizeContentView) // As in the app's SwiftUI window.
                window.setContentSize(size)
                window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                settle(0.5)
                for (destination, page) in [(Destination.settings, SettingsPage.speech), (.live, nil), (.files, nil),
                                            (.transcript(record.id), nil), (.settings, .text), (.live, nil)] {
                    if let page { model.settingsPage = page }
                    model.destination = destination
                    settle(0.6)
                }
                XCTAssertTrue(window.isVisible, "\(name) at \(size)")
            }
        }
    }

    func testFileProgressPageSettlesAtEachSize() throws {
        let previous = UserDefaults.standard.object(forKey: "showInspector")
        UserDefaults.standard.set(true, forKey: "showInspector")
        defer { UserDefaults.standard.set(previous, forKey: "showInspector") }
        for size in [NSSize(width: 860, height: 600), NSSize(width: 1316, height: 855)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(paths: AppPaths(root: root))
            model.settings.translate = true; model.settings.summarize = true; model.settings.textModel = "test-model"
            var record = TranscriptRecord(title: "Lecture", source: .file, language: "en", speechModel: "nemotron-en-0.6b")
            record.segments = (0..<12).map { TranscriptSegment(start: Double($0) * 5, end: Double($0) * 5 + 5, text: "Line \($0) of a long lecture recording") }
            model.records = [record]
            var item = QueuedFile(url: root.appendingPathComponent("A very long lecture file name for the queue.m4a"))
            item.status = .processing; item.recordID = record.id
            model.queue = [item, QueuedFile(url: root.appendingPathComponent("next.wav"))]
            model.queueRunning = true; model.phase = .files
            var run = FileRun(recordID: record.id, fileName: item.url.lastPathComponent, duration: 1_800, configuration: model.settings)
            run.processed = 60
            model.fileRun = run
            model.destination = .files
            let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(model: model)))
            window.styleMask.insert(.fullSizeContentView)
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            settle(0.6)
            for stage: FileRun.Stage in [.translating, .summarizing, .transcribing] {
                model.fileRun?.stage = stage
                model.fileRun?.processed += 120
                settle(0.4)
            }
            XCTAssertTrue(window.isVisible, "files at \(size)")
        }
    }

    /// A session's transcript on the live page, over each state of the bar under it, while the window is
    /// resized down to its minimum and back. The bar's size feeds the minimum width of the window's columns:
    /// a bar that reported more than it needs made the window require more room than its minimum size
    /// allows, and AppKit looped through layout passes until it stopped the app.
    func testLivePageSettlesWhileTheWindowResizes() throws {
        let previous = UserDefaults.standard.object(forKey: "showInspector")
        UserDefaults.standard.set(true, forKey: "showInspector")
        defer { UserDefaults.standard.set(previous, forKey: "showInspector") }
        // Idle after a finished session is the bar's widest state; recording and paused are its busiest.
        for phase: SessionPhase in [.idle, .recording, .paused, .finishing] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(paths: AppPaths(root: root))
            model.settings.translate = true
            var record = TranscriptRecord(title: "Session", source: .microphone, language: "en", speechModel: "fixture")
            record.targetLanguage = "zh"
            record.segments = (0..<80).map { index in
                var line = TranscriptSegment(start: Double(index) * 6, end: Double(index) * 6 + 6,
                                             text: "Line \(index) of a session whose transcript stays on the live page after it ends.")
                line.translation = "会话结束后仍留在实时页面上的文稿的第 \(index) 行。"
                return line
            }
            model.records = [record]; model.activeRecordID = record.id
            model.phase = phase; model.destination = .live
            let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(model: model)))
            window.styleMask.insert(.fullSizeContentView)
            window.setContentSize(NSSize(width: 1180, height: 780))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            settle(0.5)
            for size in [NSSize(width: 900, height: 640), NSSize(width: 860, height: 600), NSSize(width: 1316, height: 855),
                         NSSize(width: 860, height: 600), NSSize(width: 1000, height: 700)] {
                window.setContentSize(size)
                settle(0.4)
                // Text keeps arriving while the window changes size.
                if phase == .recording { model.records[0].segments.append(TranscriptSegment(start: 600, end: 606, text: "Another line.")) }
                settle(0.2)
            }
            XCTAssertTrue(window.isVisible, "\(phase)")
        }
    }

    /// Changing pages animates. A transition that scales a page also resizes every AppKit control on it (text
    /// fields, segmented pickers, switches, progress indicators) on each frame, and SwiftUI reports those sizes as
    /// invalid. In the app's own window that resizing, with the inspector moving beside it, kept the layout from
    /// settling until AppKit stopped the app. The loop itself needs the app's scene window, so this checks for its
    /// cause: no control may be resized while the window moves between pages.
    func testChangingPagesNeverResizesAppKitControls() throws {
        let start = Date()
        let previous = UserDefaults.standard.object(forKey: "showInspector")
        UserDefaults.standard.set(true, forKey: "showInspector")
        defer { UserDefaults.standard.set(previous, forKey: "showInspector") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root))
        // The configuration of the crash. The default local text service also makes the Text page load its model
        // list, which shows a progress indicator.
        model.settings.speechProvider = .compatible
        model.settings.speechBaseURL = "https://api.openai.com/v1"
        model.settings.translate = true
        model.settings.cloudDirectTranslation = false
        let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(model: model)))
        window.styleMask.insert(.fullSizeContentView)
        window.setContentSize(NSSize(width: 1316, height: 855))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(0.5)
        for (destination, page) in [(Destination.settings, SettingsPage.speech), (.live, nil), (.settings, .text),
                                    (.files, nil), (.settings, .general), (.live, nil)] {
            if let page { model.settingsPage = page }
            model.destination = destination
            settle(0.6)
        }
        // Home menus appear and disappear as the chosen engine and text processing change.
        model.settings.translate = false; model.settings.speechProvider = .nemotron
        settle(0.6)
        model.settings.translate = true; model.settings.speechProvider = .compatible
        settle(0.6)
        // The Files page hands its drop zone over to the queue and back.
        model.addFiles([root.appendingPathComponent("lecture.m4a")])
        settle(0.6)
        model.queue[0].recordID = UUID()
        for status: QueueStatus in [.processing, .completed, .failed] {
            model.queue[0].status = status
            settle(0.6)
        }
        model.queue.map(\.id).forEach(model.removeQueued)
        settle(0.6)
        let faults = try invalidSizeReports(since: start)
        XCTAssertTrue(faults.isEmpty, "SwiftUI reported \(faults.count) invalid control sizes while changing pages, such as: \(faults.prefix(2))")
    }

    /// SwiftUI's reports, in this process's log, of AppKit controls given a size outside their own limits.
    private func invalidSizeReports(since start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let filter = NSPredicate(format: "subsystem == %@ AND category == %@", "com.apple.SwiftUI", "Invalid Configuration")
        return try store.getEntries(at: store.position(date: start), matching: filter)
            .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
            .filter { $0.contains("doesn't satisfy") }
    }

    private func settle(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}
