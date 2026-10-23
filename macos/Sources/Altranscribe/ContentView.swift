import SwiftUI
import AltranscribeCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            List(selection: $model.workspace) {
                Section(L("Workspace")) {
                    ForEach(Workspace.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section(L("Recent")) {
                    ForEach(model.records.prefix(5)) { record in
                        Button {
                            model.selectedRecordID = record.id; model.workspace = .library
                        } label: {
                            Label(record.title, systemImage: record.source.symbol).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Image(systemName: model.localProcessing ? "desktopcomputer" : "network")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.localProcessing ? L("On-device processing") : L("API processing")).font(.callout)
                        Text(model.busy ? model.status.text : model.settings.speechProvider.title)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
                        .help(L("Settings"))
                }.padding(16)
            }
        } detail: {
            Group {
                switch model.workspace ?? .live {
                case .live: LiveView(model: model)
                case .files: FilesView(model: model)
                case .library: LibraryView(model: model)
                }
            }
            .navigationTitle((model.workspace ?? .live).title)
            .toolbar {
                ToolbarItemGroup {
                    Button { model.chooseFiles() } label: { Label(L("Import"), systemImage: "plus") }
                        .help(L("Import audio or video ⌘O"))
                    Button { model.showCaptions() } label: { Label(L("Captions"), systemImage: "captions.bubble") }
                }
                ToolbarItem {
                    Button { showInspector.toggle() } label: { Label(L("Transcription Options"), systemImage: "sidebar.right") }
                }
            }
            .inspector(isPresented: $showInspector) { SessionInspector(model: model).inspectorColumnWidth(min: 245, ideal: 275, max: 320) }
        }
        .frame(minWidth: 880, minHeight: 600)
        .alert(L("Attention"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("OK"), role: .cancel) { model.error = nil }
        } message: { Text(model.error?.text ?? "") }
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }
}

struct SessionInspector: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section(L("Recognition")) {
                LabeledContent(L("Engine"), value: model.settings.speechProvider.title)
                if model.settings.speechProvider.isLocal {
                    LabeledContent(L("Compute"), value: model.settings.speechProvider == .whisper && model.settings.useGPU ? "Metal" : "CPU")
                }
                if model.settings.speechProvider == .nemotron && !model.settings.nemotronModel.multilingual {
                    LabeledContent(L("Language"), value: "English")
                } else {
                    Picker(L("Language"), selection: $model.settings.sourceLanguage) {
                        ForEach(AppSettings.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                SettingsLink { Text(L("Manage Models…")) }
            }
            Section(L("Text Processing")) {
                Toggle(L("Translate"), isOn: $model.settings.translate)
                Toggle(L("Summarize when finished"), isOn: $model.settings.summarize)
                    .help(L("Titles and summaries use the app language at task start, independently of the translation language."))
                Picker(L("Target Language"), selection: $model.settings.targetLanguage) {
                    ForEach(AppSettings.languages.filter { $0.0 != "auto" }, id: \.0) { Text($0.1).tag($0.0) }
                }
                if model.settings.translate || model.settings.summarize {
                    Text(model.settings.textModel.isEmpty ? L("Configure a text model in Settings.") : model.settings.textModel)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.settings.speechProvider != .nemotron {
                Section(L("Vocabulary")) {
                    TextField(L("Names and terms, separated by commas"), text: $model.settings.vocabulary, axis: .vertical)
                        .lineLimit(3...6)
                    Text(L("Helps recognize names and terms without rewriting the original text."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Label(model.localProcessing ? L("Audio and text stay on this Mac") : L("Relevant audio or text is sent to the selected API"), systemImage: model.localProcessing ? "lock.shield" : "network")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy)
    }
}

struct LiveView: View {
    @Bindable var model: AppModel
    @State private var confirmDiscard = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker(L("Audio Source"), selection: $model.source) {
                    ForEach([AudioSource.microphone, .system]) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 320).disabled(model.busy)
                Spacer(minLength: 4)
                Text(timestamp(model.elapsed)).monospacedDigit().foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            if let record = model.activeRecord, record.source != .file {
                TranscriptView(record: record, followsLatest: model.phase == .recording || model.phase == .finishing)
            } else {
                ContentUnavailableView {
                    Label(L("Turn sound into words"), systemImage: "waveform")
                } description: {
                    Text(L("Capture a lecture, a meeting, or a thought. Choose an audio source to begin."))
                } actions: {
                    if !model.modelReady { SettingsLink { Text(L("Download a Local Model")) }.buttonStyle(.borderedProminent) }
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Circle().fill(model.phase == .recording ? Color.red : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.status.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        if model.pendingTranslations > 0 {
                            Text(L("Pending translations: %@", String(model.pendingTranslations)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.phase == .recording { ProgressView(value: Double(model.meter)).frame(width: 60).accessibilityLabel(L("Input Level")) }
                }
                Spacer()
                if model.phase == .recording || model.phase == .paused {
                    Menu {
                        Button(L("Discard Recording…"), role: .destructive) { confirmDiscard = true }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                    Button { model.togglePause() } label: { Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill") }
                        .help(model.phase == .paused ? L("Resume") : L("Pause"))
                    Button(L("Stop & Save"), systemImage: "stop.fill") { model.stopAndSave() }.buttonStyle(.borderedProminent)
                } else if model.busy {
                    ProgressView().controlSize(.small)
                    Button(L("Cancel Processing")) { model.cancel() }
                } else {
                    Button(L("Start Transcription"), systemImage: "record.circle") { model.startLive() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.modelReady)
                }
            }.padding(20)
        }
        .confirmationDialog(L("Discard this recording?"), isPresented: $confirmDiscard) {
            Button(L("Discard"), role: .destructive) { model.cancel(discardRecording: true) }
        } message: { Text(L("This deletes the transcript from this recording.")) }
    }
}

struct TranscriptView: View {
    let record: TranscriptRecord
    var followsLatest = false
    @State private var follow = true
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if let summary = record.summary {
                        GroupBox {
                            Text(summary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        } label: { Label(L("Summary"), systemImage: "text.alignleft") }
                    }
                    if let error = record.error { Label(error.text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                    if record.segments.isEmpty {
                        ContentUnavailableView(L("Waiting for speech"), systemImage: "waveform", description: Text(L("Text appears here as each audio segment is processed.")))
                            .frame(maxWidth: .infinity).padding(.top, 48)
                    }
                    ForEach(record.segments) { segment in
                        HStack(alignment: .top, spacing: 20) {
                            Text((segment.estimated ? "≈ " : "") + timestamp(segment.start))
                                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                .frame(width: 56, alignment: .leading).padding(.top, 4)
                                .help(segment.estimated ? L("This timestamp is estimated") : L("Audio timestamp"))
                            VStack(alignment: .leading, spacing: 8) {
                                Text(segment.text).font(.body).lineSpacing(5).textSelection(.enabled)
                                if let translation = segment.translation {
                                    Text(translation).font(.body).foregroundStyle(.secondary).lineSpacing(4).textSelection(.enabled)
                                }
                                if let error = segment.translationError {
                                    Label(error.text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.id(segment.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(28)
            }
            .onChange(of: record.segments.last?.id) { _, _ in if followsLatest && follow { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: record.segments.last?.text) { _, _ in if followsLatest && follow { proxy.scrollTo("bottom", anchor: .bottom) } }
            .safeAreaInset(edge: .top, alignment: .trailing) {
                if followsLatest {
                    Toggle(L("Follow Latest"), isOn: $follow).toggleStyle(.button).controlSize(.small).padding(8)
                }
            }
        }
    }
}

struct FilesView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if model.queue.isEmpty {
                ContentUnavailableView {
                    Label(L("Bring in a recording"), systemImage: "doc.badge.plus")
                } description: {
                    Text(L("Drop audio or video here, or choose files from your Mac. Files are processed in order."))
                } actions: {
                    Button(L("Choose Files…")) { model.chooseFiles() }.buttonStyle(.borderedProminent)
                }.frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.queue) { item in
                        HStack(spacing: 14) {
                            Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.url.lastPathComponent).lineLimit(1)
                                if let error = item.error { Text(error.text).font(.caption).foregroundStyle(.orange) }
                                else { Text(queueLabel(item.status)).font(.caption).foregroundStyle(.secondary) }
                                if item.status == .processing { ProgressView(value: item.progress).frame(maxWidth: 300) }
                            }
                            Spacer()
                            if item.status == .completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            if let id = item.recordID {
                                Button(L("View")) { model.selectedRecordID = id; model.workspace = .library }
                            }
                            if item.status == .failed || item.status == .cancelled {
                                Button(L("Retry")) {
                                    if let index = model.queue.firstIndex(where: { $0.id == item.id }) { model.queue[index].status = .waiting; model.queue[index].error = nil; model.queue[index].progress = 0 }
                                }.disabled(model.busy)
                            }
                            Button { model.queue.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).disabled(model.busy).help(L("Remove from Queue"))
                        }.padding(.vertical, 10)
                    }
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Text(L("Supports audio and video that macOS can decode")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.queueRunning {
                    ProgressView().controlSize(.small)
                    Button(L("Stop Queue")) { model.cancel() }
                } else {
                    Button(L("Start Queue"), systemImage: "play.fill") { model.startQueue() }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || !model.modelReady || !model.queue.contains(where: { $0.status == .waiting }))
                }
            }.padding(20)
        }
        .dropDestination(for: URL.self) { urls, _ in model.addFiles(urls); return !urls.isEmpty }
    }
    private func queueLabel(_ status: QueueStatus) -> String {
        switch status {
        case .waiting: L("Waiting")
        case .processing: L("Transcribing")
        case .completed: L("Completed")
        case .failed: L("Failed")
        case .cancelled: L("Stopped; partial transcript retained")
        }
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var rename = false
    @State private var title = ""
    @State private var confirmDelete = false
    var body: some View {
        HStack(spacing: 0) {
            List(model.filteredRecords, selection: $model.selectedRecordID) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.title).font(.headline).lineLimit(2)
                    Text(Localization.date(record.createdAt)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Label(record.source.title, systemImage: record.source.symbol)
                        Spacer()
                        if record.status != .completed { Text(record.status.title) }
                    }.font(.caption2).foregroundStyle(.tertiary)
                }.padding(.vertical, 6).tag(record.id)
            }
            .searchable(text: $model.search, prompt: Text(L("Search Transcripts")))
            .frame(width: 220)
            Divider()
            if let record = model.selectedRecord {
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.title).font(.title2).fontWeight(.semibold).textSelection(.enabled)
                            Text("\(record.speechModel) · \(record.status.title)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button(L("Copy Transcript"), systemImage: "doc.on.doc") { model.copy(record) }
                            Menu(L("Export")) {
                                ForEach(ExportFormat.allCases) { format in Button(format.title) { model.export(record, format: format) } }
                            }
                            Divider()
                            Button(L("Rename…")) { title = record.title; rename = true }.disabled(model.busy)
                            Button(L("Generate Summary")) { model.postProcess(record, summary: true) }.disabled(model.busy || record.segments.isEmpty)
                            Button(L("Translate Transcript")) { model.postProcess(record, summary: false) }.disabled(model.busy || record.segments.isEmpty)
                            if let path = record.sourcePath { Button(L("Show Source in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                            Divider()
                            Button(L("Delete Transcript…"), role: .destructive) { confirmDelete = true }.disabled(model.busy)
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
                    }.padding(24)
                    if model.isPostProcessing {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(model.status.text).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("Cancel")) { model.cancel() }
                        }.padding(.horizontal, 24).padding(.bottom, 12)
                    }
                    Divider()
                    TranscriptView(record: record)
                }.frame(maxWidth: .infinity)
                .alert(L("Rename"), isPresented: $rename) {
                    TextField(L("Title"), text: $title)
                    Button(L("Cancel"), role: .cancel) { }
                    Button(L("Save")) { model.renameRecord(record.id, title: title) }
                }
                .confirmationDialog(L("Delete this transcript?"), isPresented: $confirmDelete) {
                    Button(L("Delete"), role: .destructive) { model.deleteRecord(record.id) }
                } message: { Text(L("The original media file will be kept.")) }
            } else {
                ContentUnavailableView(L("Your words, kept close"), systemImage: "books.vertical", description: Text(L("Select a transcript to read its text, translation and summary.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
