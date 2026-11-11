import XCTest
@testable import AltranscribeCore

/// A model download says how far it has got. The check fetches a real 7 MB model file, so it runs only when asked.
final class DownloadProgressTests: XCTestCase {
    func testDownloadReportsEachPercentOnceAndInOrder() async throws {
        guard ProcessInfo.processInfo.environment["ALTRANSCRIBE_DOWNLOAD_TEST"] == "1" else {
            throw XCTSkip("Set ALTRANSCRIBE_DOWNLOAD_TEST=1 to download one small model file and check its progress.")
        }
        let model = NemotronModel.catalog[0]
        let file = try XCTUnwrap(model.files.first { $0.name == "decoder.int8.onnx" })
        let url = try XCTUnwrap(URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(file.name)"))
        let steps = Steps()
        let (temporary, response) = try await FileDownload.fetch(url, expected: file.bytes) { steps.add($0) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let reported = steps.values
        XCTAssertGreaterThan(reported.count, 3, "A download of several megabytes arrives in more than one piece")
        XCTAssertLessThanOrEqual(reported.count, 101, "At most one report for each percent")
        XCTAssertEqual(reported, reported.sorted())
        XCTAssertEqual(reported.last, file.bytes)
        XCTAssertEqual(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init), file.bytes)
    }

    private final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [Int64] = []
        func add(_ value: Int64) { lock.withLock { bytes.append(value) } }
        var values: [Int64] { lock.withLock { bytes } }
    }
}
