import SwiftUI
import Observation
import AltranscribeCore

/// A floating Liquid Glass panel for captions, kept above other apps and in every Space, like Live Captions.
@MainActor @Observable final class CaptionWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private(set) var isVisible = false
    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 340),
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
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.25
            panel.animator().alphaValue = 1
        }
    }
    func hide() {
        isVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.2
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var showingOptions = false
    @State private var contentHeight: CGFloat = 0

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
                control("textformat.size", help: L("Caption Settings")) { showingOptions.toggle() }
                    .popover(isPresented: $showingOptions) {
                        Form { CaptionControls(model: model) }
                            .formStyle(.grouped)
                            .frame(width: 350, height: 210)
                    }
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
            .animation(Motion.quick, value: model.status)
            if !model.captionSegments.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: model.settings.captionSize * 0.55) {
                            ForEach(model.captionSegments) { segment in
                                captions(segment)
                                    .transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)),
                                                            removal: .opacity.animation(.easeOut(duration: 0.1))))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("caption-bottom")
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .smooth(duration: 0.55), value: model.captionSegments.map(\.id))
                    }
                    .defaultScrollAnchor(.bottom)
                    .defaultScrollAnchor(.top, for: .sizeChanges)
                    .defaultScrollAnchor(.top, for: .alignment)
                    .scrollIndicators(.never)
                    .task(id: contentHeight) {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.55)) {
                            proxy.scrollTo("caption-bottom", anchor: .bottom)
                        }
                    }
                }
            } else {
                Text(L("Captions appear here when transcription starts."))
                    .font(.system(size: model.settings.captionSize * 0.8))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(Motion.content, value: model.currentCaption == nil)
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .ignoresSafeArea()
        .onHover { value in withAnimation(Motion.quick) { hovering = value } }
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
        .id(interfaceLanguage)
        .environment(\.locale, InterfaceLanguage.current.locale)
    }

    @ViewBuilder private func captions(_ segment: TranscriptSegment) -> some View {
        let size = model.settings.captionSize
        let translationOnly = model.settings.captionTranslationOnly
        let current = segment.id == model.currentCaption?.id
        VStack(alignment: .leading, spacing: size * 0.25) {
            if !translationOnly || segment.translation == nil {
                StreamingText(segment.text, active: current)
                    .font(.system(size: size, weight: .semibold))
                    .textSelection(.enabled)
            }
            if let translation = segment.translation {
                if segment.translationIsProvisional == true {
                    Text(L("Provisional translation")).font(.caption).foregroundStyle(.tertiary).transition(.opacity)
                }
                StreamingText(translation, active: current)
                    .font(.system(size: translationOnly ? size : size * 0.92, weight: translationOnly ? .semibold : .regular))
                    .foregroundStyle(translationOnly ? .primary : .secondary)
                    .textSelection(.enabled)
            } else if model.isTranslationPending(segment.id) {
                Text(L("Translating…")).font(.caption).foregroundStyle(.secondary).transition(.opacity)
            } else if let error = segment.translationError {
                Text(error.text).font(.caption).foregroundStyle(.orange).transition(.opacity)
            }
        }
        .animation(Motion.content, value: segment.translation != nil)
        .animation(Motion.quick, value: segment.translationIsProvisional)
        .animation(Motion.quick, value: translationOnly)
        .modifier(SentenceEmphasis(current: current))
    }

    /// Standard circular buttons on the glass panel, so the system draws their fill, press state and focus.
    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 10, weight: .bold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help(help)
        .accessibilityLabel(help)
    }
}
