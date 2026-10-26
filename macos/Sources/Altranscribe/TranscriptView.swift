import SwiftUI
import AltranscribeCore

enum LiveState { case recording, paused, finishing }

/// A transcript laid out for reading: one measure-limited column of timestamped lines, each followed by its translation.
struct TranscriptScroll<Header: View>: View {
    let record: TranscriptRecord
    var live: LiveState?
    @ViewBuilder var header: Header
    @AppStorage("transcriptTextSize") private var textSize = 15.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var follow = true
    private let bottom = "bottom"

    /// Lines that have received their translation or its error, so arriving translations animate in.
    private var settledTranslations: Int {
        record.segments.reduce(0) { $0 + ($1.translation != nil || $1.translationError != nil ? 1 : 0) }
    }

    private struct Metrics: Equatable {
        var offset: CGFloat, distance: CGFloat
        var content: CGFloat, container: CGFloat, insets: EdgeInsets
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    if let summary = record.summary {
                        SummaryCard(summary: summary, textSize: textSize)
                            .padding(.bottom, 20)
                            .transition(.rise)
                    }
                    ForEach(record.segments) { SegmentRow(segment: $0, textSize: textSize).transition(.rise) }
                    if record.segments.isEmpty && live == nil {
                        Text(L("No speech was transcribed."))
                            .font(.system(size: textSize))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                    }
                    if let live, live != .finishing {
                        ListeningIndicator(paused: live == .paused, textSize: textSize).transition(.rise)
                    }
                    Color.clear.frame(height: 1).id(bottom)
                }
                // New lines, arriving translations, a new summary and the end of listening all move as content.
                .animation(Motion.content, value: record.segments.count)
                .animation(Motion.content, value: settledTranslations)
                .animation(Motion.content, value: record.summary)
                .animation(Motion.content, value: live)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(offset: geometry.contentOffset.y,
                        distance: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY,
                        content: geometry.contentSize.height, container: geometry.containerSize.height, insets: geometry.contentInsets)
            } action: { old, new in
                // New text keeps the reader on the latest line. Only moving up by hand, with the
                // layout unchanged, stops following; new lines, insets and resizing never do.
                if new.distance < 40 { follow = true }
                else if new.content == old.content && new.container == old.container && new.insets == old.insets
                            && new.offset < old.offset - 0.5 { follow = false }
            }
            // A new line glides into view; a line that grows keeps pace with a shorter glide.
            .onChange(of: record.segments.count) { _, _ in followLatest(proxy, Motion.content) }
            .onChange(of: record.segments.last?.text) { _, _ in followLatest(proxy, Motion.quick) }
            .onChange(of: settledTranslations) { _, _ in followLatest(proxy, Motion.content) }
            .onChange(of: textSize) { _, _ in followLatest(proxy, nil) }
            .onAppear { if live != nil { proxy.scrollTo(bottom, anchor: .bottom) } }
            .overlay(alignment: .bottom) {
                if live != nil && !follow {
                    Button {
                        follow = true
                        scroll(proxy, Motion.content)
                    } label: {
                        Label(L("Jump to Latest"), systemImage: "arrow.down")
                    }
                    .buttonStyle(.glass)
                    .padding(.bottom, 14)
                    .transition(.rise)
                }
            }
            .animation(Motion.content, value: follow)
        }
    }

    private func followLatest(_ proxy: ScrollViewProxy, _ animation: Animation?) {
        guard live != nil, follow else { return }
        scroll(proxy, animation)
    }
    private func scroll(_ proxy: ScrollViewProxy, _ animation: Animation?) {
        if let animation, !reduceMotion { withAnimation(animation) { proxy.scrollTo(bottom, anchor: .bottom) } }
        else { proxy.scrollTo(bottom, anchor: .bottom) }
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let textSize: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text((segment.estimated ? "≈ " : "") + timestamp(segment.start))
                .font(.system(size: max(10, textSize - 4)).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
                .help(segment.estimated ? L("This timestamp is estimated") : L("Audio timestamp"))
            VStack(alignment: .leading, spacing: textSize * 0.4) {
                Text(segment.text)
                    .font(.system(size: textSize))
                    .lineSpacing(textSize * 0.3)
                if let translation = segment.translation {
                    Text(translation)
                        .font(.system(size: textSize))
                        .lineSpacing(textSize * 0.3)
                        .foregroundStyle(.secondary)
                        .transition(.rise)
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
        }
        .padding(.vertical, textSize * 0.55)
    }
}

private struct ListeningIndicator: View {
    let paused: Bool
    let textSize: Double
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Color.clear.frame(width: 58, height: 1)
            HStack(spacing: 6) {
                Image(systemName: paused ? "pause.fill" : "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: !paused)
                    .contentTransition(.symbolEffect(.replace))
                Text(paused ? L("Paused") : L("Listening"))
                    .contentTransition(.opacity)
            }
            .font(.system(size: max(11, textSize - 2)))
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, textSize * 0.55)
        .animation(Motion.quick, value: paused)
    }
}

struct SummaryCard: View {
    let summary: String
    let textSize: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Summary"), systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text(summary)
                .font(.system(size: textSize))
                .lineSpacing(textSize * 0.3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(.tint.opacity(0.07), in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.tint.opacity(0.14)) }
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
                    .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
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
        guard record.id == model.activeRecordID else { return nil }
        switch model.phase {
        case .recording: return .recording
        case .paused: return .paused
        case .finishing: return record.source == .file ? nil : .finishing
        default: return nil
        }
    }

    var body: some View {
        TranscriptScroll(record: record, live: live) {
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
                .background(.fill.quaternary, in: .rect(cornerRadius: 12))
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
