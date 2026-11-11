@preconcurrency import AVFoundation
import Foundation

/// AVAssetReader decodes incrementally; an hour-long recording is never loaded into memory.
public actor MediaDecoder {
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: [Float] = []
    private var delivered = 0
    private var expectedSamples = 0
    private var deferredBuffer: (samples: [Float], start: Int)?
    private let chunkSize: Int
    private let boostQuietAudio: Bool
    private var gain: Float = 1
    public init(chunkSeconds: Int = 20, boostQuietAudio: Bool = false) {
        chunkSize = max(1, min(600, chunkSeconds)) * 16_000
        self.boostQuietAudio = boostQuietAudio
    }

    public func open(_ url: URL) async throws -> Double {
        try Task.checkCancellation()
        gain = 1
        let duration = try await openReader(url)
        if boostQuietAudio {
            // One gain for the whole file keeps its dynamics, chunks and timing, and a loud passage
            // near the end limits it too. So the file is read through once before it is decoded.
            var level = QuietAudioLevel()
            while let chunk = try next() { level.measure(chunk.samples) }
            gain = level.gain
            _ = try await openReader(url)
        }
        return duration
    }

    private func openReader(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AppError("This file has no readable audio track.")
        }
        let duration = try await asset.load(.duration).seconds
        let range = try await track.load(.timeRange)
        let sourceOrigin = max(0, range.start.seconds.isFinite ? range.start.seconds : 0)
        delivered = Int(sourceOrigin * 16_000)
        expectedSamples = delivered
        pending = []
        deferredBuffer = nil
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw decodeError() }
        reader.add(output)
        guard reader.startReading() else { throw decodeError() }
        self.reader = reader; self.output = output
        return duration.isFinite ? max(duration, 0) : 0
    }

    public func next() throws -> AudioChunk? {
        try Task.checkCancellation()
        guard let output, let reader else { return nil }
        if pending.isEmpty, let deferred = deferredBuffer {
            delivered = deferred.start
            pending = deferred.samples
            expectedSamples = delivered + pending.count
            deferredBuffer = nil
        }
        while pending.count < chunkSize, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length % MemoryLayout<Float>.size == 0 else { throw decodeError() }
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw decodeError() }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if pts.isFinite {
                let offset = max(0, Int((pts * 16_000).rounded()))
                if abs(offset - expectedSamples) > 160 {
                    // End the current chunk at a discontinuity instead of allocating the silence gap.
                    if !pending.isEmpty { deferredBuffer = (floats, offset); break }
                    delivered = offset
                }
            }
            pending.append(contentsOf: floats)
            expectedSamples = delivered + pending.count
        }
        if reader.status == .failed { throw decodeError() }
        guard !pending.isEmpty else { return nil }
        let count = min(chunkSize, pending.count)
        let samples = gain == 1 ? Array(pending.prefix(count)) : QuietAudioLevel.raise(pending.prefix(count), by: gain)
        let chunk = AudioChunk(samples: samples, start: Double(delivered) / 16_000)
        pending.removeFirst(count)
        delivered += count
        return chunk
    }
    public func cancel() { reader?.cancelReading(); reader = nil; output = nil; pending = []; deferredBuffer = nil }
    private func decodeError() -> AppError {
        AppError("macOS could not decode this media file. Convert it to WAV, M4A or MP4 first.")
    }
}

/// How loud a recording's speech is as a whole, and how much to raise it when it is quiet.
///
/// The level is the one that 99.9% of the samples stay below. The loudest single sample says little
/// about speech: a knock on the desk or a cough near the microphone reaches full scale in a lecture that
/// is otherwise 40 dB down, and judged by its peak such a recording would never be raised. The few
/// samples above the level are rounded off under full scale instead.
struct QuietAudioLevel {
    /// Where the level is brought to: -6 dBFS, about where the peaks of ordinary speech sit.
    static let target: Float = 0.5
    /// 25 dB. More would mostly raise the noise of a recording with no usable speech.
    static let mostGain: Float = 17.782795
    /// Raised samples above this are bent toward full scale, which they approach and never pass.
    static let knee: Float = 0.8

    /// Samples counted by magnitude in quarter-decibel steps, from -120 dBFS to +20 dBFS.
    private var counts = [Int](repeating: 0, count: 560)
    private var total = 0

    mutating func measure(_ samples: [Float]) {
        for sample in samples {
            let magnitude = abs(sample)
            let step = magnitude > 0.000001 ? Int((20 * log10(magnitude) + 120) * 4) : 0
            counts[min(step, counts.count - 1)] += 1
        }
        total += samples.count
    }

    /// The magnitude that all but one in a thousand samples stay below.
    var level: Float {
        var above = 0
        for step in counts.indices.reversed() {
            above += counts[step]
            if above * 1000 > total { return pow(10, (Float(step + 1) / 4 - 120) / 20) }
        }
        return 0
    }

    /// One for a recording at an ordinary level, for silence and for an empty file.
    var gain: Float {
        let level = level
        return level > 0.000001 ? min(Self.mostGain, max(1, Self.target / level)) : 1
    }

    static func raise(_ samples: ArraySlice<Float>, by gain: Float) -> [Float] {
        samples.map { sample in
            let raised = sample * gain, magnitude = abs(raised)
            guard magnitude > knee else { return raised }
            let rounded = knee + (1 - knee) * tanh((magnitude - knee) / (1 - knee))
            return raised < 0 ? -rounded : rounded
        }
    }
}
