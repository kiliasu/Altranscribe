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
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        // Keep the scroll container (and its toolbar edge effect) alive when changing pages;
        // only the sections inside rise into place.
        Form { pane }
        .formStyle(.grouped)
        .frame(width: embedded ? nil : 600, height: embedded ? nil : 620)
        .background { if !embedded { UnifiedToolbarWindow() } }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .animation(Motion.content, value: model.settingsPage)
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
        // A local text service costs nothing to ask, so its model list loads as soon as the page opens.
        .task(id: "\(model.settingsPage)|\(model.settings.textEndpoint)") {
            guard model.settingsPage == .text, model.settings.textProvider == .compatible, models.isEmpty,
                  (try? APIEndpoint(model.settings.textEndpoint).isLoopback) == true else { return }
            fetchModels(quietly: true)
        }
        .alert(L("Attention"), isPresented: Binding(get: { !embedded && model.error != nil && appearsActive },
                                                    set: { if !$0 && appearsActive { model.error = nil } })) {
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
        if model.busy && model.settingsPage != .general {
            Section {
                Label(L("A session is running. Speech and text settings unlock when it ends."), systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            .transition(.swap)
        }
        switch model.settingsPage {
        case .general: general.transition(.swap)
        case .speech: speech.transition(.swap)
        case .text: text.transition(.swap)
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
                CaptionControls(model: model)
                Button(L("Show Caption Window")) { model.showCaptions() }
            }
            Section(L("Data & Privacy")) {
                LabeledContent(L("Recording Location")) {
                    Button(L("Open in Finder")) {
                        do {
                            try FileManager.default.createDirectory(at: model.paths.recordings, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(model.paths.recordings)
                        } catch { model.error = LocalizedText(error: error) }
                    }
                }
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

    // MARK: - Speech

    private var speech: some View {
        Group {
            Section {
                Picker(L("Speech Engine"), selection: $model.settings.speechProvider) {
                    ForEach(SpeechProvider.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.offersLanguageChoice {
                    Picker(L("Language"), selection: $model.settings.sourceLanguage) {
                        ForEach(AppSettings.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
            }
            Section {
                if model.settings.usesBatchLiveAudio {
                    Picker(L("Live Audio Chunks"), selection: Binding(get: { model.settings.liveChunkMode ?? .automatic },
                        set: { model.settings.liveChunkMode = $0 })) {
                        ForEach(LiveChunkMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(L("Automatic cuts at pauses and waits at most 4 seconds. Shorter chunks respond faster but have less context."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(L("Continuous streaming · No audio slicing"), systemImage: "waveform")
                        .foregroundStyle(.secondary)
                }
                Toggle(L("Adaptive gain for quiet speech"), isOn: Binding(get: { model.settings.adaptiveInputGain ?? true },
                    set: { model.settings.adaptiveInputGain = $0 }))
                Toggle(L("Apple microphone voice processing"), isOn: Binding(get: { model.settings.microphoneVoiceProcessing ?? false },
                    set: { model.settings.microphoneVoiceProcessing = $0 }))
            } header: { Text(L("Live Audio")) }
              footer: { Text(L("Gain helps quiet or distant voices. Apple's microphone processing reduces noise but may suppress distant speakers; leave it off for lectures or virtual inputs. It only processes microphone input and may lower other apps' audio.")) }
            switch model.settings.speechProvider {
            case .whisper: whisper
            case .nemotron: nemotron
            case .fluidAudio: fluidAudio
            case .appleSpeech: appleSpeech
            case .compatible, .gemini: cloudSpeech
            }
            if model.settings.supportsVocabulary {
                Section {
                    SettingsTextField(L("Vocabulary"), text: $model.settings.vocabulary,
                                      prompt: L("Names and terms, separated by commas"), multiline: true)
                } header: { Text(L("Vocabulary")) }
                  footer: { Text(L("Helps recognize names and terms without rewriting the original text.")) }
            }
        }
        .disabled(model.busy)
        // Switching engines, downloads finishing and models being deleted all rearrange the pane as content.
        .animation(Motion.content, value: model.settings.speechProvider)
        .animation(Motion.quick, value: model.downloadID)
        .animation(Motion.quick, value: model.modelRevision)
    }

    @ViewBuilder private var whisper: some View {
        Section(L("On-device Compute")) {
            Toggle(L("Use Metal GPU Acceleration"), isOn: $model.settings.useGPU)
            LabeledContent(L("Current Model")) {
                Text(model.settings.speechModelTitle(live: true)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(model.settings.effectiveModelPath.isEmpty ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
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
    }

    @ViewBuilder private var nemotron: some View {
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
    }

    @ViewBuilder private var fluidAudio: some View {
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
    }

    @ViewBuilder private var appleSpeech: some View {
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
        Section {
            Text(L("Apple Speech streams words as you speak. Stable phrases are translated without waiting for a long pause; stopping finalizes the last words."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cloudSpeech: some View {
        let provider = model.settings.speechProvider
        Section(L("Service")) {
            if provider == .compatible {
                SettingsTextField(L("Service URL"), text: $model.settings.speechBaseURL, prompt: "https://api.openai.com/v1")
                if !model.settings.usesCloudLive {
                    Label(L("A custom endpoint must implement audio/transcriptions. Live audio follows the chunk setting above; Realtime transcription is OpenAI only."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Button(L("Use OpenAI Endpoint")) { model.settings.speechBaseURL = "https://api.openai.com/v1" }
                }
            }
            CredentialEditor(endpoint: model.settings.speechEndpoint).id(model.settings.speechEndpoint)
        }
        if model.settings.usesCloudLive {
            Section {
                // Two short segments behave the same for every provider; the models are named underneath.
                Picker(L("Live Mode"), selection: Binding(get: { model.settings.cloudDirectTranslation ?? true },
                                                          set: { model.settings.cloudDirectTranslation = $0 })) {
                    Text(L("Transcribe")).tag(false)
                    Text(L("Translate Directly")).tag(true)
                }
                .pickerStyle(.segmented)
                LabeledContent(L("In Effect")) {
                    Label(model.settings.liveSpeechModel, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
                if (model.settings.cloudDirectTranslation ?? true) && !model.settings.translate {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label(L("Translation is off, so live sessions transcribe. Turn on Translate to translate directly from audio."), systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(L("Turn On Translate")) { model.settings.translate = true }
                    }
                }
            } header: { Text(L("Live Speech")) }
              footer: { Text(L("Transcription uses %@. Direct translation uses %@, returns both the original and translated text, and needs only the speech key. Generated audio is never played, but the service still bills it.",
                               AppSettings.liveSpeechModel(provider: provider, direct: false), AppSettings.liveSpeechModel(provider: provider, direct: true))) }
        }
        Section(L("File Transcription")) {
            if provider == .compatible {
                ModelChoice(presets: OpenAITranscriptionModel.allCases.map(\.rawValue),
                            label: { name in OpenAITranscriptionModel(rawValue: name)?.isDeprecated == true ? name + " · " + L("legacy") : name },
                            selection: $model.settings.speechModel, custom: $model.settings.speechModelOverride)
                if model.settings.openAITranscriptionModel?.isDeprecated == true {
                    Text(L("This legacy OpenAI model is scheduled to shut down on February 26, 2027. For new use, choose gpt-transcribe."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.settings.openAITranscriptionModel == .diarize {
                    Text(L("This model does not accept vocabulary hints. This app uses its text output without speaker labels."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                LabeledContent(L("File Transcription Model"), value: model.settings.effectiveGeminiSpeechModel)
            }
        }
        Section {
            Text(model.settings.usesCloudLive ?
                 L("Files use chunks of up to ten minutes. Live cloud sessions renew before expiry. Timestamps are estimates; paid requests are not replayed automatically.") :
                 L("Custom endpoints use the live chunk setting above and chunks of up to ten minutes for files."))
                .font(.caption).foregroundStyle(.secondary)
            if provider == .gemini {
                Text(L("Gemini live translation is a preview. If the service does not confirm finalization, the saved record asks you to review the last sentence."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Text

    private var text: some View {
        Group {
            Section(L("Text Processing")) {
                Toggle(L("Translate"), isOn: $model.settings.translate)
                Picker(L("Target Language"), selection: $model.settings.targetLanguage) {
                    ForEach(AppSettings.languages.filter { $0.0 != "auto" }, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle(L("Summarize when finished"), isOn: $model.settings.summarize)
            }
            Section {
                Picker(L("Text Service"), selection: Binding(get: { model.settings.textProvider },
                                                             set: { switchService(provider: $0) })) {
                    ForEach(TextProvider.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.textProvider == .compatible {
                    SettingsTextField(L("API Base URL"), text: $model.settings.textBaseURL, prompt: "http://127.0.0.1:11434/v1")
                    LabeledContent(L("Quick Fill")) {
                        HStack(spacing: 8) {
                            Button("Ollama") { switchService(baseURL: "http://127.0.0.1:11434/v1") }
                            Button("OpenAI") { switchService(baseURL: "https://api.openai.com/v1") }
                        }
                    }
                }
                if model.settings.textProvider == .apple {
                    LabeledContent(L("Model"), value: NativeAppleText.modelName)
                    if let issue = NativeAppleText.availabilityIssue {
                        Label(issue.text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Label(L("Ready on this Mac"), systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                } else {
                    ModelChoice(presets: model.settings.textModelPresets, fetched: models,
                            selection: $model.settings.textModel, custom: $model.settings.textModelOverride)
                    LabeledContent(L("Model List")) {
                        HStack(spacing: 8) {
                            if let connectionStatus {
                                Text(connectionStatus.text).font(.caption).foregroundStyle(.secondary).transition(.opacity)
                            }
                            if loadingModels { ProgressView().controlSize(.small).transition(.opacity) }
                            Button(L("Fetch Models")) { fetchModels() }.disabled(loadingModels)
                        }
                        .animation(Motion.quick, value: loadingModels)
                    }
                    if model.settings.textProvider == .anthropic {
                        SettingsTextField(L("Workspace ID (optional)"),
                                          text: Binding(get: { model.settings.anthropicWorkspaceID ?? "" }, set: { model.settings.anthropicWorkspaceID = $0 }),
                                          prompt: "wrkspc_…")
                    }
                    CredentialEditor(endpoint: model.settings.textEndpoint).id(model.settings.textEndpoint)
                }
            } header: { Text(L("Service")) } footer: { Text(serviceNote) }
        }
        .disabled(model.busy)
        .animation(Motion.content, value: models)
        .animation(Motion.content, value: model.settings.textProvider)
        .onChange(of: model.settings.textEndpoint) { _, _ in models = []; connectionStatus = nil }
    }

    private var serviceNote: String {
        switch model.settings.textProvider {
        case .compatible:
            L("File translation and summaries use this text model; live direct speech translation uses the speech service. Ollama must be running with a text model installed; a local model list loads automatically. Online services use HTTPS, and keys are saved separately for each API base URL.")
        case .gemini, .anthropic:
            L("File translation and summaries use this text model; live direct speech translation uses the speech service. Keys are saved separately for each API base URL. Fetching the model list does not run inference.")
        case .apple:
            L("Translation and summaries run on this Mac with Apple's system model. No API key or bundled model is needed. Long transcripts are summarized in sections. Requires Apple Intelligence to be enabled and ready.") + "\n\n" +
            L("Apple's content checks can reject ordinary quotations or sensitive topics. Translation and summaries may be refused; if this happens often, choose another text service.")
        }
    }
    private func switchService(provider: TextProvider? = nil, baseURL: String? = nil) {
        model.settings.switchTextService(provider: provider, baseURL: baseURL)
        models = []; connectionStatus = nil
    }
    private var chunkedLocalNote: some View {
        Section {
            Text(L("Live audio follows the chunk setting above. Files use 20-second chunks. Stopping retains the final audio. Recognition stays on this Mac."))
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
    /// Lists the service's models. A quiet fetch, run on the page's behalf, reports failure inline
    /// instead of raising the app's alert.
    private func fetchModels(quietly: Bool = false) {
        loadingModels = true; connectionStatus = nil
        let endpoint = model.settings.textEndpoint
        let provider = model.settings.textProvider
        let workspace = model.settings.anthropicWorkspaceID
        Task {
            defer { loadingModels = false }
            do {
                let key = try await KeychainStore.read(endpoint: endpoint)
                let fetched = try await APIClient().models(endpoint: endpoint, provider: provider, key: key, workspace: workspace)
                guard endpoint == model.settings.textEndpoint, provider == model.settings.textProvider else { return }
                models = fetched
                connectionStatus = LocalizedText("Models found: %@", String(models.count))
            } catch {
                if quietly { connectionStatus = LocalizedText("Model list unavailable: %@", LocalizedText(error: error).text) }
                else { model.error = LocalizedText(error: error) }
            }
        }
    }
}

/// A labelled row with a visible, bordered field, so the prompt reads as a placeholder and
/// never as the row's title.
struct SettingsTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String
    var multiline = false

    init(_ title: String, text: Binding<String>, prompt: String, multiline: Bool = false) {
        self.title = title; _text = text; self.prompt = prompt; self.multiline = multiline
    }

    var body: some View {
        LabeledContent(title) {
            TextField("", text: $text, prompt: Text(prompt), axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 2...4 : 1...1)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 420)
        }
    }
}

/// The service's models plus a Custom entry that reveals a name field. A custom name, or a chosen
/// name the service's list does not confirm, is flagged where it is chosen.
private struct ModelChoice: View {
    let presets: [String]
    var fetched: [String] = []
    var label: (String) -> String = { $0 }
    @Binding var selection: String
    @Binding var custom: String?
    private static let customTag = "\u{1}custom"

    private var options: [String] { presets + fetched.filter { !presets.contains($0) } }

    var body: some View {
        Picker(L("Model"), selection: Binding(get: { custom != nil ? Self.customTag : selection }, set: { value in
            if value == Self.customTag { custom = custom ?? selection } else { custom = nil; selection = value }
        })) {
            if custom == nil && !options.contains(selection) {
                Text(selection.isEmpty ? L("Select Model") : selection).tag(selection)
            }
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            Divider()
            Text(L("Custom Name…")).tag(Self.customTag)
        }
        if custom != nil {
            SettingsTextField(L("Custom Model Name"), text: Binding(get: { custom ?? "" }, set: { custom = $0 }),
                              prompt: L("Exactly as the service names it"))
            Label(L("A custom model name is in use. The app has not checked it against the service."), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if !presets.isEmpty && !selection.isEmpty && !options.contains(selection) {
            Label(L("This model is not in the service's preset list. Fetch the model list to check it."), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
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
            // The tile stays the same; the Selected mark alone says which model is in use.
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 8))
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

/// Saves one API key for an endpoint. The stored key is never shown again; the row says whether
/// one is saved, and a new entry replaces it.
struct CredentialEditor: View {
    let endpoint: String
    @State private var key = ""
    @State private var configured = false
    @State private var saving = false
    @State private var message: LocalizedText?

    var body: some View {
        LabeledContent(L("API Key")) {
            HStack(spacing: 8) {
                SecureField("", text: $key, prompt: Text(configured ? L("Enter a new key to replace the saved one") : L("Paste the key for this service")))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit(save)
                Button(L("Save Key"), action: save)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if configured {
                    Button(L("Remove"), action: remove)
                }
            }
        }
        .disabled(saving)
        HStack(spacing: 6) {
            Image(systemName: configured ? "checkmark.seal.fill" : "key")
                .foregroundStyle(configured ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            Text(message?.text ?? (configured ? L("Saved in Keychain for this API address.") : L("No key saved. Local services can go without one.")))
        }
        .font(.caption).foregroundStyle(.secondary)
        .animation(Motion.quick, value: configured)
        .task(id: endpoint) {
            do { configured = try await KeychainStore.contains(endpoint: endpoint) }
            catch is CancellationError { }
            catch { message = LocalizedText(error: error) }
        }
    }

    private func save() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        updateKey(value)
    }
    private func remove() { updateKey("") }
    private func updateKey(_ value: String) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await KeychainStore.save(value, endpoint: endpoint)
                key = ""; configured = !value.isEmpty
                message = LocalizedText(value.isEmpty ? "The saved key was removed." : "Saved to Keychain")
            } catch { message = LocalizedText(error: error) }
        }
    }
}

/// Gives the Settings window the main window's unified toolbar, so its page picker is the same large toolbar control
/// on a glass platter beside the window buttons. SwiftUI's Settings scene keeps the preference toolbar style whatever
/// the scene asks for, and that style puts a smaller picker in a row of its own below the window buttons.
private struct UnifiedToolbarWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowStyler() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowStyler: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window.toolbarStyle != .unified { window.toolbarStyle = .unified }
        }
    }
}
