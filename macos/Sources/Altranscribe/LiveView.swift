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
                TranscriptScroll(record: record, live: live) {
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
                FlowLayout(alignment: .center, spacing: 8, lineSpacing: 8) {
                    InfoChip(title: engine, symbol: model.settings.speechProvider.isLocal ? "cpu" : "cloud")
                    if model.settings.speechProvider != .nemotron || model.settings.nemotronModel.multilingual {
                        InfoChip(title: languageName(model.settings.recognitionLanguage), symbol: "globe").transition(.pop)
                    }
                    if model.settings.translate {
                        InfoChip(title: L("Translate") + " → " + languageName(model.settings.targetLanguage), symbol: "translate")
                            .transition(.pop)
                    }
                    if model.settings.summarize { InfoChip(title: L("Summary"), symbol: "sparkles").transition(.pop) }
                    InfoChip(title: model.localProcessing ? L("On this Mac") : L("Uses an online API"),
                             symbol: model.localProcessing ? "lock.fill" : "network")
                }
                .frame(maxWidth: 520)
                .animation(Motion.content, value: model.settings)
                if !model.modelReady { ModelCallout().transition(.rise) }
            }
            .animation(Motion.content, value: model.modelReady)
            .padding(40)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(Motion.content, value: model.source)
        .animation(Motion.content, value: model.phase == .preparing)
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

/// The floating Liquid Glass controls for a live session. Each stage morphs into the next:
/// the source picker becomes "Preparing…", then the running time; Start becomes Cancel, then Stop & Save;
/// "Finishing…" closes with a drawn "Saved" before the picker and Start return.
struct TransportBar: View {
    @Bindable var model: AppModel
    @Namespace private var glass
    @State private var levels = [Float](repeating: 0, count: 26)
    @State private var confirmDiscard = false
    @State private var acknowledgedSave: Date?

    /// "Saved" takes the place of the source picker for a moment after Stop and Save.
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
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                switch stage {
                case .preparing: working(model.status.text, cancellable: true)
                case .capturing: capturing
                case .finishing: working(model.status.text, cancellable: false)
                case .idle: idle
                }
            }
        }
        .animation(Motion.glass, value: stage)
        .animation(Motion.glass, value: acknowledgingSave)
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
        } message: { Text(L("This deletes the transcript from this recording.")) }
    }

    @ViewBuilder private var idle: some View {
        if acknowledgingSave {
            HStack(spacing: 8) {
                DrawnCheckmark().foregroundStyle(.green)
                Text(L("Saved"))
            }
            .font(.title3.weight(.medium))
            .padding(.horizontal, 18)
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID("status", in: glass)
        } else {
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
        }

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
            RecordingDot(paused: paused)
            Text(timestamp(model.elapsed))
                .font(.title3.monospacedDigit().weight(.medium))
                .rollingNumbers(timestamp(model.elapsed))
            LevelHistory(levels: levels)
                .foregroundStyle(paused ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            if model.pendingTranslations > 0 {
                Label(String(model.pendingTranslations), systemImage: "translate")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .rollingNumbers(model.pendingTranslations)
                    .help(L("Pending translations: %@", String(model.pendingTranslations)))
                    .transition(.pop)
            }
        }
        .animation(Motion.quick, value: paused)
        .animation(Motion.quick, value: model.pendingTranslations > 0)
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
            Text(text).foregroundStyle(.secondary).contentTransition(.opacity)
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

/// Recording pulses red; pausing turns it a steady orange, so the state reads at a glance without words.
private struct RecordingDot: View {
    let paused: Bool
    var body: some View {
        Circle()
            .fill(paused ? Color.orange : Color.red)
            .frame(width: 9, height: 9)
            .phaseAnimator([1.0, 0.35]) { dot, value in
                dot.opacity(paused ? 1 : value)
            } animation: { _ in .easeInOut(duration: 0.9) }
    }
}
