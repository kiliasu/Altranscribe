import Foundation

public enum LiveChunkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, short, balanced, long
    public var id: String { rawValue }
    public var seconds: Double {
        switch self { case .automatic: 4; case .short: 2; case .balanced: 4; case .long: 8 }
    }
    public var title: String {
        switch self {
        case .automatic: L("Automatic")
        case .short: L("2 seconds · Faster")
        case .balanced: L("4 seconds · Balanced")
        case .long: L("8 seconds · More context")
        }
    }
}

/// Live batch engines cut at a short pause, with a bounded wait during continuous speech.
/// Streaming engines use fixed, small transport blocks and retain their own acoustic context.
public struct LiveAudioChunker: Sendable {
    private var pending: [Float] = []
    private var offset = 0
    private var scanned = 0
    private var quietSamples = 0
    private var voiceSamples = 0
    private var noise: Float = 0.0001
    private let maximum: Int
    private let automatic: Bool
    public init(seconds: Double, automatic: Bool = false) {
        maximum = max(1, Int(seconds * 16_000)); self.automatic = automatic
    }
    public mutating func append(_ samples: [Float]) -> [AudioChunk] {
        pending.append(contentsOf: samples)
        var chunks: [AudioChunk] = []
        while scanned < pending.count {
            let count = min(320, maximum - scanned)
            guard scanned + count <= pending.count else { break }
            let energy = pending[scanned..<(scanned + count)].reduce(Float.zero) { $0 + $1 * $1 }
            let rms = sqrt(energy / Float(count))
            noise += (rms < noise ? 0.1 : 0.002) * (rms - noise)
            let quiet = rms < max(0.0002, noise * 1.8)
            quietSamples = quiet ? quietSamples + count : 0
            if !quiet { voiceSamples += count }
            scanned += count
            if scanned >= maximum || (automatic && voiceSamples >= 800 && scanned >= 48_000 && quietSamples >= 4_800) {
                chunks.append(take(scanned))
            }
        }
        return chunks
    }
    private mutating func take(_ count: Int) -> AudioChunk {
        let chunk = AudioChunk(samples: Array(pending.prefix(count)), start: Double(offset) / 16_000,
                               containsSpeech: voiceSamples >= 800 || (!automatic && maximum < 16_000))
        pending.removeFirst(count); offset += count; scanned = 0; quietSamples = 0; voiceSamples = 0
        return chunk
    }
    public mutating func flush() -> AudioChunk? { pending.isEmpty ? nil : take(pending.count) }
    public var duration: Double { Double(offset + pending.count) / 16_000 }
}

/// Conservative level riding for quiet/distant speech, not a replacement for noise removal.
/// A noise-floor estimate holds gain during silence; a peak limiter prevents clipping.
public struct AdaptiveInputGain: Sendable {
    private var previousInput: Float = 0
    private var previousOutput: Float = 0
    private var noise: Float = 0.0001
    public private(set) var gain: Float = 1
    public init() {}

    public mutating func process(_ samples: [Float]) -> [Float] {
        var output = samples
        for start in stride(from: 0, to: output.count, by: 320) {
            let end = min(start + 320, output.count)
            var energy: Float = 0, peak: Float = 0
            for i in start..<end {
                // Remove DC and low-frequency rumble before estimating speech level (80 Hz).
                let filtered = 0.969 * (previousOutput + output[i] - previousInput)
                previousInput = output[i]; previousOutput = filtered
                output[i] = filtered; energy += filtered * filtered; peak = max(peak, abs(filtered))
            }
            let rms = sqrt(energy / Float(end - start))
            noise += (rms < noise ? 0.1 : 0.002) * (rms - noise)
            let hasSignal = rms > max(0.00015, noise * 2.2)
            let desired: Float = hasSignal ? min(12, max(1, 0.06 / max(rms, 0.00001))) : 1
            let oldGain = gain
            gain += (desired < gain ? 0.25 : 0.08) * (desired - gain)
            let ceiling = peak > 0 ? 0.95 / peak : 12
            // Apply the limiter immediately; interpolate ordinary gain changes to avoid clicks.
            for i in start..<end {
                let ramp = oldGain + (gain - oldGain) * Float(i - start + 1) / Float(end - start)
                output[i] *= min(ramp, ceiling)
            }
        }
        return output
    }
}

/// Revise a bounded live audio window as slices arrive, retaining acoustic context across cuts.
/// A real pause starts a new window; a short Stop/Pause tail still repairs its preceding result.
struct LiveBatchTail: Sendable {
    private var previous: AudioChunk?
    private var previousSegments: [TranscriptSegment] = []
    private var replacing = false
    private var pause = SpeechPauseDetector()
    mutating func input(_ chunk: AudioChunk) -> AudioChunk {
        replacing = false
        var input = chunk
        if let previous, previous.containsSpeech,
           (chunk.duration < 1.2 || (chunk.containsSpeech && pause.duration < 0.7)),
           previous.duration + chunk.duration <= 12,
           abs(previous.start + previous.duration - chunk.start) < 0.01 {
            input = AudioChunk(samples: previous.samples + chunk.samples, start: previous.start,
                               containsSpeech: previous.containsSpeech || chunk.containsSpeech)
            replacing = true
        }
        pause.accept(chunk.samples[...])
        if !replacing { previousSegments = [] }
        previous = input
        return input
    }
    mutating func results(_ lines: [TranscriptSegment]) -> [TranscriptSegment] {
        var lines = lines
        if replacing {
            for index in lines.indices where previousSegments.indices.contains(index) { lines[index].id = previousSegments[index].id }
            if lines.count < previousSegments.count {
                for old in previousSegments.dropFirst(lines.count) {
                    var removed = old; removed.text = ""; removed.translation = nil
                    lines.append(removed)
                }
            }
        }
        previousSegments = lines.filter { !$0.text.isEmpty }
        return lines
    }
}
