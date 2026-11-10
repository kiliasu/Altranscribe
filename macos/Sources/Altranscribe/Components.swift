import SwiftUI
import AltranscribeCore

/// Lays its children out like words in a paragraph, wrapping onto new lines when the row is full.
/// Children keep their ideal size; only one wider than a whole row is offered the row's width, so it
/// truncates or wraps on a row of its own instead of overflowing.
struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private struct Row { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, in: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        // With a definite width, take all of it and align the rows inside, so placement uses the width
        // that was measured. The minimum-size probe (width zero) answers zero too, so a long child never
        // raises the minimum width of the column around the layout.
        if let width = proposal.width, width.isFinite { return CGSize(width: max(width, 0), height: height) }
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = alignment == .center ? bounds.minX + (bounds.width - row.width) / 2 : bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            // A zero width is SwiftUI asking for the minimum size. Answering with text wrapped one word per
            // line demanded a towering minimum height; outside a scroll view that reached the window's
            // constraints and AppKit looped through layout passes. Keep each child whole on its own row.
            if width > 0, width.isFinite, size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            rows[rows.count - 1].width += (rows[rows.count - 1].items.isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            rows[rows.count - 1].items.append((index, size))
        }
        return rows
    }
}

/// One corner radius per kind of surface in the content layer, so neighbouring shapes read as one family.
/// Grouped content (a summary, a notice) matches the grouped Form sections beside it; a whole region is rounder.
enum Radius {
    static let group: CGFloat = 12
    static let region: CGFloat = 18
}

/// A bar's two groups of controls: one at each edge of a line, or one above the other where the line is
/// too narrow. It answers with the sizes `ViewThatFits` gives for those two arrangements, so the columns
/// of the window keep the minimum widths they had, but it holds the controls once. `ViewThatFits` builds
/// an arrangement to measure it, and the window measures its content again after every update: while
/// recording, that built and discarded a second bar for each new word and each frame of an animation.
struct BarLayout: Layout {
    /// The least room between the groups on one line: a spacer of 16 points with 16 on each side of it.
    var spacing: CGFloat = 48
    var lineSpacing: CGFloat = 12

    /// Each group's size by the width it was offered; `nil` is its ideal size. AppKit controls work their
    /// size out through Auto Layout every time they are asked. SwiftUI discards this when a group changes.
    func makeCache(subviews: Subviews) -> [CGFloat?: [CGSize]] { [:] }

    private func sizes(_ subviews: Subviews, in width: CGFloat?, cache: inout [CGFloat?: [CGSize]]) -> [CGSize] {
        if let known = cache[width] { return known }
        let sizes = subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard let width, ideal.width > width else { return ideal }
            // Narrower than the group would like to be: it wraps or truncates, or answers with the least
            // it can be, and that answer stands. A width of zero is the window asking for the minimum
            // size, so the group is asked for its own. Reporting less would let the window shrink to a
            // width its columns cannot be laid out in; reporting more makes it demand space it does
            // not have. AppKit ends either by stopping the app.
            return subview.sizeThatFits(width == 0 ? .zero : ProposedViewSize(width: width, height: nil))
        }
        cache[width] = sizes
        return sizes
    }
    /// A group with nothing in it, such as a status with nothing to say, takes no spacing.
    private func gaps(_ sizes: [CGSize]) -> CGFloat {
        CGFloat(max(0, sizes.filter { $0.width > 0 || $0.height > 0 }.count - 1))
    }
    /// The width of the groups side by side, which is the least a single line can be.
    private func line(_ ideal: [CGSize]) -> CGFloat {
        ideal.reduce(0) { $0 + $1.width } + spacing * gaps(ideal)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGFloat?: [CGSize]]) -> CGSize {
        let ideal = sizes(subviews, in: nil, cache: &cache)
        let line = line(ideal)
        guard let width = proposal.width, width < line else {
            // One line takes all the width it is offered, so the groups reach both edges.
            return CGSize(width: max(proposal.width ?? line, line), height: ideal.map(\.height).max() ?? 0)
        }
        let stacked = sizes(subviews, in: width, cache: &cache)
        return CGSize(width: stacked.map(\.width).max() ?? 0,
                      height: stacked.reduce(0) { $0 + $1.height } + lineSpacing * gaps(stacked))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGFloat?: [CGSize]]) {
        let ideal = sizes(subviews, in: nil, cache: &cache)
        if bounds.width >= line(ideal) {
            // What is left of the line goes between the groups: two groups meet the two edges.
            let free = bounds.width - ideal.reduce(0) { $0 + $1.width }
            let gap = subviews.count > 1 ? free / CGFloat(subviews.count - 1) : 0
            var x = bounds.minX
            for (subview, size) in zip(subviews, ideal) {
                subview.place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(size))
                x += size.width + gap
            }
        } else {
            var y = bounds.minY
            for (subview, size) in zip(subviews, sizes(subviews, in: bounds.width, cache: &cache)) {
                subview.place(at: CGPoint(x: bounds.midX - size.width / 2, y: y), proposal: ProposedViewSize(size))
                if size.width > 0 || size.height > 0 { y += size.height + lineSpacing }
            }
        }
    }
}

/// A dot that pulses while something is live. Core Animation runs the pulse in the window server, so it
/// costs the app nothing per frame. An animation SwiftUI steps itself updates this window's layout on
/// every frame, which kept half a processor core busy for as long as a recording lasted.
struct PulsingDot: NSViewRepresentable {
    var color: NSColor
    var pulsing: Bool
    var diameter: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> DotView { DotView() }
    func updateNSView(_ view: DotView, context: Context) {
        view.color = color
        view.pulsing = pulsing && !reduceMotion
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }

    final class DotView: NSView {
        private let dot = CALayer()
        var color = NSColor.systemRed { didSet { if color != oldValue { needsDisplay = true } } }
        var pulsing = false { didSet { if pulsing != oldValue { updatePulse() } } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            // Resolved while AppKit draws, so the color follows the window's light or dark appearance.
            dot.backgroundColor = color.cgColor
        }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.frame = bounds; dot.cornerRadius = bounds.height / 2
            CATransaction.commit()
        }
        // A layer loses its animations when its view leaves a window, as recycled list rows do.
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updatePulse() }

        private func updatePulse() {
            dot.removeAnimation(forKey: "pulse")
            guard pulsing, window != nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.35
            pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.isRemovedOnCompletion = false
            dot.add(pulse, forKey: "pulse")
        }
    }
}

/// A symbol that shows work in progress by lighting its layers in turn. AppKit's image view runs the
/// effect in Core Animation. The same effect on a SwiftUI image is stepped by SwiftUI, and each step
/// lays this window out again: half a processor core for as long as the symbol is on screen.
struct ActivitySymbol: NSViewRepresentable {
    var name: String
    var animating: Bool
    var pointSize: CGFloat
    var side: CGFloat

    func makeNSView(context: Context) -> SymbolView { SymbolView() }
    func updateNSView(_ view: SymbolView, context: Context) {
        view.show(name, pointSize: pointSize)
        view.animating = animating
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SymbolView, context: Context) -> CGSize? {
        CGSize(width: side, height: side)
    }

    final class SymbolView: NSImageView {
        private var shown: (name: String, pointSize: CGFloat)?
        var animating = false { didSet { if animating != oldValue { updateEffect() } } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            imageScaling = .scaleNone
            contentTintColor = .tertiaryLabelColor
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }

        func show(_ name: String, pointSize: CGFloat) {
            guard shown?.name != name || shown?.pointSize != pointSize else { return }
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
            // One symbol gives way to the next; the first one, and a new size, simply appear.
            if let image, shown != nil, shown?.name != name, window != nil { setSymbolImage(image, contentTransition: .replace) }
            else { self.image = image }
            shown = (name, pointSize)
        }
        // An effect stops when its view leaves a window, as a row of a lazy stack does.
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateEffect() }

        private func updateEffect() {
            removeAllSymbolEffects(animated: false)
            if animating, window != nil { addSymbolEffect(.variableColor.iterative, options: .repeating) }
        }
    }
}

/// The last moments of input level, scrolling from right to left like the meter in Voice Memos.
/// A level arrives with every audio buffer, about ten times a second for as long as a session lasts.
/// The view follows the model itself and resizes its own layers, so a new level never becomes a SwiftUI
/// update, each of which lays this window out again. Core Animation eases every bar to its new height.
struct LevelMeter: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> MeterView { MeterView(model: model) }
    func updateNSView(_ view: MeterView, context: Context) { }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeterView, context: Context) -> CGSize? { MeterView.size }

    final class MeterView: NSView {
        private static let count = 26, bar: CGFloat = 2.5, gap: CGFloat = 2
        static let size = CGSize(width: CGFloat(count) * (bar + gap) - gap, height: 20)

        private let model: AppModel
        private var levels = [Float](repeating: 0, count: count)
        private let bars = (0..<count).map { _ in CALayer() }
        private var following = false
        private var visible = false
        private var occlusion: NSObjectProtocol?

        init(model: AppModel) {
            self.model = model
            super.init(frame: NSRect(origin: .zero, size: Self.size))
            wantsLayer = true
            for bar in bars { bar.cornerRadius = Self.bar / 2; layer?.addSublayer(bar) }
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel(L("Input Level"))
        }
        required init?(coder: NSCoder) { nil }

        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            // Resolved while AppKit draws, so the bars follow the window's light or dark appearance.
            let color = NSColor.secondaryLabelColor.cgColor
            for bar in bars { bar.backgroundColor = color }
        }
        override func layout() { super.layout(); arrange(animated: false) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
            occlusion = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateVisibility() }
                }
            }
            updateVisibility()
            follow()
        }

        /// A window that is hidden, minimized or covered needs no bars moved; it shows the latest ones when it returns.
        private func updateVisibility() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            guard visible != self.visible else { return }
            self.visible = visible
            if visible { arrange(animated: false) }
        }

        /// Observation reports the next change once, so ask again after each one, while in a window.
        private func follow() {
            guard !following, window != nil else { return }
            following = true
            withObservationTracking {
                _ = model.meter; _ = model.phase
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.following = false
                    self.advance()
                    self.follow()
                }
            }
        }

        private func advance() {
            if model.phase == .recording {
                levels.removeFirst()
                levels.append(model.meter)
            } else {
                levels = levels.map { _ in 0 }
            }
            if visible { arrange(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
        }

        private func arrange(animated: Bool) {
            CATransaction.begin()
            if animated {
                CATransaction.setAnimationDuration(0.1)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            } else {
                CATransaction.setDisableActions(true)
            }
            for (index, level) in levels.enumerated() {
                let height = 3 + CGFloat(min(1, max(0, level))) * 17
                bars[index].frame = CGRect(x: CGFloat(index) * (Self.bar + Self.gap), y: (bounds.height - height) / 2,
                                           width: Self.bar, height: height)
            }
            CATransaction.commit()
        }
    }
}
/// The commands for one saved transcript, shared by its toolbar, the sidebar's context menu and the menu bar.
struct RecordActions: View {
    let model: AppModel
    let record: TranscriptRecord
    var includesSharing = true

    var body: some View {
        if includesSharing {
            Button(L("Copy Transcript"), systemImage: "doc.on.doc") { model.copy(record) }
            ExportMenu(model: model, record: record)
            Divider()
        }
        Button(L("Rename…"), systemImage: "pencil") {
            model.destination = .transcript(record.id)
            model.renamingRecordID = record.id
        }
        .disabled(model.busy)
        Button(L("Generate Summary"), systemImage: "text.append") {
            model.destination = .transcript(record.id)
            model.postProcess(record, summary: true)
        }
        .disabled(model.busy || record.segments.isEmpty)
        Button(L("Translate Transcript"), systemImage: "translate") {
            model.destination = .transcript(record.id)
            model.postProcess(record, summary: false)
        }
        .disabled(model.busy || record.segments.isEmpty)
        if let path = record.sourcePath {
            Button(L("Show Source in Finder"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        if record.hasRecording == true {
            Button(L("Show Recording in Finder"), systemImage: "waveform") {
                NSWorkspace.shared.activateFileViewerSelecting([model.paths.recording(record)])
            }
            .disabled(model.busy)
        }
        Divider()
        Button(L("Delete Transcript…"), systemImage: "trash", role: .destructive) { model.pendingDeletion = record.id }
            .disabled(model.busy)
    }
}

struct ExportMenu: View {
    let model: AppModel
    let record: TranscriptRecord
    var body: some View {
        Menu(L("Export"), systemImage: "square.and.arrow.up") {
            ForEach(ExportFormat.allCases) { format in
                Button(format.title + "…") { model.export(record, format: format) }
            }
        }
    }
}

/// Opens the Settings window on one page and leaves the main window where it is, so adjusting a setting
/// never takes the person away from the page they were working on. Closing Settings returns them there.
struct OpenSettingsButton: View {
    let title: String
    let page: SettingsPage
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            model.settingsPage = page
            openSettings()
        }
    }
}

/// Shared quick choices in the home page and transcription inspector.
struct TextModelMenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        let settings = model.settings
        Section(L("Text Service")) {
            Picker(L("Text Service"), selection: Binding(get: { settings.textProvider }, set: {
                model.settings.switchTextService(provider: $0)
            })) {
                ForEach(TextProvider.allCases) { provider in
                    Text(serviceTitle(provider)).tag(provider)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        }
        if !settings.textModelPresets.isEmpty {
            Section(L("Model")) {
                Picker(L("Model"), selection: Binding(get: { settings.effectiveTextModel }, set: {
                    model.settings.textModel = $0; model.settings.textModelOverride = nil
                })) {
                    if !settings.textModelPresets.contains(settings.effectiveTextModel) {
                        Text(settings.effectiveTextModel.isEmpty ? L("Select Model") : settings.effectiveTextModel)
                            .tag(settings.effectiveTextModel)
                    }
                    ForEach(settings.textModelPresets, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
        }
        Divider()
        OpenSettingsButton(title: L("Text Model Settings…"), page: .text, model: model)
    }

    private func serviceTitle(_ provider: TextProvider) -> String {
        var settings = model.settings
        settings.textProvider = provider
        return settings.textServiceTitle
    }
}

struct TextModelPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        LabeledContent(L("Text Model")) {
            Menu { TextModelMenuContent(model: model) } label: {
                Text(model.settings.effectiveTextModel.isEmpty ? L("Not configured") : model.settings.effectiveTextModel)
                    .lineLimit(1).truncationMode(.middle)
            }
            .tint(model.settings.effectiveTextModel.isEmpty ? .orange : nil)
            .help(model.settings.textServiceTitle)
        }
    }
}

/// Shows or hides the inspector. Every page ends its toolbar with it, as Apple's apps do.
struct InspectorToggle: ToolbarContent {
    @Binding var isPresented: Bool
    var body: some ToolbarContent {
        ToolbarItem {
            Button { withAnimation(Motion.content) { isPresented.toggle() } } label: {
                Label(L("Transcription Options"), systemImage: "sidebar.trailing")
            }
            .help((isPresented ? L("Hide Transcription Options") : L("Show Transcription Options")) + " ⌃⌘I")
        }
    }
}

/// Minutes and seconds the way Voice Memos shows a length: 0:42, 3:05, 1:02:10.
func durationText(_ seconds: Double) -> String {
    let value = Duration.seconds(max(0, seconds.isFinite ? seconds : 0))
    return value.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
}

func languageName(_ code: String) -> String {
    AppSettings.languages.first { $0.0 == code }?.1 ?? code
}

extension AudioSource {
    /// A filled variant for places where the symbol stands alone and needs more weight.
    var heroSymbol: String {
        switch self { case .microphone: "mic.fill"; case .system: "speaker.wave.2.fill"; case .file: "doc.text.fill" }
    }
}

/// The same caption controls are available in Settings and directly on the floating panel.
struct CaptionControls: View {
    @Bindable var model: AppModel

    var body: some View {
        LabeledContent(L("Text Size")) {
            HStack(spacing: 10) {
                Slider(value: $model.settings.captionSize, in: 16...60, step: 1)
                    .accessibilityLabel(L("Text Size"))
                    .frame(maxWidth: 220)
                Text("\(Int(model.settings.captionSize)) pt")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        Stepper(L("Visible Sentences") + " · " + String(model.settings.visibleCaptionCount),
                value: Binding(get: { model.settings.visibleCaptionCount }, set: { model.settings.captionSentenceCount = $0 }), in: 1...8)
            .accessibilityLabel(L("Visible Sentences"))
            .accessibilityValue(String(model.settings.visibleCaptionCount))
        Toggle(L("Show only translation when available"), isOn: $model.settings.captionTranslationOnly)
    }
}
