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
    public init(chunkSeconds: Int = 20) { chunkSize = max(1, min(600, chunkSeconds)) * 16_000 }

    public func open(_ url: URL) async throws -> Double {
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
        let chunk = AudioChunk(samples: Array(pending.prefix(count)), start: Double(delivered) / 16_000)
        pending.removeFirst(count)
        delivered += count
        return chunk
    }
    public func cancel() { reader?.cancelReading(); reader = nil; output = nil; pending = []; deferredBuffer = nil }
    private func decodeError() -> AppError {
        AppError("macOS could not decode this media file. Convert it to WAV, M4A or MP4 first.")
    }
}
