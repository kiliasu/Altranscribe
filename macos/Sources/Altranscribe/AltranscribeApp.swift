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
        .defaultSize(width: 1120, height: 760)
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
                Button(L("Floating Captions")) { model.showCaptions() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView(model: model)
                .id(interfaceLanguage)
                .environment(\.locale, InterfaceLanguage.current.locale)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }
}
