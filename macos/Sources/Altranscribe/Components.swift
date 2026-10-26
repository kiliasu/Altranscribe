import SwiftUI
import AltranscribeCore

/// Lays its children out like words in a paragraph, wrapping onto new lines when the row is full.
/// Each child is offered the full row, so one that is too long truncates instead of overflowing.
struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private struct Row { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, in: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
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
        let offer = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        var rows = [Row()]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(offer)
            if width.isFinite { size.width = min(size.width, width) }
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
