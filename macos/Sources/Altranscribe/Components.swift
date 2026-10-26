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

/// The last moments of input level, scrolling from right to left like the meter in Voice Memos.
struct LevelHistory: View {
    let levels: [Float]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule().frame(width: 2.5, height: 3 + CGFloat(min(1, max(0, levels[index]))) * 17)
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.1), value: levels)
        .accessibilityElement()
        .accessibilityLabel(L("Input Level"))
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
