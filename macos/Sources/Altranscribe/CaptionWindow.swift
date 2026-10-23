import SwiftUI
import AltranscribeCore

/// A floating Liquid Glass panel for captions, kept above other apps and in every Space, like Live Captions.
@MainActor final class CaptionWindow {
    private let panel: NSPanel
    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 200),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.title = L("Altranscribe Captions")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // The panel draws its own controls on hover; the traffic lights would cover the first words.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 130)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: CaptionView(model: model) { [weak self] in self?.panel.orderOut(nil) })
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 380, y: frame.minY + 60))
        }
    }
    func show() { panel.makeKeyAndOrderFront(nil) }
    func updateLanguage() { panel.title = L("Altranscribe Captions") }
}

private struct CaptionView: View {
    @Bindable var model: AppModel
    let close: () -> Void
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "system"
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.phase == .recording ? Color.red : model.phase == .paused ? Color.orange : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(model.isCapturing || model.phase == .finishing ? model.status.text : "Altranscribe")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if hovering {
                    HStack(spacing: 6) {
                        if model.isCapturing {
                            control(model.phase == .paused ? "play.fill" : "pause.fill", help: L("Pause / Resume")) { model.togglePause() }
                            control("stop.fill", help: L("Stop and Save")) { model.stopAndSave() }
                        }
                        control("xmark", help: L("Close")) { close() }
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 26)
            ScrollView {
                captions
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.smooth(duration: 0.25), value: model.currentCaption?.text)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .ignoresSafeArea()
        .onHover { value in withAnimation(.smooth(duration: 0.2)) { hovering = value } }
        .id(interfaceLanguage)
        .environment(\.locale, InterfaceLanguage.current.locale)
    }

    @ViewBuilder private var captions: some View {
        let size = model.settings.captionSize
        let translationOnly = model.settings.captionTranslationOnly
        VStack(alignment: .leading, spacing: size * 0.35) {
            if let segment = model.currentCaption {
                let translated = model.currentCaptionTranslation
                if !translationOnly || translated == nil {
                    Text(segment.text)
                        .font(.system(size: size, weight: .semibold))
                        .textSelection(.enabled)
                }
                if let translated, let translation = translated.translation {
                    if translated.id != segment.id && !translationOnly {
                        Text(L("Translation") + " · " + timestamp(translated.start))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(translation)
                        .font(.system(size: translationOnly ? size : size * 0.92, weight: translationOnly ? .semibold : .regular))
                        .foregroundStyle(translationOnly ? .primary : .secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text(L("Captions appear here when transcription starts."))
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(.fill.secondary, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
