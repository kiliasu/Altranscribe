import Foundation
import CryptoKit
import Security

public struct AppPaths: Sendable {
    public let root: URL
    public var records: URL { root.appendingPathComponent("Records", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var settings: URL { root.appendingPathComponent("settings.json") }
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Altranscribe", isDirectory: true)
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
    public func save(_ record: TranscriptRecord) throws {
        try paths.prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = paths.records.appendingPathComponent("\(record.id).json")
        var snapshot = record
        snapshot.version = 2
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: paths.records.appendingPathComponent("\(id).json"))
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
    public static func read(endpoint: String) throws -> String {
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
    public static func save(_ key: String, endpoint: String) throws {
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
    public func download(to directory: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
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
