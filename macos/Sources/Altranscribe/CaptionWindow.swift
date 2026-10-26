import SwiftUI
import Observation
import AltranscribeCore

/// A floating Liquid Glass panel for captions, kept above other apps and in every Space, like Live Captions.
@MainActor @Observable final class CaptionWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private(set) var isVisible = false
    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 200),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
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
        panel.contentView = NSHostingView(rootView: CaptionView(model: model) { [weak self] in self?.hide() })
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 380, y: frame.minY + 60))
        }
    }
    /// The panel fades in where it was left, and fades out before it leaves the screen.
    func show() {
        isVisible = true
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }
    func hide() {
        isVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Showing it again mid-fade wins over the fade-out.
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        }
    }
    func windowWillClose(_ notification: Notification) { isVisible = false }
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
                    .contentTransition(.opacity)
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
            .animation(Motion.quick, value: model.phase)
            ScrollView {
                captions
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A new sentence rises in as the previous one lifts away; a sentence that grows stays put.
                    .animation(Motion.content, value: model.currentCaption?.id)
                    .animation(Motion.content, value: model.currentCaptionTranslation?.id)
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
        .onHover { value in withAnimation(Motion.quick) { hovering = value } }
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
                    // Each slot is a ZStack, so the outgoing and incoming sentence share one place while they cross.
                    ZStack(alignment: .topLeading) {
                        Text(segment.text)
                            .font(.system(size: size, weight: .semibold))
                            .textSelection(.enabled)
                            .id(segment.id)
                            .transition(.rise)
                    }
                }
                if let translated, let translation = translated.translation {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 4) {
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
                        .id(translated.id)
                        .transition(.rise)
                    }
                }
            } else {
                Text(L("Captions appear here when transcription starts."))
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
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
