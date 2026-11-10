import SwiftUI
import AltranscribeCore

struct FilesView: View {
    @Bindable var model: AppModel
    @AppStorage("showInspector") private var showInspector = true
    @State private var targeted = false

    var body: some View {
        // The drop zone hands over to the queue when the first file arrives, and returns when the last leaves.
        // While the queue works on a file, the page shows its progress and the text it is producing.
        ZStack {
            if model.queue.isEmpty {
                DropZone(targeted: targeted) { model.chooseFiles() }
                    .padding(24)
                    .transition(.page)
            } else if model.queueRunning, let run = model.fileRun {
                FileProgress(model: model, run: run)
                    .id(run.recordID)
                    .transition(.page)
            } else {
                QueueList(model: model).transition(.page)
            }
        }
        .overlay {
            if targeted && !model.queue.isEmpty {
                RoundedRectangle(cornerRadius: Radius.region)
                    .strokeBorder(.tint, lineWidth: 2)
                    .background(.tint.opacity(0.05), in: .rect(cornerRadius: Radius.region))
                    .padding(8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .safeAreaBar(edge: .bottom) {
            if !model.queue.isEmpty {
                QueueBar(model: model)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .animation(Motion.content, value: model.queue.isEmpty)
        .animation(Motion.content, value: model.fileRun?.recordID)
        .animation(Motion.quick, value: targeted)
        .navigationTitle(L("File Transcription"))
        .navigationSubtitle(L("Supports audio and video that macOS can decode"))
        .toolbar {
            ToolbarItem {
                Button { model.chooseFiles() } label: { Label(L("Add Files…"), systemImage: "plus") }
                    .help(L("Import audio or video ⌘O"))
            }
            ToolbarSpacer(.fixed)
            InspectorToggle(isPresented: $showInspector)
        }
    }
}

private struct QueueList: View {
    let model: AppModel
    var body: some View {
        List {
            ForEach(model.queue) { QueueRow(model: model, item: $0) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .animation(Motion.content, value: model.queue.map(\.id))
    }
}

/// Looks the file's transcript up here, so the text it gains re-evaluates this page and not the
/// files page's bar, title and toolbar around it.
private struct FileProgress: View {
    let model: AppModel
    let run: FileRun
    var body: some View {
        if let record = model.records.first(where: { $0.id == run.recordID }) {
            FileProgressPage(model: model, run: run, record: record)
        } else {
            QueueList(model: model)
        }
    }
}

/// The file the queue is working on: a fixed progress panel over the transcript as it is produced.
private struct FileProgressPage: View {
    let model: AppModel
    let run: FileRun
    let record: TranscriptRecord

    var body: some View {
        VStack(spacing: 0) {
            FileProgressPanel(model: model, run: run, record: record)
                .frame(maxWidth: 760)
                .padding(.horizontal, 36)
                .padding(.top, 20)
                .frame(maxWidth: .infinity)
            TranscriptScroll(record: record, live: LiveState(run.stage)) { _ in EmptyView() }
        }
    }
}

/// How far the current file has got, at what speed, with which models, and how much is translated.
/// Content layer: a standard fill in the grouped radius, system progress, no glass and no outline.
private struct FileProgressPanel: View {
    let model: AppModel
    let run: FileRun
    let record: TranscriptRecord

    private var fraction: Double { run.duration > 0 ? min(1, run.processed / run.duration) : 0 }

    var body: some View {
        let settings = run.configuration
        let locale = InterfaceLanguage.current.locale
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(run.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                if model.queue.count > 1, let index = model.queue.firstIndex(where: { $0.status == .processing }) {
                    Text(L("File %@ of %@", String(index + 1), String(model.queue.count)))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label(stageTitle, systemImage: stageSymbol)
                        .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    if run.duration > 0 {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                .font(.callout)
                if run.duration > 0 {
                    ProgressView(value: fraction).animation(Motion.content, value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                TimelineView(.periodic(from: run.started, by: 1)) { context in
                    Text(timing(at: context.date))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            FlowLayout(spacing: 16, lineSpacing: 6) {
                Label(settings.speechSummary(live: false), systemImage: settings.speechProvider.isLocal ? "cpu" : "cloud")
                if settings.translate {
                    Label(L("Translate to %@", languageName(settings.targetLanguage)) + " · " + settings.effectiveTextModel, systemImage: "translate")
                    Label(L("Translated %@ of %@", String(record.segments.count { $0.translation != nil }), String(record.segments.count)),
                          systemImage: "checkmark.circle")
                }
                if settings.summarize {
                    Label(L("Summary") + " · " + settings.effectiveTextModel, systemImage: "sparkles")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }
        .padding(16)
        .background(.fill.quaternary, in: .rect(cornerRadius: Radius.group))
        .animation(Motion.quick, value: run.stage)
    }

    private var stageTitle: String {
        switch run.stage {
        case .transcribing: L("Transcribing")
        case .translating: L("Translating")
        case .summarizing: L("Creating summary…")
        }
    }
    private var stageSymbol: String {
        switch run.stage {
        case .transcribing: "waveform"
        case .translating: "translate"
        case .summarizing: "sparkles"
        }
    }

    /// Audio done against the file's length, time spent, and, once there is enough to go on, speed and time left.
    private func timing(at now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(run.started))
        var parts = [run.duration > 0 ? L("Processed %@ of %@", durationText(run.processed), durationText(run.duration))
                                      : L("Processed %@", durationText(run.processed)),
                     L("Elapsed %@", durationText(elapsed))]
        let measured = run.updated.timeIntervalSince(run.started)
        if run.processed >= 5, measured >= 1 {
            let speed = run.processed / measured
            parts.append(L("%@× real time", speed.formatted(.number.precision(.fractionLength(1)).locale(InterfaceLanguage.current.locale))))
            let left = max(0, run.duration - run.processed) / speed - now.timeIntervalSince(run.updated)
            if run.duration > 0, run.stage != .summarizing, left >= 1 { parts.append(L("About %@ left", durationText(left))) }
        }
        return parts.joined(separator: " · ")
    }
}

private struct DropZone: View {
    let targeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 112, height: 112)
                .background(.tint.opacity(targeted ? 0.18 : 0.1), in: .circle)
            VStack(spacing: 8) {
                Text(L("Bring in a recording")).font(.largeTitle.weight(.bold))
                Text(L("Drop audio or video here, or choose files from your Mac. Files are processed in order."))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            Button(L("Choose Files…"), action: choose)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            Text("WAV · M4A · MP3 · AAC · AIFF · MP4 · MOV")
                .font(.footnote.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Radius.region)
                .fill(targeted ? AnyShapeStyle(.tint.opacity(0.05)) : AnyShapeStyle(.clear))
                .strokeBorder(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [8, 6]))
        }
    }
}

private struct QueueRow: View {
    let model: AppModel
    let item: QueuedFile
    @State private var hovering = false
    /// Marks only celebrate what finishes while the row is on screen, not work that was already done.
    @State private var initialStatus: QueueStatus

    init(model: AppModel, item: QueuedFile) {
        self.model = model
        self.item = item
        _initialStatus = State(initialValue: item.status)
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The caption cross-fades between waiting, the progress bar and the outcome.
                ZStack(alignment: .leading) {
                    if item.status == .processing {
                        let percent = item.progress.formatted(.percent.precision(.fractionLength(0)).locale(InterfaceLanguage.current.locale))
                        HStack(spacing: 10) {
                            ProgressView(value: item.progress)
                                .controlSize(.small)
                                .animation(Motion.content, value: item.progress)
                            Text(percent)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                                .rollingNumbers(percent)
                        }
                        .transition(.opacity)
                    } else if let error = item.error {
                        Text(error.text).font(.caption).foregroundStyle(.red).lineLimit(2).transition(.opacity)
                    } else {
                        Text(status).font(.caption).foregroundStyle(.secondary).transition(.opacity)
                    }
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(Motion.content, value: item.status)
        .animation(Motion.quick, value: hovering)
        .contextMenu {
            if let id = item.recordID {
                Button(L("Open Transcript"), systemImage: "text.page") { model.destination = .transcript(id) }
            }
            Button(L("Show in Finder"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            if item.status == .failed || item.status == .cancelled {
                Button(L("Retry"), systemImage: "arrow.clockwise") { model.retryQueued(item.id) }
                    .disabled(model.queueRunning)
            }
            Divider()
            Button(L("Remove from Queue"), systemImage: "xmark") { model.removeQueued(item.id) }
                .disabled(model.queueRunning)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.status {
        case .completed:
            DrawnCheckmark(animated: initialStatus != .completed).foregroundStyle(.green).font(.title3)
        case .failed:
            FailureMark(animated: initialStatus != .failed).font(.title3).transition(.pop)
        default:
            EmptyView()
        }
        if let id = item.recordID, item.status != .processing {
            Button(L("View")) { model.destination = .transcript(id) }.transition(.pop)
        }
        if item.status == .failed || item.status == .cancelled {
            Button(L("Retry")) { model.retryQueued(item.id) }.disabled(model.queueRunning).transition(.pop)
        }
        Button { model.removeQueued(item.id) } label: {
            Image(systemName: "xmark.circle.fill").font(.title3)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.tertiary)
        .help(L("Remove from Queue"))
        .opacity(hovering && !model.queueRunning ? 1 : 0)
        .disabled(model.queueRunning)
    }

    private var status: String {
        switch item.status {
        case .waiting: L("Waiting")
        case .processing: L("Transcribing")
        case .completed: L("Completed")
        case .failed: L("Failed")
        case .cancelled: L("Stopped; partial transcript retained")
        }
    }
}

/// File progress and actions share the same native bottom-bar layout as live capture.
private struct QueueBar: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let waiting = model.queue.filter { $0.status == .waiting }.count
        let completed = model.queue.filter { $0.status == .completed }.count
        // Progress at the leading edge and actions at the trailing edge; one above the other where narrow.
        BarLayout {
            HStack(spacing: 0) { progress(waiting: waiting) }
            HStack(spacing: 0) { actions(waiting: waiting, completed: completed) }
        }
        .controlSize(.large)
        // The bar floats over content in the control layer, so its controls are Liquid Glass.
        .buttonStyle(.glass)
    }

    @ViewBuilder private func progress(waiting: Int) -> some View {
        if !model.queueRunning, waiting > 0, let blocker {
            // Say why Start is unavailable and open the setting that fixes it, without leaving the queue.
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(blocker.text).foregroundStyle(.secondary).lineLimit(1)
                Button(blocker.action) { model.settingsPage = blocker.page; openSettings() }
                    .buttonStyle(.link)
            }
        } else if let summary = summary(waiting: waiting) {
            HStack(spacing: 8) {
                if model.queueRunning { ProgressView().controlSize(.small) }
                Text(summary).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func actions(waiting: Int, completed: Int) -> some View {
        HStack {
            if model.queueRunning {
                Button(L("Stop Queue"), systemImage: "stop.fill") { model.cancel() }
            } else {
                if completed > 0 {
                    Button(L("Clear Completed")) { model.clearCompletedQueue() }
                }
                Button(L("Start Queue"), systemImage: "play.fill") { model.startQueue() }
                    .buttonStyle(.glassProminent)
                    .disabled(model.busy || !model.canStart(live: false) || waiting == 0)
            }
        }
    }

    /// The first thing that keeps the queue from starting, with the settings page that fixes it.
    private var blocker: (text: String, action: String, page: SettingsPage)? {
        if let issue = model.modelIssue {
            return (issue.text, model.settings.speechProvider.isLocal ? L("Manage Models…") : L("Speech Settings…"), .speech)
        }
        if let issue = model.textIssue(live: false) {
            return (issue.text, L("Text Model Settings…"), .text)
        }
        return nil
    }

    /// Only what the rows cannot say at a glance: where a running queue is, or how much is left to start.
    private func summary(waiting: Int) -> String? {
        if model.queueRunning, let index = model.queue.firstIndex(where: { $0.status == .processing }) {
            return L("Transcribing %@ of %@", String(index + 1), String(model.queue.count))
        }
        return waiting > 0 ? L("%@ waiting", String(waiting)) : nil
    }
}

/// A failed file's mark shakes once when the failure happens, the way a rejected password field does.
private struct FailureMark: View {
    var animated: Bool
    @State private var attempts = 0
    var body: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
            .symbolEffect(.wiggle, value: attempts)
            .onAppear { if animated { attempts += 1 } }
    }
}
