import SwiftUI
import AltranscribeCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
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

    var body: some Scene {
        Window(L("Altranscribe"), id: "main") {
            ContentView(model: model)
                .id(interfaceLanguage)
                .environment(\.locale, InterfaceLanguage.current.locale)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .onAppear { delegate.model = model }
                .onOpenURL { model.addFiles([$0]) }
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .onChange(of: interfaceLanguage) { _, value in
            Self.updateSystemLanguage(value)
            model.captions?.updateLanguage()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Import Audio or Video…")) { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
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
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
        // Only the page picker sits in the title bar, as in the main window's Settings page. (SwiftUI applies the
        // hidden title here but keeps the preference toolbar style; SettingsView switches the window to unified.)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
