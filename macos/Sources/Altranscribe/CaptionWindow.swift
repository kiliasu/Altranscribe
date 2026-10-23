import SwiftUI
import AltranscribeCore

@MainActor final class CaptionWindow {
    private let panel: NSPanel
    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 190),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.title = L("Altranscribe Captions")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 400, height: 130)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = NSHostingView(rootView: CaptionView(model: model))
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 360, y: frame.minY + 60))
        }
    }
    func show() { panel.makeKeyAndOrderFront(nil) }
    func updateLanguage() { panel.title = L("Altranscribe Captions") }
}

private struct CaptionView: View {
    @Bindable var model: AppModel
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "system"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.phase == .paused ? L("Paused") : "Altranscribe", systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.phase == .recording || model.phase == .paused {
                    Button { model.togglePause() } label: { Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill") }
                        .help(L("Pause / Resume"))
                    Button { model.stopAndSave() } label: { Image(systemName: "stop.fill") }
                        .help(L("Stop and Save"))
                }
            }.padding(.leading, 54)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let segment = model.currentCaption {
                        let translated = model.currentCaptionTranslation
                        if !model.settings.captionTranslationOnly || translated == nil {
                            Text(segment.text).font(.system(size: model.settings.captionSize, weight: .medium)).textSelection(.enabled)
                        }
                        if let translated, let translation = translated.translation {
                            if translated.id != segment.id && !model.settings.captionTranslationOnly {
                                Text(L("Translation") + " · " + timestamp(translated.start))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(translation).font(.system(size: model.settings.captionSize)).foregroundStyle(model.settings.captionTranslationOnly ? .primary : .secondary).textSelection(.enabled)
                        }
                    } else {
                        Text(L("Captions appear here when transcription starts."))
                            .font(.system(size: model.settings.captionSize)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .ignoresSafeArea()
        .id(interfaceLanguage)
        .environment(\.locale, InterfaceLanguage.current.locale)
    }
}
