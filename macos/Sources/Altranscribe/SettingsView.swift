import SwiftUI
import UniformTypeIdentifiers
import AltranscribeCore

struct SettingsView: View {
    @Bindable var model: AppModel
    var embedded = false
    @AppStorage("interfaceLanguage") private var language = "system"
    @AppStorage("appearance") private var appearance = "system"
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var connectionStatus: LocalizedText?
    @State private var removeModel: URL?

    var body: some View {
        // Keep the scroll container (and its toolbar edge effect) alive when changing pages.
        Form { pane }
        .formStyle(.grouped)
        .frame(width: embedded ? nil : 600, height: embedded ? nil : 620)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(L("Settings"), selection: $model.settingsPage) {
                    Text(L("General")).tag(SettingsPage.general)
                    Text(L("Speech")).tag(SettingsPage.speech)
                    Text(L("Text Models")).tag(SettingsPage.text)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .onChange(of: model.settings) { _, _ in if !embedded { model.saveSettings() } }
        .task(id: model.settings.appleSpeechLocale + model.settings.speechProvider.rawValue) {
            if !embedded && model.settings.speechProvider == .appleSpeech { await model.refreshAppleSpeech() }
        }
        .alert(L("Attention"), isPresented: Binding(get: { !embedded && model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("OK"), role: .cancel) { model.error = nil }
        } message: { Text(model.error?.text ?? "") }
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

    @ViewBuilder private var pane: some View {
        switch model.settingsPage {
        case .general: general
        case .speech: speech
        case .text: text
        }
    }

    private var general: some View {
        Group {
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
                // Whole points only, so dragging saves settings once per step instead of on every movement.
                LabeledContent(L("Text Size")) {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { model.settings.captionSize },
                                              set: { model.settings.captionSize = $0.rounded() }), in: 16...44)
                            .frame(maxWidth: 220)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                        Text("\(Int(model.settings.captionSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
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
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Altranscribe").font(.headline)
                        Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.8.0") + " · macOS")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var speech: some View {
        Group {
            Section {
                Picker(L("Speech Engine"), selection: $model.settings.speechProvider) {
                    ForEach(SpeechProvider.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.speechProvider == .whisper || !model.settings.speechProvider.isLocal ||
                    (model.settings.speechProvider == .nemotron && model.settings.nemotronModel.multilingual) {
                    Picker(L("Language"), selection: $model.settings.sourceLanguage) {
                        ForEach(AppSettings.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
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
                        ModelRow(title: item.title, detail: Localization.byteCount(item.bytes), symbol: "waveform",
                                 inUse: installed(item) && model.settings.modelPath == model.paths.models.appendingPathComponent(item.filename).path) {
                            if model.downloadID == item.id {
                                ProgressView().controlSize(.small)
                                Button(L("Cancel")) { model.downloadTask?.cancel() }
                            } else if installed(item) {
                                if model.settings.modelPath != model.paths.models.appendingPathComponent(item.filename).path {
                                    Button(L("Use")) { model.settings.modelPath = model.paths.models.appendingPathComponent(item.filename).path }
                                }
                                Button(role: .destructive) { removeModel = model.paths.models.appendingPathComponent(item.filename) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help(L("Delete Model"))
                            } else {
                                Button(L("Download"), systemImage: "arrow.down.circle") { model.download(item) }.disabled(model.downloadID != nil)
                            }
                        }
                    }
                } header: { Text(L("Multilingual Whisper Models")) }
                  footer: { Text(L("Models are downloaded separately and verified with SHA-256. Large v3 is the full model; Turbo is smaller and faster.")) }
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
                        ModelRow(title: item.multilingual ? L("3.5 Multilingual") : L("English · Default"),
                                 detail: Localization.byteCount(item.bytes), symbol: item.multilingual ? "globe" : "character.bubble",
                                 link: item.modelCard, inUse: installed(item) && model.settings.nemotronModel.id == item.id) {
                            if model.downloadID == item.id {
                                ProgressView().controlSize(.small)
                                Button(L("Cancel")) { model.downloadTask?.cancel() }
                            } else if installed(item) {
                                if model.settings.nemotronModel.id != item.id {
                                    Button(L("Use")) { model.settings.nemotronModelID = item.id }
                                }
                                Button(role: .destructive) { removeModel = item.directory(in: model.paths.models) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help(L("Delete Model"))
                            } else {
                                Button(L("Download"), systemImage: "arrow.down.circle") { model.download(item) }
                                    .disabled(model.downloadID != nil)
                            }
                        }
                    }
                } header: { Text(L("Nemotron Models")) }
                  footer: { Text(L("The English model recognizes English only; choose 3.5 Multilingual for Chinese and other languages. All four files must pass SHA-256 verification before installation.")) }
            } else if model.settings.speechProvider == .fluidAudio {
                Section(L("On-device Compute")) {
                    LabeledContent(L("Current Model"), value: model.settings.fluidAudioModel.title)
                    LabeledContent(L("Compute"), value: "Core ML · CPU + Neural Engine")
                    Text(L("Parakeet v2 recognizes English. V3 detects 25 European languages automatically; Chinese is not supported."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("FluidAudio Models")) {
                    ForEach(FluidAudioModel.allCases) { item in
                        ModelRow(title: item.title, detail: "Parakeet TDT · 0.6B", symbol: "cpu", link: item.modelCard,
                                 inUse: item.isInstalled(in: model.paths.models) && model.settings.fluidAudioModel == item) {
                            if model.downloadID == item.id {
                                ProgressView().controlSize(.small)
                                Button(L("Cancel")) { model.downloadTask?.cancel() }
                            } else if item.isInstalled(in: model.paths.models) {
                                if model.settings.fluidAudioModel != item {
                                    Button(L("Use")) { model.settings.fluidAudioModelID = item.id }
                                }
                                Button(role: .destructive) { removeModel = item.directory(in: model.paths.models) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help(L("Delete Model")).disabled(model.downloadID != nil)
                            } else {
                                Button(L("Download"), systemImage: "arrow.down.circle") { model.download(item) }.disabled(model.downloadID != nil)
                            }
                        }
                    }
                }
                chunkedLocalNote
            } else if model.settings.speechProvider == .appleSpeech {
                Section(L("System Language Model")) {
                    Picker(L("Language"), selection: Binding(get: { model.settings.appleSpeechLocale },
                                                             set: { model.settings.appleSpeechLocaleID = $0 })) {
                        if !model.appleSpeechLocales.contains(model.settings.appleSpeechLocale) {
                            Text(localeName(model.settings.appleSpeechLocale)).tag(model.settings.appleSpeechLocale)
                        }
                        ForEach(model.appleSpeechLocales, id: \.self) { Text(localeName($0)).tag($0) }
                    }.disabled(model.downloadID == "apple-speech")
                    LabeledContent(L("Model Status"), value: model.appleSpeechStatus.title)
                    LabeledContent(L("Compute"), value: L("Managed by macOS"))
                    HStack {
                        if model.downloadID == "apple-speech" {
                            ProgressView().controlSize(.small)
                            Button(L("Cancel")) { model.downloadTask?.cancel() }
                        } else if model.appleSpeechStatus == .downloadRequired || model.appleSpeechStatus == .downloading {
                            Button(L("Install Language Model"), systemImage: "arrow.down.circle") { model.installAppleSpeech() }
                                .disabled(model.downloadID != nil)
                        }
                        Button(L("Refresh Status")) { Task { await model.refreshAppleSpeech() } }
                            .disabled(model.downloadID == "apple-speech")
                    }
                    Text(L("Choose the spoken language explicitly. macOS manages and updates these on-device models; availability depends on this Mac. No speech API key is needed."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                chunkedLocalNote
            } else {
                Section(L("Service")) {
                    if model.settings.speechProvider == .compatible {
                        DisclosureGroup(L("Endpoint Override")) {
                            TextField(L("API Base URL"), text: $model.settings.speechBaseURL)
                            Button(L("Use OpenAI Endpoint")) { model.settings.speechBaseURL = "https://api.openai.com/v1" }
                            Text(L("Custom endpoints must implement audio/transcriptions; chat-only services cannot transcribe audio."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    CredentialEditor(endpoint: model.settings.speechEndpoint).id(model.settings.speechEndpoint)
                }
                if model.settings.usesCloudLive {
                    Section(L("Live Speech")) {
                        Toggle(L("Translate directly from audio"), isOn: Binding(get: { model.settings.cloudDirectTranslation ?? true },
                                                                              set: { model.settings.cloudDirectTranslation = $0 }))
                        LabeledContent(L("Transcription"), value: model.settings.speechProvider == .gemini ? "gemini-3.5-transcribe-live" : "gpt-live-transcribe")
                        LabeledContent(L("Direct Translation"), value: model.settings.speechProvider == .gemini ? "gemini-3.5-live-translate-preview" : "gpt-realtime-translate")
                        Text(L("When Translate is enabled, direct speech translation returns both the original and translated text. It needs only the speech key. Generated audio is never played."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L("File Transcription")) {
                    if model.settings.speechProvider == .compatible {
                        ModelNamePicker(presets: OpenAITranscriptionModel.allCases.map(\.rawValue),
                                        selection: $model.settings.speechModel, overrideName: $model.settings.speechModelOverride)
                        if model.settings.openAITranscriptionModel?.isDeprecated == true {
                            Text(L("This legacy OpenAI model is scheduled to shut down on February 26, 2027. For new use, choose gpt-transcribe."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.settings.openAITranscriptionModel == .diarize {
                            Text(L("This model does not accept vocabulary hints. This app uses its text output without speaker labels."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker(L("File Transcription Model"), selection: Binding(get: { model.settings.effectiveGeminiSpeechModel },
                                                                                set: { model.settings.geminiSpeechModel = $0 })) {
                            Text("gemini-3.5-transcribe").tag("gemini-3.5-transcribe")
                        }
                    }
                }
                Section {
                    Text(model.settings.usesCloudLive ?
                         L("Files use chunks of up to ten minutes. Live cloud sessions renew before expiry. Timestamps are estimates; paid requests are not replayed automatically.") :
                         L("Custom endpoints use 8-second chunks for live audio and chunks of up to ten minutes for files."))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.settings.speechProvider == .gemini {
                        Text(L("Gemini live translation is a preview. If the service does not confirm finalization, the saved record asks you to review the last sentence."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.settings.supportsVocabulary {
                Section(L("Vocabulary")) {
                    TextField(L("Names and terms, separated by commas"), text: $model.settings.vocabulary, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
        }
        .disabled(model.busy)
        // Switching engines, downloads finishing and models being deleted all rearrange the pane as content.
        .animation(Motion.content, value: model.settings.speechProvider)
        .animation(Motion.quick, value: model.downloadID)
        .animation(Motion.quick, value: model.modelRevision)
    }

    private var text: some View {
        Group {
            Section(L("Text Processing")) {
                Toggle(L("Translate"), isOn: $model.settings.translate)
                Picker(L("Target Language"), selection: $model.settings.targetLanguage) {
                    ForEach(AppSettings.languages.filter { $0.0 != "auto" }, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle(L("Summarize when finished"), isOn: $model.settings.summarize)
            }
            Section(L("Service")) {
                Picker(L("Text Service"), selection: $model.settings.textProvider) {
                    ForEach(TextProvider.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.textProvider == .compatible {
                    TextField(L("API Base URL"), text: $model.settings.textBaseURL)
                    HStack {
                        Text(L("Presets")).foregroundStyle(.secondary)
                        Spacer()
                        Button("Ollama") {
                            model.settings.textBaseURL = "http://127.0.0.1:11434/v1"
                            model.settings.textModel = ""; model.settings.textModelOverride = nil; models = []
                        }
                        Button("OpenAI") {
                            model.settings.textBaseURL = "https://api.openai.com/v1"
                            model.settings.textModel = TextModelPresets.openAI[0]; model.settings.textModelOverride = nil; models = []
                        }
                    }
                }
                ModelNamePicker(presets: textModels, selection: $model.settings.textModel, overrideName: $model.settings.textModelOverride)
                if model.settings.textProvider == .anthropic {
                    TextField(L("Workspace ID (optional)"), text: Binding(get: { model.settings.anthropicWorkspaceID ?? "" },
                                                                         set: { model.settings.anthropicWorkspaceID = $0 }))
                }
                Text(L("File translation and summaries use this text model. Live direct speech translation uses the speech service. For local services, fetch installed models or use an override."))
                    .font(.caption).foregroundStyle(.secondary)
                CredentialEditor(endpoint: model.settings.textEndpoint).id(model.settings.textEndpoint)
            }
            Section(L("Available Models")) {
                HStack {
                    Button(L("Fetch Models")) { fetchModels() }.disabled(loadingModels)
                    if loadingModels { ProgressView().controlSize(.small).transition(.pop) }
                    if let connectionStatus {
                        Text(connectionStatus.text).font(.caption).foregroundStyle(.secondary).transition(.opacity)
                    }
                }
                .animation(Motion.quick, value: loadingModels)
                Text(L("Run Ollama locally with an installed text model. Online services use HTTPS; keys are saved separately for each API base URL. Fetching models does not run inference."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(model.busy)
        .animation(Motion.content, value: models)
        .animation(Motion.content, value: model.settings.textProvider)
        .onChange(of: model.settings.textEndpoint) { _, _ in models = []; connectionStatus = nil }
        .onChange(of: model.settings.textProvider) { _, _ in
            model.settings.textModel = model.settings.textModelPresets.first ?? ""
            model.settings.textModelOverride = nil
        }
    }
    private var textModels: [String] {
        let presets = model.settings.textModelPresets
        return presets + models.filter { !presets.contains($0) }
    }
    private var chunkedLocalNote: some View {
        Section {
            Text(L("Live transcription updates about every 8 seconds; files are processed in 20-second chunks. Stopping also transcribes the remaining audio. Recognition stays on this Mac."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func localeName(_ identifier: String) -> String {
        InterfaceLanguage.current.locale.localizedString(forIdentifier: identifier) ?? identifier
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
        let workspace = model.settings.anthropicWorkspaceID
        Task {
            defer { loadingModels = false }
            do {
                let key = try KeychainStore.read(endpoint: endpoint)
                let fetched = try await APIClient().models(endpoint: endpoint, provider: provider, key: key, workspace: workspace)
                guard endpoint == model.settings.textEndpoint, provider == model.settings.textProvider else { return }
                models = fetched
                connectionStatus = LocalizedText("Models found: %@", String(models.count))
            } catch { model.error = LocalizedText(error: error) }
        }
    }
}

private struct ModelNamePicker: View {
    let presets: [String]
    @Binding var selection: String
    @Binding var overrideName: String?

    var body: some View {
        Picker(L("Model"), selection: $selection) {
            if !presets.contains(selection) {
                Text(selection.isEmpty ? L("Select Model") : selection).tag(selection)
            }
            ForEach(presets, id: \.self) { Text($0).tag($0) }
        }.disabled(overrideName != nil)
        Toggle(L("Override Model Name"), isOn: Binding(get: { overrideName != nil }, set: {
            overrideName = $0 ? selection : nil
        }))
        if overrideName != nil {
            TextField(L("Custom Model Name"), text: Binding(get: { overrideName ?? "" }, set: { overrideName = $0 }))
        }
    }
}

/// One downloadable model: an icon tile that fills in when the model is in use, its name and size, and its actions.
/// Choosing a model, or finishing its download, draws the Selected checkmark.
private struct ModelRow<Accessory: View>: View {
    let title: String
    let detail: String
    let symbol: String
    var link: URL?
    let inUse: Bool
    var accessory: Accessory
    @State private var initiallyInUse: Bool

    init(title: String, detail: String, symbol: String, link: URL? = nil, inUse: Bool, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.link = link; self.inUse = inUse
        self.accessory = accessory()
        _initiallyInUse = State(initialValue: inUse)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(inUse ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 32, height: 32)
                .background(inUse ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.12)), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                HStack(spacing: 8) {
                    Text(detail)
                    if let link { Link(L("Model Card & License"), destination: link) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if inUse {
                HStack(spacing: 5) {
                    DrawnCheckmark(animated: !initiallyInUse)
                    Text(L("Selected"))
                }
                .font(.callout)
                .foregroundStyle(.tint)
                .transition(.opacity)
            }
            accessory
        }
        .padding(.vertical, 3)
        .animation(Motion.quick, value: inUse)
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
            if let message { Text(message.text).font(.caption).foregroundStyle(.secondary).transition(.rise) }
        }
        .animation(Motion.content, value: message)
        .task {
            do { key = try KeychainStore.read(endpoint: endpoint) }
            catch { message = LocalizedText(error: error) }
        }
    }
}
