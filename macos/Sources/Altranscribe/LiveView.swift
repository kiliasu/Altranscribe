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
        Group {
            if let record {
                TranscriptScroll(record: record, live: live) {
                    RecordHeader(model: model, record: record, compact: true)
                }
            } else {
                LiveWelcome(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .bottom) {
            TransportBar(model: model).padding(.bottom, 18)
        }
        .navigationTitle(L("Live Transcription"))
        .navigationSubtitle(model.isCapturing || model.phase == .finishing ? model.status.text : model.source.title)
        .toolbar {
            ToolbarItem {
                Button { model.showCaptions() } label: { Label(L("Floating Captions"), systemImage: "captions.bubble") }
                    .help(L("Floating Captions") + " ⇧⌘C")
            }
            ToolbarSpacer(.fixed)
            InspectorToggle(isPresented: $showInspector)
        }
    }
}

/// What the live page shows before the first session: the chosen source, how it will be processed, and what is missing.
private struct LiveWelcome: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: model.source.heroSymbol)
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 112, height: 112)
                    .background(.tint.opacity(0.1), in: .circle)
                    .symbolEffect(.variableColor.iterative, isActive: model.phase == .preparing)
                VStack(spacing: 8) {
                    Text(L("Turn sound into words"))
                        .font(.largeTitle.weight(.bold))
                    Text(L("Capture a lecture, a meeting, or a thought. Choose an audio source to begin."))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                FlowLayout(alignment: .center, spacing: 8, lineSpacing: 8) {
                    InfoChip(title: engine, symbol: model.settings.speechProvider.isLocal ? "cpu" : "cloud")
                    if model.settings.speechProvider != .nemotron || model.settings.nemotronModel.multilingual {
                        InfoChip(title: languageName(model.settings.recognitionLanguage), symbol: "globe")
                    }
                    if model.settings.translate {
                        InfoChip(title: L("Translate") + " → " + languageName(model.settings.targetLanguage), symbol: "translate")
                    }
                    if model.settings.summarize { InfoChip(title: L("Summary"), symbol: "sparkles") }
                    InfoChip(title: model.localProcessing ? L("On this Mac") : L("Uses an online API"),
                             symbol: model.localProcessing ? "lock.fill" : "network")
                }
                .frame(maxWidth: 520)
                if !model.modelReady { ModelCallout() }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(.smooth, value: model.source)
    }

    private var engine: String {
        switch model.settings.speechProvider {
        case .nemotron: model.settings.nemotronModel.multilingual ? L("Nemotron 3.5 · Multilingual") : L("Nemotron · English")
        case .whisper: "Whisper · " + URL(fileURLWithPath: model.settings.effectiveModelPath).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "ggml-", with: "")
        case .compatible, .gemini: model.settings.speechProvider.title
        }
    }
}

private struct ModelCallout: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("A speech model is needed")).font(.headline)
                Text(L("Download one in Settings to transcribe on this Mac."))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            SettingsLink { Text(L("Download a Local Model")) }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
    }
}

/// The floating Liquid Glass controls for a live session. The pieces morph into each other as the session moves on.
struct TransportBar: View {
    @Bindable var model: AppModel
    @Namespace private var glass
    @State private var levels = [Float](repeating: 0, count: 26)
    @State private var confirmDiscard = false

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if model.queueRunning || model.isPostProcessing { idle }
                else {
                    switch model.phase {
                    case .preparing: working(model.status.text, cancellable: true)
                    case .recording, .paused: capturing
                    case .finishing: working(model.status.text, cancellable: false)
                    case .idle, .files: idle
                    }
                }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: model.phase)
        .onChange(of: model.meter) { _, level in
            levels.removeFirst()
            levels.append(model.phase == .recording ? level : 0)
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .recording { levels = levels.map { _ in 0 } }
        }
        .confirmationDialog(L("Discard this recording?"), isPresented: $confirmDiscard) {
            Button(L("Discard"), role: .destructive) { model.cancel(discardRecording: true) }
        } message: { Text(L("This deletes the transcript from this recording.")) }
    }

    @ViewBuilder private var idle: some View {
        Picker(L("Audio Source"), selection: $model.source) {
            ForEach([AudioSource.microphone, .system]) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.large)
        .padding(5)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("status", in: glass)
        .disabled(model.busy)

        Button { model.startLive() } label: {
            Label(L("Start Transcription"), systemImage: "record.circle.fill")
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(.red)
        .controlSize(.extraLarge)
        .glassEffectID("primary", in: glass)
        .disabled(model.busy || !model.modelReady)
        .help(L("Start Transcription") + " ⇧⌘R")
    }

    @ViewBuilder private var capturing: some View {
        let paused = model.phase == .paused
        Button { model.togglePause() } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.extraLarge)
        .glassEffectID("pause", in: glass)
        .help((paused ? L("Resume") : L("Pause")) + " ⇧⌘P")

        HStack(spacing: 12) {
            Circle()
                .fill(paused ? Color.orange : Color.red)
                .frame(width: 9, height: 9)
                .opacity(paused ? 1 : 0.9)
                .phaseAnimator([1.0, 0.35], trigger: paused) { dot, value in dot.opacity(paused ? 1 : value) }
            Text(timestamp(model.elapsed))
                .font(.title3.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
            LevelHistory(levels: levels)
                .foregroundStyle(paused ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            if model.pendingTranslations > 0 {
                Label(String(model.pendingTranslations), systemImage: "translate")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(L("Pending translations: %@", String(model.pendingTranslations)))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("status", in: glass)

        Button { model.stopAndSave() } label: {
            Label(L("Stop & Save"), systemImage: "stop.fill").padding(.horizontal, 4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .glassEffectID("primary", in: glass)
        .help(L("Stop and Save") + " ⇧⌘S")

        Menu {
            Button(L("Discard Recording…"), systemImage: "trash", role: .destructive) { confirmDiscard = true }
        } label: {
            Image(systemName: "ellipsis").frame(width: 22, height: 22)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.extraLarge)
        .glassEffectID("more", in: glass)
    }

    @ViewBuilder private func working(_ text: String, cancellable: Bool) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("status", in: glass)
        if cancellable {
            Button(L("Cancel")) { model.cancel() }
                .buttonStyle(.glass)
                .controlSize(.extraLarge)
                .glassEffectID("primary", in: glass)
        }
    }
}
