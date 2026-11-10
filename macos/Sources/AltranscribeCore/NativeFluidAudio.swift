import Foundation
import FluidAudio

public enum FluidAudioModel: String, CaseIterable, Identifiable, Sendable {
    case english = "parakeet-tdt-0.6b-v2-coreml"
    case multilingual = "parakeet-tdt-0.6b-v3-coreml"
    case ultra = "parakeet-ultra-coreml"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .english: L("Parakeet v2 · English")
        case .multilingual: L("Parakeet v3 · Multilingual")
        case .ultra: L("Parakeet Ultra · Multilingual")
        }
    }
    private var version: AsrModelVersion {
        switch self { case .english: .v2; case .multilingual: .v3; case .ultra: .ultra }
    }
    private var repository: Repo {
        switch self { case .english: .parakeetV2; case .multilingual: .parakeetV3; case .ultra: .parakeetUltra }
    }
    public var modelCard: URL { URL(string: "https://huggingface.co/FluidInference/\(rawValue)")! }
    public func directory(in models: URL) -> URL {
        models.appendingPathComponent(repository.folderName, isDirectory: true)
    }
    public func isInstalled(in models: URL) -> Bool {
        AsrModels.modelsExist(at: directory(in: models), version: version)
    }
    /// `progress` receives the part of the model that has arrived, from 0 to 1.
    public func download(to models: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        var handler: ProgressHandler?
        if let progress { handler = { update in progress(update.fractionCompleted) } }
        try await AsrModels.download(to: directory(in: models), version: version, progressHandler: handler)
        try Task.checkCancellation()
    }
    fileprivate func load(from models: URL) throws -> AsrModels {
        // Only the explicit Download action may access the network.
        try AsrModels.loadLocal(from: directory(in: models), version: version)
    }
}

public actor NativeFluidAudio {
    private var manager: AsrManager?
    private var liveTail: LiveBatchTail?
    public init() {}

    public func load(model: FluidAudioModel, models: URL, live: Bool = false) async throws {
        try Task.checkCancellation()
        guard model.isInstalled(in: models) else {
            throw AppError("Download a FluidAudio model in Settings first.")
        }
        let manager = AsrManager()
        try await manager.loadModels(model.load(from: models))
        self.manager = manager
        liveTail = live ? LiveBatchTail() : nil
        try Task.checkCancellation()
    }

    public func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        guard let manager else { throw AppError("The local model is not loaded.") }
        let chunk = liveTail?.input(chunk) ?? chunk
        guard chunk.containsSpeech, !chunk.samples.isEmpty,
              chunk.samples.reduce(Float.zero, { $0 + $1 * $1 }) / Float(chunk.samples.count) >= 0.00000001 else { return [] }
        // Each capture/file chunk is independent; decoder state must not leak between files.
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(chunk.samples, decoderState: &state)
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let timings = result.tokenTimings ?? []
        let start = min(chunk.duration, max(0, timings.first?.startTime ?? 0))
        let end = min(chunk.duration, max(start, timings.last?.endTime ?? chunk.duration))
        let segments = [TranscriptSegment(start: chunk.start + start, end: chunk.start + end, text: text, estimated: timings.isEmpty)]
        return liveTail?.results(segments) ?? segments
    }

    public func unload() async {
        await manager?.cleanup()
        manager = nil; liveTail = nil
    }
}
