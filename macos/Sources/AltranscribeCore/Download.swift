import Foundation

/// Fetches one file to a temporary location and says how much of it has arrived, so a download of
/// several gigabytes shows more than a spinner.
enum FileDownload {
    /// `received` is called with the bytes so far, at most once for each whole percent of `expected`.
    static func fetch(_ url: URL, expected: Int64, received: (@Sendable (Int64) -> Void)?) async throws -> (URL, URLResponse) {
        guard let received else { return try await URLSession.shared.download(from: url) }
        return try await URLSession.shared.download(from: url, delegate: Observer(expected: expected, received: received))
    }

    /// Follows the transfer through the task's own byte count and through the download's progress calls;
    /// URLSession delivers one or the other to a task's delegate, depending on how the task was made.
    private final class Observer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let expected: Int64
        private let received: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var observation: NSKeyValueObservation?
        private var reported: Int64 = -1

        init(expected: Int64, received: @escaping @Sendable (Int64) -> Void) {
            self.expected = max(1, expected); self.received = received
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let observation = task.observe(\.countOfBytesReceived) { [weak self] task, _ in self?.report(task.countOfBytesReceived) }
            lock.withLock { self.observation = observation }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            report(totalBytesWritten)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.withLock { observation = nil }
        }

        private func report(_ bytes: Int64) {
            let percent = min(100, bytes * 100 / expected)
            let isNew = lock.withLock { () -> Bool in
                guard percent > reported else { return false }
                reported = percent; return true
            }
            if isNew { received(bytes) }
        }
    }
}
