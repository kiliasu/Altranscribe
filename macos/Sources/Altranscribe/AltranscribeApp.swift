import SwiftUI
import AltranscribeCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.apply(UserDefaults.standard.string(forKey: "appearance") ?? "system", animated: false)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("A task is still running")
        alert.informativeText = L("Quitting stops processing. Text already saved will be retained.")
        alert.addButton(withTitle: L("Keep Working"))
        alert.addButton(withTitle: L("Stop and Quit"))
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.cancel()
        Task {
            while model.busy { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct AltranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "system"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("transcriptTextSize") private var textSize = 15.0

    init() {
        Self.updateSystemLanguage(UserDefaults.standard.string(forKey: InterfaceLanguage.preferenceKey) ?? "system")
    }
    private static func updateSystemLanguage(_ value: String) {
        if value == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else if let language = InterfaceLanguage(rawValue: value) {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    private var selectedTranscript: UUID? {
        if case .transcript(let id) = model.destination { return id }
        return nil
    }
    private func selectedRecord() -> TranscriptRecord? {
        selectedTranscript.flatMap { id in model.records.first { $0.id == id } }
    }

    var body: some Scene {
        Window(L("Altranscribe"), id: "main") {
            ContentView(model: model)
                .id(interfaceLanguage)
                .environment(\.locale, InterfaceLanguage.current.locale)
                .onAppear { delegate.model = model }
                .onOpenURL { model.addFiles([$0]) }
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .onChange(of: interfaceLanguage) { _, value in
            Self.updateSystemLanguage(value)
            model.captions?.updateLanguage()
        }
        .onChange(of: appearance) { _, value in AppAppearance.apply(value) }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Import Audio or Video…")) { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
            // The selected transcript's commands, as its toolbar and the sidebar's menu offer them. They are
            // enabled by which transcript is selected; its text, which changes with every word of a running
            // session, is only looked up when a command is chosen.
            CommandGroup(replacing: .saveItem) {
                Button(L("Copy Transcript")) { if let record = selectedRecord() { model.copy(record) } }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(selectedTranscript == nil)
                Menu(L("Export")) {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title + "…") { if let record = selectedRecord() { model.export(record, format: format) } }
                    }
                }
                .disabled(selectedTranscript == nil)
                Divider()
                Button(L("Rename…")) { model.renamingRecordID = selectedTranscript }
                    .disabled(selectedTranscript == nil || model.busy)
                Button(L("Generate Summary")) { if let record = selectedRecord() { model.postProcess(record, summary: true) } }
                    .disabled(selectedTranscript == nil || model.busy)
                Button(L("Translate Transcript")) { if let record = selectedRecord() { model.postProcess(record, summary: false) } }
                    .disabled(selectedTranscript == nil || model.busy)
                Divider()
                // No shortcut: ⌘⌫ belongs to the text being edited, a title or the search. The Delete key
                // deletes the transcript selected in the sidebar.
                Button(L("Delete Transcript…")) { model.pendingDeletion = selectedTranscript }
                    .disabled(selectedTranscript == nil || model.busy)
            }
            // There is no help book; the Help menu keeps its search field.
            CommandGroup(replacing: .help) { }
            CommandGroup(before: .toolbar) {
                Button(L("Live Transcription")) { model.destination = .live }
                    .keyboardShortcut("1")
                Button(L("File Transcription")) { model.destination = .files }
                    .keyboardShortcut("2")
                Divider()
                Button(L("Make Text Bigger")) { textSize = min(28, textSize + 1) }
                    .keyboardShortcut("+")
                Button(L("Make Text Smaller")) { textSize = max(11, textSize - 1) }
                    .keyboardShortcut("-")
                Button(L("Make Text Normal Size")) { textSize = 15 }
                    .keyboardShortcut("0")
                Divider()
            }
            SidebarCommands()
            InspectorCommands()
            CommandMenu(L("Transcription")) {
                Button(L("Start Transcription")) { model.startLive() }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.busy)
                Button(L("Pause / Resume")) { model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.phase != .recording && model.phase != .paused)
                Button(L("Stop and Save")) { model.stopAndSave() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.phase != .recording && model.phase != .paused)
                Divider()
                Toggle(L("Floating Captions"), isOn: $model.captionsVisible)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView(model: model)
                .id(interfaceLanguage)
                .environment(\.locale, InterfaceLanguage.current.locale)
        }
        // Only the page picker sits in the title bar, as in the main window's Settings page. (SwiftUI applies the
        // hidden title here but keeps the preference toolbar style; SettingsView switches the window to unified.)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
