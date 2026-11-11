import Foundation

public enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    public static let preferenceKey = "interfaceLanguage"
    public var id: String { rawValue }
    public static var current: InterfaceLanguage {
        (InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system).resolved()
    }
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> InterfaceLanguage {
        guard self == .system else { return self }
        for language in preferredLanguages {
            if language.lowercased().hasPrefix("zh") { return .simplifiedChinese }
            if language.lowercased().hasPrefix("en") { return .english }
        }
        return .english
    }
    public var locale: Locale { Locale(identifier: resolved().rawValue) }
    public var speechCode: String { resolved() == .simplifiedChinese ? "zh" : "en" }
}

public enum Localization {
    // SwiftPM tests use Bundle.module; the distributed app carries the same bundle in Resources.
    static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Altranscribe_AltranscribeCore.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()
    private static let bundles: [InterfaceLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        [InterfaceLanguage.english, .simplifiedChinese].compactMap { language in
            resources.url(forResource: language.rawValue, withExtension: "lproj")
                .flatMap(Bundle.init(url:)).map { (language, $0) }
        })

    public static func text(_ key: String, arguments: [String] = [], language: InterfaceLanguage = .current) -> String {
        let resolved = language.resolved()
        let format = bundles[resolved]?.localizedString(forKey: key, value: key, table: nil) ?? key
        return arguments.isEmpty ? format : String(format: format, locale: resolved.locale, arguments: arguments)
    }
    public static func date(_ date: Date, language: InterfaceLanguage = .current) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(language.locale))
    }
    public static func byteCount(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file).locale(InterfaceLanguage.current.locale))
    }
    static func legacyKey(_ value: String) -> String {
        guard let url = bundles[.simplifiedChinese]?.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let strings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return value }
        return strings.first { $0.value == value }?.key ?? value
    }
}

public func L(_ key: String, _ arguments: String...) -> String {
    Localization.text(key, arguments: arguments)
}

/// Keep status and diagnostic text language-neutral until it is displayed.
public struct LocalizedText: Codable, Equatable, Sendable {
    public let key: String
    public let arguments: [String]
    private var verbatim: Bool
    private var context: String?
    public init(_ key: String, _ arguments: String...) {
        self.init(key: key, arguments: arguments)
    }
    init(key: String, arguments: [String]) {
        self.key = key; self.arguments = arguments; verbatim = false
    }
    public init(verbatim: String) { key = verbatim; arguments = []; self.verbatim = true }
    public init(error: Error, context: String? = nil) {
        self = (error as? AppError)?.message ?? LocalizedText(verbatim: error.localizedDescription)
        self.context = context
    }
    public var text: String { rendered() }
    public func rendered(language: InterfaceLanguage = .current) -> String {
        let value = verbatim ? key : Localization.text(key, arguments: arguments, language: language)
        return (context.map { Localization.text($0, language: language) } ?? "") + value
    }
    private enum CodingKeys: String, CodingKey { case key, arguments, verbatim, context }
    public init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self.init(Localization.legacyKey(legacy)); return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try values.decode(String.self, forKey: .key),
                  arguments: try values.decodeIfPresent([String].self, forKey: .arguments) ?? [])
        verbatim = try values.decodeIfPresent(Bool.self, forKey: .verbatim) ?? false
        context = try values.decodeIfPresent(String.self, forKey: .context)
    }
}
