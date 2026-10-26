import SwiftUI
import AltranscribeCore

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 256, max: 360)
        } detail: {
            detail
                .inspector(isPresented: Binding(get: { showInspector && model.destination != .settings },
                                                set: { if model.destination != .settings { showInspector = $0 } })) {
                    SessionInspector(model: model)
                        .inspectorColumnWidth(min: 250, ideal: 280, max: 360)
                }
        }
        .frame(minWidth: 860, minHeight: 560)
        .alert(L("Attention"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("OK"), role: .cancel) { model.error = nil }
        } message: { Text(model.error?.text ?? "") }
        .confirmationDialog(L("Delete this transcript?"),
                            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
                            presenting: model.pendingDeletion) { id in
            Button(L("Delete"), role: .destructive) { model.deleteRecord(id) }
        } message: { _ in Text(L("The original media file will be kept.")) }
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
        .task(id: model.settings.appleSpeechLocale + model.settings.speechProvider.rawValue) {
            if model.settings.speechProvider == .appleSpeech { await model.refreshAppleSpeech() }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.destination ?? .live {
        case .live: LiveView(model: model)
        case .files: FilesView(model: model)
        case .settings: SettingsView(model: model, embedded: true).navigationTitle(L("Settings"))
        case .transcript(let id):
            if let record = model.records.first(where: { $0.id == id }) {
                TranscriptPage(model: model, record: record).id(id)
            } else {
                ContentUnavailableView(L("Your words, kept close"), systemImage: "text.page",
                                       description: Text(L("Select a transcript to read its text, translation and summary.")))
            }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.destination) {
            Section {
                LiveRow(model: model).tag(Destination.live)
                FilesRow(model: model).tag(Destination.files)
                Label(L("Settings"), systemImage: "gearshape").tag(Destination.settings)
            }
            let groups = RecordGroup.make(model.filteredRecords)
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.records) { record in
                        RecordRow(record: record, kind: group.kind,
                                  isLive: record.id == model.activeRecordID && (model.isCapturing || model.phase == .finishing))
                            .tag(Destination.transcript(record.id))
                            .contextMenu { RecordActions(model: model, record: record) }
                    }
                }
            }
            if groups.isEmpty {
                Section(L("Transcripts")) {
                    Text(model.search.isEmpty ? L("No transcripts yet") : L("No Results"))
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        // Transcripts slide into and out of the list as they are recorded, deleted or filtered.
        .animation(Motion.content, value: model.filteredRecords.map(\.id))
        .searchable(text: $model.search, placement: .sidebar, prompt: Text(L("Search Transcripts")))
        .onDeleteCommand {
            if case .transcript(let id) = model.destination, !model.busy { model.pendingDeletion = id }
        }
    }
}

private struct LiveRow: View {
    let model: AppModel
    var body: some View {
        let active = model.isCapturing || model.phase == .finishing
        Label {
            HStack(spacing: 6) {
                Text(L("Live Transcription"))
                Spacer(minLength: 4)
                if active {
                    HStack(spacing: 6) {
                        Text(timestamp(model.elapsed))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .rollingNumbers(timestamp(model.elapsed))
                        Circle()
                            .fill(model.phase == .recording ? Color.red : Color.orange)
                            .frame(width: 7, height: 7)
                    }
                    .transition(.pop)
                }
            }
        } icon: {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: model.phase == .recording)
        }
        .tint(active ? .red : nil)
        .animation(Motion.quick, value: active)
        .animation(Motion.quick, value: model.phase == .paused)
    }
}

private struct FilesRow: View {
    let model: AppModel
    var body: some View {
        let pending = model.queue.filter { $0.status == .waiting || $0.status == .processing }.count
        Label {
            HStack(spacing: 6) {
                Text(L("File Transcription"))
                Spacer(minLength: 4)
                if let current = model.queue.first(where: { $0.status == .processing }) {
                    ProgressView(value: current.progress)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .animation(Motion.content, value: current.progress)
                        .transition(.pop)
                }
            }
        } icon: {
            Image(systemName: "tray.and.arrow.down")
        }
        .badge(pending)
        .animation(Motion.quick, value: model.queue.contains { $0.status == .processing })
    }
}

private struct RecordRow: View {
    let record: TranscriptRecord
    let kind: RecordGroup.Kind
    let isLive: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(1)
                HStack(spacing: 5) {
                    Text(detail)
                    if record.status == .interrupted || record.status == .failed {
                        Text("·")
                        Text(record.status.title).foregroundStyle(record.status == .failed ? .red : .orange)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } icon: {
            // While recording the row shows a pulsing record mark; once saved it becomes its source's symbol.
            Image(systemName: isLive ? "record.circle" : record.source.symbol)
                .foregroundStyle(isLive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .symbolEffect(.pulse, isActive: isLive)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.vertical, 2)
        .animation(Motion.quick, value: isLive)
    }

    private var detail: String {
        let locale = InterfaceLanguage.current.locale
        let date: String = switch kind {
        case .today, .yesterday: record.createdAt.formatted(.dateTime.hour().minute().locale(locale))
        case .week: record.createdAt.formatted(.dateTime.weekday(.wide).locale(locale))
        case .month, .earlier: record.createdAt.formatted(.dateTime.month(.abbreviated).day().locale(locale))
        }
        return record.duration > 0 ? date + " · " + durationText(record.duration) : date
    }
}

/// Transcripts grouped the way Notes groups notes: today, yesterday, the past week and month, then by month.
struct RecordGroup: Identifiable {
    enum Kind: Hashable { case today, yesterday, week, month, earlier(Date) }
    let kind: Kind
    var records: [TranscriptRecord]
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .today: L("Today")
        case .yesterday: L("Yesterday")
        case .week: L("Previous 7 Days")
        case .month: L("Previous 30 Days")
        case .earlier(let month): month.formatted(.dateTime.year().month(.wide).locale(InterfaceLanguage.current.locale))
        }
    }

    static func make(_ records: [TranscriptRecord], now: Date = .now, calendar: Calendar = .current) -> [RecordGroup] {
        let today = calendar.startOfDay(for: now)
        var groups: [RecordGroup] = []
        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            let age = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let kind: Kind = switch age {
            case ...0: .today
            case 1: .yesterday
            case 2..<7: .week
            case 7..<30: .month
            default: .earlier(calendar.dateInterval(of: .month, for: day)?.start ?? day)
            }
            if groups.last?.kind == kind { groups[groups.count - 1].records.append(record) }
            else { groups.append(RecordGroup(kind: kind, records: [record])) }
        }
        return groups
    }
}

// MARK: - Inspector

struct SessionInspector: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section(L("Recognition")) {
                LabeledContent(L("Engine")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.settings.speechProvider.title)
                        if model.settings.speechProvider.isLocal {
                            Text(compute).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.modelReady {
                    Label(model.settings.speechProvider == .appleSpeech ? model.appleSpeechStatus.title : L("The selected model is not downloaded yet."), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .transition(.rise)
                }
                if model.settings.speechProvider == .appleSpeech {
                    LabeledContent(L("Language"), value: InterfaceLanguage.current.locale.localizedString(forIdentifier: model.settings.appleSpeechLocale) ?? model.settings.appleSpeechLocale)
                } else if model.settings.speechProvider == .fluidAudio {
                    LabeledContent(L("Language"), value: model.settings.fluidAudioModel == .english ? "English" : L("Detect Automatically"))
                } else if model.settings.speechProvider == .nemotron && !model.settings.nemotronModel.multilingual {
                    LabeledContent(L("Language"), value: "English")
                } else {
                    Picker(L("Language"), selection: $model.settings.sourceLanguage) {
                        ForEach(AppSettings.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                Button(L("Manage Models…")) { model.settingsPage = .speech; model.destination = .settings }
            }
            Section {
                Toggle(L("Translate"), isOn: $model.settings.translate)
                Picker(L("Target Language"), selection: $model.settings.targetLanguage) {
                    ForEach(AppSettings.languages.filter { $0.0 != "auto" }, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle(L("Summarize when finished"), isOn: $model.settings.summarize)
                    .help(L("Titles and summaries use the app language at task start, independently of the translation language."))
            } header: {
                Text(L("Text Processing"))
            } footer: {
                if model.settings.translate || model.settings.summarize {
                    Label(model.settings.effectiveTextModel.isEmpty ? L("Configure a text model in Settings.") : model.settings.effectiveTextModel,
                          systemImage: model.settings.effectiveTextModel.isEmpty ? "exclamationmark.triangle" : "character.bubble")
                        .font(.caption)
                        .foregroundStyle(model.settings.effectiveTextModel.isEmpty ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
            }
            if model.settings.supportsVocabulary {
                Section {
                    TextField(L("Names and terms, separated by commas"), text: $model.settings.vocabulary, axis: .vertical)
                        .lineLimit(3...6)
                        .labelsHidden()
                } header: {
                    Text(L("Vocabulary"))
                } footer: {
                    Text(L("Helps recognize names and terms without rewriting the original text."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy)
        .animation(Motion.content, value: model.modelReady)
        .animation(Motion.content, value: model.settings.translate || model.settings.summarize)
        .animation(Motion.content, value: model.settings.speechProvider)
    }

    private var compute: String {
        switch model.settings.speechProvider {
        case .fluidAudio: "Core ML · CPU + Neural Engine"
        case .appleSpeech: L("Managed by macOS")
        default: model.settings.speechProvider == .whisper && model.settings.useGPU ? "Metal GPU" : "CPU"
        }
    }
}
