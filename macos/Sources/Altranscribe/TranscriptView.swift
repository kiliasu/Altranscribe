import SwiftUI
import AltranscribeCore

/// A transcript that is still growing: a live session, or a file the queue is processing.
enum LiveState: Equatable {
    case recording, paused, finishing
    case transcribing, translating, summarizing

    init(_ stage: FileRun.Stage) {
        switch stage {
        case .transcribing: self = .transcribing
        case .translating: self = .translating
        case .summarizing: self = .summarizing
        }
    }
}

/// A transcript laid out for reading: one measure-limited column of timestamped lines, each followed by its translation.
///
/// A growing transcript stays on its latest line by anchoring the scroll view's bottom edge. The position
/// is settled in the same layout pass as the text, so the latest line never moves: earlier lines shift up
/// as it grows. Nothing is queued, replayed or chased with scroll requests afterwards, however many lines
/// arrive at once and whether the window is in front, behind another app, hidden or minimized.
struct TranscriptScroll<Header: View>: View {
    let record: TranscriptRecord
    var live: LiveState?
    /// Words from the sidebar's search: marked wherever the transcript has them, the first place brought into view.
    var highlight = ""
    private let header: (TranscriptRecord) -> Header
    @AppStorage("transcriptTextSize") private var textSize = 15.0
    @Environment(\.appearsActive) private var appearsActive
    /// Whether the view rests on the end of a transcript that is growing, or has just stopped growing.
    /// Scrolling away by hand turns it off; reaching the end of a growing transcript turns it on.
    @State private var follow: Bool
    @State private var position = ScrollPosition()
    @State private var scrollPhase = ScrollPhase.idle
    @State private var surroundings = Surroundings()

    init(record: TranscriptRecord, live: LiveState? = nil, highlight: String = "",
         @ViewBuilder header: @escaping (TranscriptRecord) -> Header) {
        self.record = record; self.live = live; self.highlight = highlight; self.header = header
        _follow = State(initialValue: live != nil)
    }

    private var following: Bool { live != nil && follow }

    private struct Metrics: Equatable {
        var offset: CGFloat, distance: CGFloat
        var content: CGFloat, container: CGFloat, insets: EdgeInsets
    }

    var body: some View {
        ScrollViewReader { reader in
            transcript
                // Opened from a search, or searched while open: the first line that has the words comes
                // into view. A transcript that is still growing stays with its latest line.
                .onChange(of: highlight, initial: true) { _, words in
                    guard live == nil, let line = SearchHighlight.firstLine(with: words, in: record) else { return }
                    Task { @MainActor in reader.scrollTo(line, anchor: .center) }
                }
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(record)
                if let summary = record.summary {
                    SummaryCard(summary: summary, textSize: textSize, highlight: highlight)
                        .padding(.bottom, 20)
                }
                ForEach(record.segments) { segment in
                    SegmentRow(segment: segment, textSize: textSize,
                               streaming: live != nil && appearsActive && segment.id == record.segments.last?.id,
                               current: following ? segment.id == record.segments.last?.id : nil,
                               highlight: highlight).equatable()
                }
                if record.segments.isEmpty && live == nil {
                    Text(L("No speech was transcribed."))
                        .font(.system(size: textSize))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
                if let live, live != .finishing {
                    ListeningIndicator(state: live, textSize: textSize)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, 28, for: .scrollContent)
        .contentMargins(.bottom, 36, for: .scrollContent)
        .scrollPosition($position)
        // While the view rests on the end, the bottom edge is the fixed point for every change of size:
        // new text, a translation above the latest line, another text size, a resized window, the taller
        // bar under a finished session. Once the reader has scrolled away, the top is, so the lines
        // being read stay where they are.
        .defaultScrollAnchor(live == nil ? .top : .bottom, for: .initialOffset)
        .defaultScrollAnchor(follow ? .bottom : .top, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .transaction { transaction in
            if !appearsActive { transaction.animation = nil; transaction.disablesAnimations = true }
        }
        .onScrollGeometryChange(for: Metrics.self) { geometry in
            Metrics(offset: geometry.contentOffset.y,
                    distance: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY,
                    content: geometry.contentSize.height, container: geometry.containerSize.height, insets: geometry.contentInsets)
        } action: { old, new in
            guard live != nil || follow else { return }
            let handled = scrollPhase == .tracking || scrollPhase == .interacting || scrollPhase == .decelerating
            let resized = new.container != old.container || new.insets != old.insets
            if resized { surroundings.changed = .now }
            let layoutChanged = resized || new.content != old.content
            if new.distance < 8 {
                if !follow { follow = true }
            } else if follow, new.offset < old.offset - 0.5,
                      handled || !layoutChanged && Date.now.timeIntervalSince(surroundings.changed) > 0.5 {
                // Only the reader moves the view away from the end: with a gesture or the wheel, which
                // report a phase, or with the scroll bar or an assistive app, which move the view while
                // nothing else changes. Text that changes never does, and neither does a window that
                // resizes: its layout settles over several passes, some of which move only the position.
                follow = false
            }
            // Only a view resting exactly on the end stays there as the text grows. Bring it back when
            // it was resting a few points short.
            if follow, layoutChanged, !handled, scrollPhase != .animating, new.distance > 0.5 {
                position.scrollTo(edge: .bottom)
            }
        }
        .onScrollPhaseChange { _, phase, context in
            scrollPhase = phase
            // A gesture can end a few points short of the end, or past it and spring back short of new text.
            let geometry = context.geometry
            if phase == .idle, follow, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY > 0.5 {
                position.scrollTo(edge: .bottom)
            }
        }
        // The initial anchor rests the last line on the window's edge, behind the bar below it.
        .onAppear { if live != nil { position.scrollTo(edge: .bottom) } }
        .onChange(of: live != nil) { _, growing in
            if growing, !follow { follow = true; position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if live != nil && !follow {
                    // The latest line can be thousands of lines away, most of them never laid out: go there at once.
                    Button { follow = true; position.scrollTo(edge: .bottom) } label: {
                        Label(L("Jump to Latest"), systemImage: "arrow.down")
                    }
                    .buttonStyle(.glass)
                    .transition(.rise)
                }
            }
            .padding(.bottom, 14)
            // Only the button moves when the reader leaves the end or returns to it; the text does not.
            .animation(Motion.content, value: live != nil && !follow)
        }
    }
}

/// When the space around a transcript last changed: its window, the bar under it, the inspector beside it.
/// A reference, so noting the time redraws nothing.
private final class Surroundings {
    var changed = Date.distantPast
}

struct SegmentRow: View, Equatable {
    let segment: TranscriptSegment
    let textSize: Double
    var streaming = false
    var current: Bool?
    var highlight = ""

    /// A line's words: settling in as they arrive, or with the searched words marked.
    @ViewBuilder private func words(_ text: String) -> some View {
        if highlight.isEmpty { StreamingText(text, active: streaming) }
        else { Text(SearchHighlight.marked(text, highlight)) }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text((segment.estimated ? "≈ " : "") + timestamp(segment.start))
                .font(.system(size: max(10, textSize - 4)).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
                .help(segment.estimated ? L("This timestamp is estimated") : L("Audio timestamp"))
            VStack(alignment: .leading, spacing: textSize * 0.4) {
                words(segment.text)
                    .font(.system(size: textSize))
                    .lineSpacing(textSize * 0.3)
                if let translation = segment.translation {
                    if segment.translationIsProvisional == true {
                        Text(L("Provisional translation")).font(.caption).foregroundStyle(.tertiary)
                    }
                    words(translation)
                        .font(.system(size: textSize))
                        .lineSpacing(textSize * 0.3)
                        .foregroundStyle(.secondary)
                }
                if let error = segment.translationError {
                    Label(error.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .transition(.rise)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SentenceEmphasis(current: current))
        }
        .padding(.vertical, textSize * 0.55)
        .animation(Motion.content, value: segment.translation != nil || segment.translationError != nil)
    }
}

/// The line under a growing transcript that says what is producing the next line.
private struct ListeningIndicator: View {
    let state: LiveState
    let textSize: Double
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String {
        switch state {
        case .paused: "pause.fill"
        case .translating: "translate"
        case .summarizing: "sparkles"
        default: "waveform"
        }
    }
    private var title: String {
        switch state {
        case .paused: L("Paused")
        case .transcribing: L("Transcribing")
        case .translating: L("Translating")
        case .summarizing: L("Creating summary…")
        default: L("Listening")
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Color.clear.frame(width: 58, height: 1)
            HStack(spacing: 6) {
                ActivitySymbol(name: symbol, animating: appearsActive && !reduceMotion && state != .paused,
                               pointSize: max(11, textSize - 2), side: max(16, textSize))
                Text(title)
                    .contentTransition(.opacity)
                    .lineLimit(1)
            }
            .font(.system(size: max(11, textSize - 2)))
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, textSize * 0.55)
        .animation(appearsActive && !reduceMotion ? Motion.quick : nil, value: state)
    }
}

/// Marks each place a text has the words being searched for. It finds them the way the sidebar's search
/// finds a transcript: without regard to case, accents or character width.
enum SearchHighlight {
    static func marked(_ text: String, _ words: String) -> AttributedString {
        var marked = AttributedString(text)
        for range in ranges(of: words, in: text) {
            if let place = Range(range, in: marked) { marked[place].backgroundColor = .yellow.opacity(0.45) }
        }
        return marked
    }
    static func ranges(of words: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = [], start = text.startIndex
        while !words.isEmpty, start < text.endIndex,
              let range = text[start...].localizedStandardRange(of: words), !range.isEmpty {
            ranges.append(range); start = range.upperBound
        }
        return ranges
    }
    static func firstLine(with words: String, in record: TranscriptRecord) -> UUID? {
        guard !words.isEmpty else { return nil }
        return record.segments.first {
            $0.text.localizedStandardContains(words) || $0.translation?.localizedStandardContains(words) == true
        }?.id
    }
}

struct SummaryCard: View {
    let summary: String
    let textSize: Double
    var highlight = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Summary"), systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text(SearchHighlight.marked(summary, highlight))
                .font(.system(size: textSize))
                .lineSpacing(textSize * 0.3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        // Content layer: a standard fill in the grouped radius, no outline.
        .background(.fill.quaternary, in: .rect(cornerRadius: Radius.group))
    }
}

/// The title and facts at the top of a transcript. Double-click the title, or choose Rename, to edit it in place.
struct RecordHeader: View {
    @Bindable var model: AppModel
    let record: TranscriptRecord
    var compact = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var renaming: Bool { model.renamingRecordID == record.id }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Group {
                if renaming {
                    TextField(L("Title"), text: $draft)
                        .textFieldStyle(.plain)
                        .focused($editing)
                        .onSubmit(commit)
                        .onExitCommand { model.renamingRecordID = nil }
                        .onAppear { draft = record.title; editing = true }
                        .onChange(of: editing) { _, focused in if !focused { commit() } }
                } else {
                    Text(record.title)
                        .contentTransition(.opacity)
                        .onTapGesture(count: 2) { if !model.busy { model.renamingRecordID = record.id } }
                }
            }
            .font(compact ? .title2.weight(.semibold) : .largeTitle.weight(.bold))
            FlowLayout(spacing: 16, lineSpacing: 6) {
                // A live header leaves the time to the transport bar.
                if !compact {
                    Label(Localization.date(record.createdAt), systemImage: "calendar")
                    if record.duration > 0 { Label(durationText(record.duration), systemImage: "clock") }
                }
                Label(record.source.title, systemImage: record.source.symbol)
                if record.hasRecording == true {
                    Button(L("Show Recording in Finder"), systemImage: "waveform") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.paths.recording(record)])
                    }
                    .buttonStyle(.link)
                    .disabled(model.busy)
                }
                Label(languageName(record.language) + (record.targetLanguage.map { " → " + languageName($0) } ?? ""),
                      systemImage: record.targetLanguage == nil ? "globe" : "translate")
                if !compact { Label(AppSettings.speechModelDisplayName(record.speechModel), systemImage: "cpu") }
                if record.status == .interrupted || record.status == .failed {
                    Label(record.status.title, systemImage: record.status == .failed ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(record.status == .failed ? .red : .orange)
                        .transition(.pop)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let error = record.error {
                Label(error.text, systemImage: "exclamationmark.bubble")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: .rect(cornerRadius: Radius.group))
                    .transition(.rise)
            }
        }
        .padding(.bottom, compact ? 18 : 26)
        // A generated title, a new status or an error settle in like other content; renaming itself stays immediate.
        .animation(Motion.content, value: record.title)
        .animation(Motion.content, value: record.status)
        .animation(Motion.content, value: record.error)
    }

    private func commit() {
        guard renaming else { return }
        model.renamingRecordID = nil
        if draft != record.title { model.renameRecord(record.id, title: draft) }
    }
}

/// A saved transcript, read in the detail column.
struct TranscriptPage: View {
    @Bindable var model: AppModel
    let record: TranscriptRecord
    @AppStorage("showInspector") private var showInspector = true

    private var live: LiveState? {
        if let run = model.fileRun, run.recordID == record.id { return LiveState(run.stage) }
        guard record.id == model.activeRecordID else { return nil }
        switch model.phase {
        case .recording: return .recording
        case .paused: return .paused
        case .finishing: return record.source == .file ? nil : .finishing
        default: return nil
        }
    }

    var body: some View {
        TranscriptScroll(record: record, live: live, highlight: model.search) { record in
            RecordHeader(model: model, record: record)
            if model.postProcessingID == record.id {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.status.text).foregroundStyle(.secondary).rollingNumbers(model.status.text)
                    Spacer()
                    Button(L("Cancel")) { model.cancel() }
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.fill.quaternary, in: .rect(cornerRadius: Radius.group))
                .padding(.bottom, 20)
                .transition(.rise)
            }
        }
        .animation(Motion.content, value: model.postProcessingID)
        .navigationTitle(record.title)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItemGroup {
                Button { model.copy(record) } label: { Label(L("Copy Transcript"), systemImage: "doc.on.doc") }
                    .help(L("Copy Transcript"))
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title + "…") { model.export(record, format: format) }
                    }
                } label: {
                    Label(L("Export"), systemImage: "square.and.arrow.up")
                }
                .menuIndicator(.hidden)
                .help(L("Export"))
            }
            ToolbarItem {
                Menu {
                    RecordActions(model: model, record: record, includesSharing: false)
                } label: {
                    Label(L("More"), systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help(L("More"))
            }
            ToolbarSpacer(.fixed)
            InspectorToggle(isPresented: $showInspector)
        }
    }
}
