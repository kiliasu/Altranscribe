import SwiftUI
import AltranscribeCore

struct FilesView: View {
    @Bindable var model: AppModel
    @AppStorage("showInspector") private var showInspector = true
    @State private var targeted = false

    var body: some View {
        Group {
            if model.queue.isEmpty {
                DropZone(targeted: targeted) { model.chooseFiles() }
                    .padding(24)
            } else {
                List {
                    ForEach(model.queue) { QueueRow(model: model, item: $0) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.tint, lineWidth: 2)
                            .background(.tint.opacity(0.05), in: .rect(cornerRadius: 18))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .safeAreaBar(edge: .bottom) {
            if !model.queue.isEmpty { QueueBar(model: model).padding(.bottom, 18) }
        }
        .animation(.smooth(duration: 0.2), value: targeted)
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
                if item.status == .processing {
                    HStack(spacing: 10) {
                        ProgressView(value: item.progress).controlSize(.small)
                        Text(item.progress.formatted(.percent.precision(.fractionLength(0)).locale(InterfaceLanguage.current.locale)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                } else if let error = item.error {
                    Text(error.text).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .onHover { hovering = $0 }
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
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.title3)
        default:
            EmptyView()
        }
        if let id = item.recordID, item.status != .processing {
            Button(L("View")) { model.destination = .transcript(id) }
        }
        if item.status == .failed || item.status == .cancelled {
            Button(L("Retry")) { model.retryQueued(item.id) }.disabled(model.queueRunning)
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

    var body: some View {
        let waiting = model.queue.filter { $0.status == .waiting }.count
        let completed = model.queue.filter { $0.status == .completed }.count
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if let summary = summary(waiting: waiting) {
                    HStack(spacing: 10) {
                        if model.queueRunning { ProgressView().controlSize(.small) }
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                }

                if model.queueRunning {
                    Button { model.cancel() } label: { Label(L("Stop Queue"), systemImage: "stop.fill").padding(.horizontal, 4) }
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                } else {
                    if completed > 0 {
                        Button(L("Clear Completed")) { model.clearCompletedQueue() }
                            .buttonStyle(.glass)
                            .controlSize(.extraLarge)
                    }
                    Button { model.startQueue() } label: { Label(L("Start Queue"), systemImage: "play.fill").padding(.horizontal, 4) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .disabled(model.busy || !model.modelReady || waiting == 0)
                }
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: model.queueRunning)
    }

    /// Only what the rows cannot say at a glance: where a running queue is, or how much is left to start.
    private func summary(waiting: Int) -> String? {
        if model.queueRunning, let index = model.queue.firstIndex(where: { $0.status == .processing }) {
            return L("Transcribing %@ of %@", String(index + 1), String(model.queue.count))
        }
        return waiting > 0 ? L("%@ waiting", String(waiting)) : nil
    }
}
