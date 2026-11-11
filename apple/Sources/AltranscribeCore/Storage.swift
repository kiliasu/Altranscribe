import Foundation
import CryptoKit
import Security
import LocalAuthentication

public struct AppPaths: Sendable {
    public let root: URL
    public var records: URL { root.appendingPathComponent("Records", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public let recordings: URL
    /// Whether a deleted transcript and its recording go to the Trash, where a mistake can be undone.
    /// True for the person's own data in its usual place; a store somewhere else, as tests use, removes
    /// its files outright and leaves nothing behind in the Trash.
    public let trashesDeletedFiles: Bool
    public func recording(_ record: TranscriptRecord) -> URL {
        let legacy = root.appendingPathComponent("Recordings/\(record.id).m4a")
        guard let filename = record.recordingFilename else { return legacy }
        let folder = record.recordingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? recordings
        let current = folder.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        if !FileManager.default.fileExists(atPath: current.path), let previous = record.recordingPreviousPath,
           FileManager.default.fileExists(atPath: previous) { return URL(fileURLWithPath: previous) }
        // A failed/interrupted migration must leave the original audio reachable.
        if !FileManager.default.fileExists(atPath: current.path), FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return current
    }
    public static func recordingFilename(for record: TranscriptRecord, title: String? = nil) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        let clean = (title ?? record.title).components(separatedBy: invalid).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        var title = ""
        for character in clean {
            guard title.utf8.count + String(character).utf8.count <= 160 else { break }
            title.append(character)
        }
        if title.isEmpty { title = record.source.title }
        return "\(title) · \(date.string(from: record.createdAt)) \(record.id.uuidString.prefix(8)).m4a"
    }
    public var settings: URL { root.appendingPathComponent("settings.json") }
    public init(root: URL? = nil, recordings: URL? = nil, trashesDeletedFiles: Bool? = nil) {
        self.trashesDeletedFiles = trashesDeletedFiles ?? (root == nil)
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Altranscribe", isDirectory: true)
        self.recordings = recordings ?? (root.map { $0.appendingPathComponent("Recordings", isDirectory: true) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Altranscribe/Recordings", isDirectory: true))
    }
    public func prepare() throws {
        for url in [root, records, models] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }
}

public struct RecordStore: Sendable {
    public let paths: AppPaths
    public init(paths: AppPaths = AppPaths()) { self.paths = paths }
    public func load() throws -> (records: [TranscriptRecord], unreadable: Int) {
        try paths.prepare()
        var records: [TranscriptRecord] = []
        var unreadable = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in try FileManager.default.contentsOfDirectory(at: paths.records, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
            do {
                var record = try decoder.decode(TranscriptRecord.self, from: Data(contentsOf: file))
                if record.status == .inProgress { record.status = .interrupted }
                records.append(record)
            } catch { unreadable += 1 }
        }
        return (records.sorted { $0.createdAt > $1.createdAt }, unreadable)
    }
    public func relocateRecording(_ record: inout TranscriptRecord) throws {
        // A chosen directory belongs to the recording, not to the app's current default.
        guard record.recordingDirectory == nil else { return }
        let original = paths.recording(record)
        guard FileManager.default.fileExists(atPath: original.path) else { return }
        if record.recordingFilename == nil {
            record.recordingFilename = AppPaths.recordingFilename(for: record)
            // Persist the new name first. The resolver still finds the old file until the move succeeds.
            try save(record)
        }
        guard let filename = record.recordingFilename else { return }
        let target = paths.recordings.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        guard original != target else { return }
        try FileManager.default.createDirectory(at: paths.recordings, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: original, to: target)
    }
    public func rename(_ record: TranscriptRecord, title: String) throws -> TranscriptRecord {
        var updated = record
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.title.isEmpty else { return record }
        guard record.hasRecording == true else { try save(updated); return updated }
        let manager = FileManager.default
        let original = paths.recording(record)
        guard manager.fileExists(atPath: original.path) else {
            throw AppError("The recording is unavailable. Reconnect its drive before renaming.")
        }
        updated.recordingDirectory = original.deletingLastPathComponent().path
        updated.recordingPreviousPath = nil
        let filename = AppPaths.recordingFilename(for: updated)
        updated.recordingFilename = filename
        let target = original.deletingLastPathComponent().appendingPathComponent(filename)
        if original == target { try save(updated); return updated }
        if manager.fileExists(atPath: target.path) {
            let first = try manager.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber
            let second = try manager.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
            guard let first, let second, first == second else { throw CocoaError(.fileWriteFileExists) }
        }
        // Persist both paths before moving. A crash at either side of the move must keep audio reachable.
        updated.recordingPreviousPath = original.path
        try save(updated)
        do { try manager.moveItem(at: original, to: target) }
        catch { try save(record); throw error }
        updated.recordingPreviousPath = nil
        // The pending metadata already resolves the new file if this optional cleanup cannot be written.
        try? save(updated)
        return updated
    }
    public func save(_ record: TranscriptRecord) throws {
        try paths.prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = paths.records.appendingPathComponent("\(record.id).json")
        var snapshot = record
        // Interim translations are UI feedback, not a saved translation of the final sentence.
        for index in snapshot.segments.indices where snapshot.segments[index].translationIsProvisional == true {
            snapshot.segments[index].translation = nil
            snapshot.segments[index].translationIsProvisional = nil
            snapshot.segments[index].translationSource = nil
        }
        snapshot.version = 2
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Removes a transcript and the recording saved with it. Returns where the files are in the Trash,
    /// which is nowhere when they were removed outright.
    @discardableResult public func delete(_ id: UUID) throws -> [URL] {
        let url = paths.records.appendingPathComponent("\(id).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(TranscriptRecord.self, from: Data(contentsOf: url))
        let audio = paths.recording(record)
        var trashed: [URL] = []
        for file in [audio, url] where FileManager.default.fileExists(atPath: file.path) {
            if paths.trashesDeletedFiles {
                // A volume without a Trash refuses; the file is then removed, as the person asked.
                var moved: NSURL?
                if (try? FileManager.default.trashItem(at: file, resultingItemURL: &moved)) != nil {
                    if let moved { trashed.append(moved as URL) }
                    continue
                }
            }
            try FileManager.default.removeItem(at: file)
        }
        return trashed
    }
    public func loadSettings() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: paths.settings.path) else { return AppSettings() }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: paths.settings))
    }
    public func saveSettings(_ settings: AppSettings) throws {
        try paths.prepare()
        try JSONEncoder().encode(settings).write(to: paths.settings, options: .atomic)
    }
}

public enum KeychainStore {
    /// Tests point this at a service of their own, so they never read the person's saved keys or make
    /// macOS ask for access to them.
    nonisolated(unsafe) public static var service = "app.altranscribe.mac.api"
    private static func query(_ endpoint: String) throws -> [String: Any] {
        let scope = try APIEndpoint(endpoint).base.absoluteString
        let account = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account]
    }
    /// SecItem calls may wait for system authorization. Never run them on the UI actor.
    private static func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let value = try await Task.detached(priority: .userInitiated, operation: operation).value
        try Task.checkCancellation()
        return value
    }

    /// A settings status check needs only unencrypted attributes, never the saved secret.
    public static func contains(endpoint: String) async throws -> Bool {
        try await perform {
            var query = try query(endpoint)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecItemNotFound { return false }
            guard status == errSecSuccess else { throw AppError("Could not read the API key from Keychain.") }
            return true
        }
    }

    public static func read(endpoint: String) async throws -> String {
        try await perform { try readValue(endpoint: endpoint) }
    }
    private static func readValue(endpoint: String) throws -> String {
        var query = try query(endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AppError("Could not read the API key from Keychain.")
        }
        return String(decoding: data, as: UTF8.self)
    }
    public static func save(_ key: String, endpoint: String) async throws {
        try await perform { try saveValue(key, endpoint: endpoint) }
    }
    private static func saveValue(_ key: String, endpoint: String) throws {
        let query = try query(endpoint)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppError("Could not remove the API key.")
            }
            return
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw AppError("Could not save to Keychain.")
            }
        } else if status != errSecSuccess {
            throw AppError("Could not update the API key.")
        }
    }
}

public struct WhisperModel: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let bytes: Int64
    public let sha256: String
    public var filename: String { "ggml-\(id).bin" }
    public var url: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/\(filename)")!
    }
    public static let catalog = [
        WhisperModel(id: "tiny", title: "Tiny", bytes: 77691713, sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        WhisperModel(id: "base", title: "Base", bytes: 147951465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        WhisperModel(id: "small", title: "Small", bytes: 487601967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        WhisperModel(id: "medium", title: "Medium", bytes: 1533763059, sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"),
        WhisperModel(id: "large-v3-turbo", title: "Large v3 Turbo", bytes: 1624555275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        WhisperModel(id: "large-v3", title: "Large v3", bytes: 3095033483, sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2")
    ]
    /// `progress` receives the part of the file that has arrived, from 0 to 1.
    public func download(to directory: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let expected = bytes
        var received: (@Sendable (Int64) -> Void)?
        if let progress { received = { bytes in progress(min(1, Double(bytes) / Double(expected))) } }
        let (temporary, response) = try await FileDownload.fetch(url, expected: expected, received: received)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError("Model download failed. Please try again.")
        }
        let actualHash = try await Task.detached {
            let file = try FileHandle(forReadingFrom: temporary)
            defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        try Task.checkCancellation()
        guard actualHash == sha256 else {
            throw AppError("Model checksum failed. The download was not installed.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: target) }
        return target
    }
}
