import SwiftUI
import AltranscribeCore

struct LiveView: View {
    @Bindable var model: AppModel
    @AppStorage("showInspector") private var showInspector = true

    /// The session on screen: the one being captured, or the last one until a new session starts.
    private var record: TranscriptRecord? {
        guard model.phase != .preparing || model.queueRunning,
              let record = model.activeRecord, record.source != .file else { return nil }
        return record
    }
    private var live: LiveState? {
        switch model.phase {
        case .recording: .recording
        case .paused: .paused
        case .finishing: .finishing
        default: nil
        }
    }

    var body: some View {
        // A new session blurs the welcome page into its transcript; starting another blurs it back.
        ZStack {
            if let record {
                TranscriptScroll(record: record, live: live) { record in
                    RecordHeader(model: model, record: record, compact: true)
                }
                .transition(.page)
            } else {
                LiveWelcome(model: model).transition(.page)
            }
        }
        .animation(Motion.content, value: record?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .bottom) {
            TransportBar(model: model)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .navigationTitle(L("Live Transcription"))
        .navigationSubtitle(model.isCapturing || model.phase == .finishing ? model.status.text : model.source.title)
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $model.captionsVisible) { Label(L("Floating Captions"), systemImage: "captions.bubble") }
                    .toggleStyle(.button)
                    .help(L(model.captionsVisible ? "Hide Caption Window" : "Show Caption Window") + " ⇧⌘C")
            }
            ToolbarSpacer(.fixed)
            InspectorToggle(isPresented: $showInspector)
        }
    }
}

/// What the live page shows before the first session: the source, what the session will use, and what is missing.
private struct LiveWelcome: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: model.source.heroSymbol)
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.breathe, isActive: model.phase == .preparing)
                    .frame(width: 112, height: 112)
                    .background(.tint.opacity(model.phase == .preparing ? 0.16 : 0.1), in: .circle)
                VStack(spacing: 8) {
                    Text(L("Turn sound into words"))
                        .font(.largeTitle.weight(.bold))
                    Text(L("Capture a lecture, a meeting, or a thought. Choose an audio source to begin."))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                SessionSetup(model: model)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        // Content shorter than the page sits in the middle; taller content scrolls from the top.
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .animation(Motion.content, value: model.source)
        .animation(Motion.content, value: model.phase == .preparing)
    }
}

/// The next session at a glance, as standard capsule controls in the content layer. Each one changes its
/// setting in place and ends its menu with the settings page; whatever keeps the session from starting
/// is named once, underneath, with the one action that fixes it.
private struct SessionSetup: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let settings = model.settings
        VStack(spacing: 16) {
            FlowLayout(alignment: .center, spacing: 8, lineSpacing: 8) {
                speech
                if settings.offersLanguageChoice { language.transition(.pop) }
                translation
                Toggle(isOn: $model.settings.summarize) { Label(L("Summary"), systemImage: "sparkles") }
                    .toggleStyle(.button)
                    .help(L("Creates a summary with the text model when the session ends."))
                if settings.needsTextModel(live: true) { textModel.transition(.pop) }
            }
            if let notice { notice.transition(.rise) }
        }
        // Regular-size capsules stay secondary to the title and keep the usual setup on one line.
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .frame(maxWidth: 620)
        .disabled(model.busy)
        .animation(Motion.content, value: settings)
        .animation(Motion.content, value: model.modelReady)
    }

    private var speech: some View {
        let settings = model.settings
        let title = settings.speechSummary(live: true)
        return Menu {
            Picker(L("Speech Engine"), selection: $model.settings.speechProvider) {
                ForEach(SpeechProvider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            // Installed models switch in place; a live cloud session's model follows its translation choice.
            if !(settings.usesCloudLive) && !model.speechModelChoices.isEmpty {
                Picker(settings.speechProvider == .appleSpeech ? L("Language") : L("Model"),
                       selection: Binding(get: { model.selectedSpeechModel }, set: { model.selectedSpeechModel = $0 })) {
                    ForEach(model.speechModelChoices) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.inline)
            }
            Divider()
            Button(settings.speechProvider.isLocal ? L("Manage Models…") : L("Speech Settings…")) { open(.speech) }
        } label: {
            Label(title, systemImage: settings.speechProvider.isLocal ? "cpu" : "cloud")
                .lineLimit(1).truncationMode(.middle)
        }
        .help(title)
    }

    private var language: some View {
        Menu {
            Picker(L("Language"), selection: $model.settings.sourceLanguage) {
                ForEach(AppSettings.languages, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(languageName(model.settings.sourceLanguage), systemImage: "globe")
        }
        .help(L("Spoken Language"))
    }

    private var translation: some View {
        let settings = model.settings
        let title = settings.translate
            ? L("Translate to %@", languageName(settings.targetLanguage)) + (settings.usesDirectSpeechTranslation ? " · " + L("Direct from audio") : "")
            : L("No Translation")
        return Menu {
            Toggle(L("Translate"), isOn: $model.settings.translate)
            Picker(L("Target Language"), selection: $model.settings.targetLanguage) {
                ForEach(AppSettings.languages.filter { $0.0 != "auto" }, id: \.0) { Text($0.1).tag($0.0) }
            }
            if settings.usesCloudLive {
                // How a live session translates is a translation choice, so it lives here rather than with the engine.
                Picker(L("Live Translation"), selection: Binding(get: { settings.cloudDirectTranslation ?? true },
                                                                 set: { model.settings.cloudDirectTranslation = $0 })) {
                    Text(L("Directly from audio") + " · " + AppSettings.liveSpeechModel(provider: settings.speechProvider, direct: true)).tag(true)
                    Text(L("Transcribe, then use the text model")).tag(false)
                }
                .pickerStyle(.inline)
                .disabled(!settings.translate)
            }
            Divider()
            Button(L("Text Model Settings…")) { open(.text) }
        } label: {
            Label(title, systemImage: "translate").lineLimit(1)
        }
        .help(title)
    }

    private var textModel: some View {
        let settings = model.settings
        return Menu {
            TextModelMenuContent(model: model)
        } label: {
            if settings.effectiveTextModel.isEmpty {
                Label(L("Choose a Text Model"), systemImage: "exclamationmark.triangle.fill")
            } else {
                // Named like the speech control, so a bare model name is never mistaken for the engine.
                Label(L("Text") + " · " + settings.effectiveTextModel, systemImage: "character.bubble")
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .tint(settings.effectiveTextModel.isEmpty ? .orange : nil)
        .help(settings.textServiceTitle + (settings.effectiveTextModel.isEmpty ? "" : " · " + settings.effectiveTextModel))
    }

    /// One line for the first thing that keeps the session from starting.
    private var notice: SetupNotice? {
        if let issue = model.modelIssue {
            return SetupNotice(text: issue.text, action: model.settings.speechProvider == .appleSpeech ? L("Speech Settings…") : L("Manage Models…")) { open(.speech) }
        }
        if let issue = model.textIssue(live: true) {
            return SetupNotice(text: issue.text, action: L("Text Model Settings…")) { open(.text) }
        }
        return nil
    }

    /// Settings open in their own window, so the person stays on this page.
    private func open(_ page: SettingsPage) { model.settingsPage = page; openSettings() }
}

private struct SetupNotice: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).foregroundStyle(.secondary)
            Button(action, action: perform).buttonStyle(.link)
        }
        .font(.callout)
        .multilineTextAlignment(.center)
    }
}

/// A bottom accessory bar. The system owns the controls' materials and interaction effects.
struct TransportBar: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels = [Float](repeating: 0, count: 26)
    @State private var confirmDiscard = false
    @State private var acknowledgedSave: Date?

    private var acknowledgingSave: Bool {
        guard stage == .idle, let saved = model.sessionSavedAt, saved != acknowledgedSave else { return false }
        return Date.now.timeIntervalSince(saved) < Motion.acknowledgement
    }

    private enum Stage { case idle, preparing, capturing, finishing }
    private var stage: Stage {
        if model.queueRunning || model.isPostProcessing { return .idle }
        switch model.phase {
        case .preparing: return .preparing
        case .recording, .paused: return .capturing
        case .finishing: return .finishing
        case .idle, .files: return .idle
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                status
                Spacer(minLength: 16)
                actions
            }
            VStack(spacing: 12) {
                status
                actions
            }
        }
        .controlSize(.large)
        // The bar floats over content in the control layer, so its controls are Liquid Glass.
        .buttonStyle(.glass)
        .onChange(of: model.meter) { _, level in
            levels.removeFirst()
            levels.append(model.phase == .recording ? level : 0)
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .recording { levels = levels.map { _ in 0 } }
        }
        .task(id: model.sessionSavedAt) {
            guard let saved = model.sessionSavedAt else { return }
            let remaining = Motion.acknowledgement - Date.now.timeIntervalSince(saved)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            if !Task.isCancelled { acknowledgedSave = saved }
        }
        .confirmationDialog(L("Discard this recording?"), isPresented: $confirmDiscard) {
            Button(L("Discard"), role: .destructive) { model.cancel(discardRecording: true) }
        } message: { Text(L(model.activeRecord?.hasRecording == true
            ? "This deletes the transcript and its saved audio." : "This deletes the transcript from this recording.")) }
    }

    @ViewBuilder private var status: some View {
        switch stage {
        case .idle:
            if acknowledgingSave {
                Label(L("Saved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        AudioSourcePicker(selection: $model.source).fixedSize()
                        saveRecording
                    }
                    VStack(spacing: 12) {
                        AudioSourcePicker(selection: $model.source).fixedSize()
                        saveRecording
                    }
                }
                .disabled(model.busy)
            }
        case .preparing, .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.status.text).foregroundStyle(.secondary)
            }
        case .capturing:
            HStack(spacing: 10) {
                RecordingDot(paused: model.phase == .paused)
                Text(timestamp(model.elapsed)).monospacedDigit()
                LevelHistory(levels: levels).foregroundStyle(.secondary)
                if model.pendingTranslations > 0 {
                    Label(String(model.pendingTranslations), systemImage: "translate")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help(L("Pending translations: %@", String(model.pendingTranslations)))
                }
            }
        }
    }

    private var saveRecording: some View {
        Toggle(isOn: Binding(get: { model.settings.saveRecording ?? false }, set: { model.settings.saveRecording = $0 })) {
            Label(L("Save Recording"), systemImage: "waveform")
        }
        .toggleStyle(.button)
        .help(L("Keep an audio file alongside the transcript. Paused audio is excluded."))
        .accessibilityIdentifier("saveRecording")
    }

    @ViewBuilder private var actions: some View {
        switch stage {
        case .idle:
            HStack(spacing: 12) {
                if model.source == .microphone {
                    MicrophonePicker(selection: $model.settings.microphoneDeviceUID)
                        .disabled(model.busy)
                        .transition(.opacity)
                }
                Button(L("Start Transcription"), systemImage: "record.circle.fill") { model.startLive() }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .disabled(model.busy || !model.canStart(live: true))
                    .help(L("Start Transcription") + " ⇧⌘R")
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.1) : Motion.quick, value: model.source)
        case .preparing, .finishing:
            Button(L("Cancel")) { model.cancel() }
        case .capturing:
            HStack(spacing: 8) {
                ControlGroup {
                    Button { model.togglePause() } label: {
                        Label(model.phase == .paused ? L("Resume") : L("Pause"),
                              systemImage: model.phase == .paused ? "play.fill" : "pause.fill")
                    }
                    .help((model.phase == .paused ? L("Resume") : L("Pause")) + " ⇧⌘P")
                    Menu {
                        Button(L("Discard Recording…"), systemImage: "trash", role: .destructive) { confirmDiscard = true }
                    } label: { Label(L("More"), systemImage: "ellipsis") }
                    .menuIndicator(.hidden)
                }
                .labelStyle(.iconOnly)
                Button(L("Stop & Save"), systemImage: "stop.fill") { model.stopAndSave() }
                    .buttonStyle(.glassProminent)
                    .help(L("Stop and Save") + " ⇧⌘S")
            }
        }
    }
}

/// Recording pulses red; pausing turns it a steady orange, so the state reads at a glance without words.
private struct RecordingDot: View {
    let paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle()
            .fill(paused ? Color.orange : Color.red)
            .frame(width: 9, height: 9)
            .phaseAnimator([1.0, 0.35]) { dot, value in
                dot.opacity(paused || reduceMotion ? 1 : value)
            } animation: { _ in .easeInOut(duration: 0.9) }
    }
}
