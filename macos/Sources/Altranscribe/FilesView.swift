import SwiftUI
import AltranscribeCore

struct FilesView: View {
    @Bindable var model: AppModel
    @AppStorage("showInspector") private var showInspector = true
    @State private var targeted = false

    var body: some View {
        // The drop zone hands over to the queue when the first file arrives, and returns when the last leaves.
        ZStack {
            if model.queue.isEmpty {
                DropZone(targeted: targeted) { model.chooseFiles() }
                    .padding(24)
                    .transition(.page)
            } else {
                List {
                    ForEach(model.queue) { QueueRow(model: model, item: $0) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .animation(Motion.content, value: model.queue.map(\.id))
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.tint, lineWidth: 2)
                            .background(.tint.opacity(0.05), in: .rect(cornerRadius: 18))
                            .padding(8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .transition(.page)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .safeAreaBar(edge: .bottom) {
            if !model.queue.isEmpty { QueueBar(model: model).padding(.bottom, 18).transition(.rise) }
        }
        .animation(Motion.content, value: model.queue.isEmpty)
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
                .controlSize(.large)
            Text("WAV · M4A · MP3 · AAC · AIFF · MP4 · MOV")
                .font(.footnote.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 24)
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

/// The floating queue controls: how far along the files are, and the one action that moves them on.
private struct QueueBar: View {
    @Bindable var model: AppModel
    @Namespace private var glass

    var body: some View {
        let waiting = model.queue.filter { $0.status == .waiting }.count
        let completed = model.queue.filter { $0.status == .completed }.count
        // Start Queue morphs into Stop Queue and back; the summary and Clear Completed grow out of it.
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if let summary = summary(waiting: waiting) {
                    HStack(spacing: 10) {
                        if model.queueRunning { ProgressView().controlSize(.small).transition(.pop) }
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .rollingNumbers(summary)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("summary", in: glass)
                }

                if model.queueRunning {
                    Button { model.cancel() } label: { Label(L("Stop Queue"), systemImage: "stop.fill").padding(.horizontal, 4) }
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                        .glassEffectID("primary", in: glass)
                } else {
                    if completed > 0 {
                        Button(L("Clear Completed")) { model.clearCompletedQueue() }
                            .buttonStyle(.glass)
                            .controlSize(.extraLarge)
                            .glassEffectID("clear", in: glass)
                    }
                    Button { model.startQueue() } label: { Label(L("Start Queue"), systemImage: "play.fill").padding(.horizontal, 4) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .glassEffectID("primary", in: glass)
                        .disabled(model.busy || !model.modelReady || waiting == 0)
                }
            }
        }
        .animation(Motion.glass, value: model.queueRunning)
        .animation(Motion.glass, value: waiting > 0)
        .animation(Motion.glass, value: completed > 0)
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
