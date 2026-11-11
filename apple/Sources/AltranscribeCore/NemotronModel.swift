import Foundation
import CryptoKit

public struct NemotronModel: Identifiable, Sendable {
    public struct File: Sendable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
    }
    public let id: String
    public let title: String
    public let repository: String
    public let revision: String
    public let multilingual: Bool
    public let files: [File]
    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public var modelCard: URL {
        URL(string: "https://huggingface.co/nvidia/" + (multilingual ? "nemotron-3.5-asr-streaming-0.6b" : "nemotron-speech-streaming-en-0.6b"))!
    }

    // The same immutable ONNX exports and hashes as the dev branch's model catalog.
    public static let catalog = [
        NemotronModel(id: "nemotron-en-0.6b", title: "Nemotron Streaming · English (0.6B)",
            repository: "csukuangfj2/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25",
            revision: "52056fdc070914a48dcd68b31b44d6a6f5b85902", multilingual: false, files: [
                File(name: "encoder.int8.onnx", bytes: 652916849, sha256: "7d932213491ad355c6e5576705dc3494731a52af87d7a1b954559340147909d8"),
                File(name: "decoder.int8.onnx", bytes: 7257753, sha256: "0be9702c2f427a2b6bb241d298e0d3836a558de1f5b9fd3018f1cce6e2b3fa98"),
                File(name: "joiner.int8.onnx", bytes: 1735862, sha256: "a35eac38a22ebceb04d230ed7afe0d68f446ba6914a036b97f14fece95967e23"),
                File(name: "tokens.txt", bytes: 8952, sha256: "dc0b4584ab2e4ddbf888425c076c61b736e7356a015250db7d307e6f1a8188ff")
            ]),
        NemotronModel(id: "nemotron-3.5-0.6b", title: "Nemotron 3.5 Streaming · Multilingual (0.6B)",
            repository: "csukuangfj2/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11",
            revision: "ab43d895f5985b1bbab8b6eac8607fcdc05343f3", multilingual: true, files: [
                File(name: "encoder.int8.onnx", bytes: 657601403, sha256: "012e9321373af99021415e0b0eb3ec827b4be3153be6f30d9b448fe65e896e68"),
                File(name: "decoder.int8.onnx", bytes: 14978075, sha256: "19f9c98fc6d0a2c33a65a43b36fdb2e914c26c0aa9764be3aebc502a1e982fb0"),
                File(name: "joiner.int8.onnx", bytes: 9504438, sha256: "4101c7c679a0bc30483794b27a059e34e79232aa2068d78d51231a22c8b0d7ce"),
                File(name: "tokens.txt", bytes: 131440, sha256: "729cc103155bafa785f9cd45746cd41cabe97eab7182fc04d594129587958f8a")
            ])
    ]

    public func directory(in models: URL) -> URL { models.appendingPathComponent(id, isDirectory: true) }
    public func isInstalled(in models: URL) -> Bool { isComplete(at: directory(in: models)) }
    public func isComplete(at directory: URL) -> Bool {
        files.allSatisfy {
            let size = try? directory.appendingPathComponent($0.name).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size.map(Int64.init) == $0.bytes
        }
    }

    /// `progress` receives the part of the model's files that has arrived, from 0 to 1.
    public func download(to models: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let target = directory(in: models)
        if isComplete(at: target) { return target }
        let staging = models.appendingPathComponent(".\(id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let total = Double(max(1, bytes))
        var finished: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.name)")!
            let earlier = finished
            var received: (@Sendable (Int64) -> Void)?
            if let progress { received = { bytes in progress(min(1, Double(earlier + bytes) / total)) } }
            let (temporary, response) = try await FileDownload.fetch(url, expected: file.bytes, received: received)
            finished += file.bytes
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw AppError("Nemotron model download failed. Please try again.")
            }
            let hash = try await Task.detached {
                let input = try FileHandle(forReadingFrom: temporary)
                defer { try? input.close() }
                var hash = SHA256()
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
                return hash.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
            try Task.checkCancellation()
            guard hash == file.sha256 else {
                throw AppError("Nemotron model checksum failed. The download was not installed.")
            }
            try FileManager.default.moveItem(at: temporary, to: staging.appendingPathComponent(file.name))
        }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: staging, to: target)
        return target
    }
}
