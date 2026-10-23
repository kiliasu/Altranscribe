import SwiftUI
import UniformTypeIdentifiers
import AltranscribeCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("interfaceLanguage") private var language = "system"
    @AppStorage("appearance") private var appearance = "system"
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var connectionStatus: LocalizedText?
    @State private var removeModel: URL?

    var body: some View {
        TabView {
            general.tabItem { Label(L("General"), systemImage: "gearshape") }
            speech.tabItem { Label(L("Speech"), systemImage: "waveform") }
            text.tabItem { Label(L("Text Models"), systemImage: "character.bubble") }
        }
        .frame(width: 650, height: 650)
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
        .alert(L("Attention"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("OK"), role: .cancel) { model.error = nil }
        } message: { Text(model.error?.text ?? "") }
    }

    private var general: some View {
        Form {
            Section(L("Appearance")) {
                Picker(L("Language"), selection: $language) {
                    Text(L("System")).tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Text(L("App text changes immediately. Reopen the app to update macOS menus and system dialogs."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L("Appearance"), selection: $appearance) {
                    Text(L("System")).tag("system")
                    Text(L("Light")).tag("light")
                    Text(L("Dark")).tag("dark")
                }
            }
            Section(L("Floating Captions")) {
                Slider(value: $model.settings.captionSize, in: 16...44, step: 1) {
                    Text(L("Text Size"))
                } minimumValueLabel: { Text("16").font(.caption) } maximumValueLabel: { Text("44").font(.caption) }
                Toggle(L("Show only translation when available"), isOn: $model.settings.captionTranslationOnly)
                Button(L("Show Caption Window")) { model.showCaptions() }
            }
            Section(L("Data & Privacy")) {
                LabeledContent(L("Transcript Location")) {
                    Button(L("Open in Finder")) {
                        do { try model.paths.prepare(); NSWorkspace.shared.open(model.paths.root) }
                        catch { model.error = LocalizedText(error: error) }
                    }
                }
                Text(L("Live audio is processed in memory. Transcripts stay on this Mac; API keys are stored in macOS Keychain. Online services receive the relevant audio or text."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Altranscribe", value: "0.8.0 · macOS")
                Text("SwiftUI · Whisper / Metal · Nemotron / CPU").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var speech: some View {
        Form {
            Section {
                Picker(L("Speech Engine"), selection: $model.settings.speechProvider) {
                    ForEach(SpeechProvider.allCases) { Text($0.title).tag($0) }
                }
            }
            if model.settings.speechProvider == .whisper {
                Section(L("On-device Compute")) {
                    Toggle(L("Use Metal GPU Acceleration"), isOn: $model.settings.useGPU)
                    LabeledContent(L("Current Model")) {
                        Text(model.settings.effectiveModelPath.isEmpty ? L("None selected") : URL(fileURLWithPath: model.settings.effectiveModelPath).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                    Button(L("Choose Existing Model…")) { chooseModel() }
                }
                Section {
                    ForEach(WhisperModel.catalog) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                Text(Localization.byteCount(item.bytes)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.downloadID == item.id {
                                ProgressView().controlSize(.small)
                                Button(L("Cancel")) { model.downloadTask?.cancel() }
                            } else if installed(item) {
                                if model.settings.modelPath == model.paths.models.appendingPathComponent(item.filename).path {
                                    Label(L("Selected"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button(L("Use")) { model.settings.modelPath = model.paths.models.appendingPathComponent(item.filename).path }
                                }
                                Button(role: .destructive) { removeModel = model.paths.models.appendingPathComponent(item.filename) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help(L("Delete Model"))
                            } else if item.id == "tiny", Bundle.main.url(forResource: "ggml-tiny", withExtension: "bin", subdirectory: "Models") != nil {
                                Label(L("Included"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                                if !model.settings.modelPath.isEmpty {
                                    Button(L("Use")) { model.settings.modelPath = "" }
                                }
                            } else {
                                Button(L("Download"), systemImage: "arrow.down.circle") { model.download(item) }.disabled(model.downloadID != nil)
                            }
                        }.padding(.vertical, 3)
                    }
                } header: { Text(L("Multilingual Whisper Models")) }
                  footer: { Text(L("Tiny is useful for testing; Small balances speed and accuracy. Downloads are verified with SHA-256.")) }
            } else if model.settings.speechProvider == .nemotron {
                Section(L("On-device Streaming")) {
                    LabeledContent(L("Current Model")) {
                        Text(model.settings.nemotronModel.multilingual ? L("Nemotron 3.5 · Multilingual") : L("Nemotron · English")).lineLimit(1)
                    }
                    LabeledContent(L("Compute"), value: "CPU · INT8")
                    Text(L("English is the default. Captions update as you speak, settle after a pause, and finish the last sentence when stopped. Recognition runs offline."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(NemotronModel.catalog) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.multilingual ? L("3.5 Multilingual") : L("English · Default"))
                                Text(Localization.byteCount(item.bytes))
                                    .font(.caption).foregroundStyle(.secondary)
                                Link(L("Model Card & License"), destination: item.modelCard).font(.caption)
                            }
                            Spacer()
                            if model.downloadID == item.id {
                                ProgressView().controlSize(.small)
                                Button(L("Cancel")) { model.downloadTask?.cancel() }
                            } else if installed(item) {
                                if model.settings.nemotronModel.id == item.id {
                                    Label(L("Selected"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button(L("Use")) { model.settings.nemotronModelID = item.id }
                                }
                                Button(role: .destructive) { removeModel = item.directory(in: model.paths.models) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help(L("Delete Model"))
                            } else {
                                Button(L("Download"), systemImage: "arrow.down.circle") { model.download(item) }
                                    .disabled(model.downloadID != nil)
                            }
                        }.padding(.vertical, 3)
                    }
                } header: { Text(L("Nemotron Models")) }
                  footer: { Text(L("The English model recognizes English only; choose 3.5 Multilingual for Chinese and other languages. All four files must pass SHA-256 verification before installation.")) }
            } else {
                Section(L("Service")) {
                    if model.settings.speechProvider == .compatible {
                        TextField(L("API Base URL"), text: $model.settings.speechBaseURL)
                        TextField(L("Model"), text: $model.settings.speechModel)
                        Text(L("The base URL usually ends in /v1. The service must support audio/transcriptions.")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField(L("Model"), text: $model.settings.geminiSpeechModel)
                    }
                    CredentialEditor(endpoint: model.settings.speechEndpoint).id(model.settings.speechEndpoint)
                }
                Section {
                    Text(L("Live audio is sent in approximately 8-second chunks; files in 20-second chunks. Timestamps are estimates. Paid inference requests are not retried automatically."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy)
        .confirmationDialog(L("Delete the downloaded model?"), isPresented: Binding(get: { removeModel != nil }, set: { if !$0 { removeModel = nil } })) {
            Button(L("Delete Model"), role: .destructive) {
                guard let url = removeModel else { return }
                do {
                    try FileManager.default.removeItem(at: url)
                    if model.settings.modelPath == url.path { model.settings.modelPath = "" }
                    model.modelRevision += 1
                } catch { model.error = LocalizedText(error: error) }
                removeModel = nil
            }
        }
    }

    private var text: some View {
        Form {
            Section(L("Service")) {
                Picker(L("Text Service"), selection: $model.settings.textProvider) {
                    ForEach(TextProvider.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.textProvider == .compatible {
                    TextField(L("API Base URL"), text: $model.settings.textBaseURL)
                    HStack {
                        Text(L("Presets")).foregroundStyle(.secondary)
                        Spacer()
                        Button("Ollama") { model.settings.textBaseURL = "http://127.0.0.1:11434/v1"; model.settings.textModel = ""; models = [] }
                        Button("OpenAI") { model.settings.textBaseURL = "https://api.openai.com/v1"; model.settings.textModel = "gpt-4.1-mini"; models = [] }
                    }
                }
                TextField(L("Model Name"), text: $model.settings.textModel)
                CredentialEditor(endpoint: model.settings.textEndpoint).id(model.settings.textEndpoint)
            }
            Section(L("Available Models")) {
                HStack {
                    Button(L("Fetch Models")) { fetchModels() }.disabled(loadingModels)
                    if loadingModels { ProgressView().controlSize(.small) }
                    if let connectionStatus { Text(connectionStatus.text).font(.caption).foregroundStyle(.secondary) }
                }
                if !models.isEmpty {
                    Picker(L("Select Model"), selection: $model.settings.textModel) {
                        if !models.contains(model.settings.textModel) {
                            Text(model.settings.textModel.isEmpty ? L("Enter Manually") : model.settings.textModel).tag(model.settings.textModel)
                        }
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                Text(L("Run Ollama locally with an installed text model. Online services use HTTPS; keys are saved separately for each API base URL. Fetching models does not run inference."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(model.busy)
    }
    private func installed(_ item: WhisperModel) -> Bool {
        _ = model.modelRevision
        return FileManager.default.fileExists(atPath: model.paths.models.appendingPathComponent(item.filename).path)
    }
    private func installed(_ item: NemotronModel) -> Bool {
        _ = model.modelRevision
        return item.isInstalled(in: model.paths.models)
    }
    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = L("Choose Existing Model…")
        panel.prompt = L("Use")
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.settings.modelPath = url.path }
    }
    private func fetchModels() {
        loadingModels = true; connectionStatus = nil
        let endpoint = model.settings.textEndpoint
        let provider = model.settings.textProvider
        Task {
            defer { loadingModels = false }
            do {
                let key = try KeychainStore.read(endpoint: endpoint)
                let fetched = try await APIClient().models(endpoint: endpoint, provider: provider, key: key)
                guard endpoint == model.settings.textEndpoint, provider == model.settings.textProvider else { return }
                models = fetched
                connectionStatus = LocalizedText("Models found: %@", String(models.count))
            } catch { model.error = LocalizedText(error: error) }
        }
    }
}

struct CredentialEditor: View {
    let endpoint: String
    @State private var key = ""
    @State private var message: LocalizedText?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SecureField(L("API Key (optional for local services)"), text: $key)
                Button(L("Save Key")) {
                    do { try KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: endpoint); message = LocalizedText("Saved to Keychain") }
                    catch { message = LocalizedText(error: error) }
                }
            }
            if let message { Text(message.text).font(.caption).foregroundStyle(.secondary) }
        }
        .task {
            do { key = try KeychainStore.read(endpoint: endpoint) }
            catch { message = LocalizedText(error: error) }
        }
    }
}
