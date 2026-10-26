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
                SessionSummary(model: model)
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

}

/// What the next session will use, one row per decision. Each row opens the page that changes it,
/// and whatever would stop the session from starting is named on its row.
private struct SessionSummary: View {
    @Bindable var model: AppModel

    var body: some View {
        let settings = model.settings
        VStack(spacing: 0) {
            SummaryRow(symbol: settings.speechProvider.isLocal ? "cpu" : "cloud", title: L("Speech"),
                       value: settings.speechServiceTitle + " · " + settings.speechModelTitle(live: true),
                       warning: model.modelIssue?.text) { open(.speech) }
            if settings.usesCloudLive {
                SummaryRow(symbol: "waveform", title: L("Live Mode"),
                           value: settings.usesDirectSpeechTranslation ? L("Direct translation with source text") : L("Transcribe")) { open(.speech) }
            }
            SummaryRow(symbol: "character.bubble", title: L("Text Model"),
                       value: settings.needsTextModel(live: true)
                           ? (settings.effectiveTextModel.isEmpty ? L("Not configured") : settings.textServiceTitle + " · " + settings.effectiveTextModel)
                           : L("Not used"),
                       warning: settings.textModelMissing(live: true) ? L("Translation or summary needs a text model.") : nil) { open(.text) }
            SummaryRow(symbol: "translate", title: L("Translate"),
                       value: settings.translate
                           ? languageName(settings.targetLanguage) + (settings.usesDirectSpeechTranslation ? " · " + L("Direct from audio") : "")
                           : L("Off")) { open(.text) }
            SummaryRow(symbol: "sparkles", title: L("Summary"), value: settings.summarize ? L("On") : L("Off"), last: true) { open(.text) }
        }
        .frame(maxWidth: 520)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        .animation(Motion.content, value: settings)
        .animation(Motion.content, value: model.modelReady)
    }

    private func open(_ page: SettingsPage) { model.settingsPage = page; model.destination = .settings }
}

private struct SummaryRow: View {
    let symbol: String
    let title: String
    let value: String
    var warning: String? = nil
    var last = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(value).lineLimit(1).truncationMode(.middle)
                    if let warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .transition(.rise)
                    }
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
            .background(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) { if !last { Divider().padding(.leading, 48) } }
        .animation(Motion.quick, value: hovering)
    }
}

/// A bottom accessory bar. The system owns the controls' materials and interaction effects.
struct TransportBar: View {
    @Bindable var model: AppModel
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
        .buttonStyle(.bordered)
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

    @ViewBuilder private var status: some View {
        switch stage {
        case .idle:
            if acknowledgingSave {
                Label(L("Saved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Picker(L("Audio Source"), selection: $model.source) {
                    ForEach([AudioSource.microphone, .system]) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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

    @ViewBuilder private var actions: some View {
        switch stage {
        case .idle:
            Button(L("Start Transcription"), systemImage: "record.circle.fill") { model.startLive() }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(model.busy || !model.canStart(live: true))
                .help(L("Start Transcription") + " ⇧⌘R")
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
