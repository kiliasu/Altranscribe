import XCTest
@testable import AltranscribeCore

final class LocalizationTests: XCTestCase {
    func testLanguageCoverageSwitchingAndLegacyRecords() throws {
        func catalog(_ language: String) throws -> [String: String] {
            let folder = try XCTUnwrap(Localization.resources.url(forResource: language, withExtension: "lproj"))
            let data = try Data(contentsOf: folder.appendingPathComponent("Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try catalog("en"), chinese = try catalog("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for key in english.keys {
            XCTAssertFalse(chinese[key]!.isEmpty, key)
            XCTAssertEqual(key.components(separatedBy: "%@").count, chinese[key]!.components(separatedBy: "%@").count, key)
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let literal = #""(?:\\.|[^"\\])*""#
        // A key passed directly, or either branch of a condition passed in its place: L(flag ? "A" : "B").
        let direct = try NSRegularExpression(pattern: #"\b(?:L|LocalizedText|AppError)\(("# + literal + ")")
        let conditional = try NSRegularExpression(pattern: #"\b(?:L|LocalizedText|AppError)\([^()"]*\?\s*("# + literal + #")\s*:\s*("# + literal + ")")
        for case let file as URL in FileManager.default.enumerator(at: package.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            let matches = direct.matches(in: text, range: range).map { [$0.range(at: 1)] } +
                conditional.matches(in: text, range: range).map { [$0.range(at: 1), $0.range(at: 2)] }
            for capture in matches.flatMap({ $0 }) {
                let key = try JSONDecoder().decode(String.self, from: Data(String(text[Range(capture, in: text)!]).utf8))
                XCTAssertNotNil(english[key], "Missing translation in \(file.lastPathComponent): \(key)")
            }
        }
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferredLanguages: ["ja-JP"]), .english)
        XCTAssertEqual(InterfaceLanguage.english.resolved(preferredLanguages: ["zh-CN"]), .english)
        let status = LocalizedText("Translating %@/%@", "1", "3")
        XCTAssertEqual(status.rendered(language: .english), "Translating 1/3")
        XCTAssertEqual(status.rendered(language: .simplifiedChinese), "正在翻译 1/3")
        XCTAssertEqual(LocalizedText(verbatim: "Ready").rendered(language: .simplifiedChinese), "Ready")

        var record = TranscriptRecord(title: "English source", source: .file, language: "en", speechModel: "nemotron-en-0.6b")
        var line = TranscriptSegment(start: 0, end: 1, text: "Hello <world>")
        line.translation = "你好"
        record.segments = [line]; record.summary = "A summary"; record.summaryLanguage = "en"; record.targetLanguage = "zh"
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        old["version"] = 1
        old.removeValue(forKey: "summaryLanguage")
        old["error"] = "The API returned an invalid response."
        var oldLines = old["segments"] as! [[String: Any]]
        oldLines[0]["translationError"] = "模型名称无效。"
        old["segments"] = oldLines
        let restored = try JSONDecoder().decode(TranscriptRecord.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(restored.summaryLanguage)
        XCTAssertEqual(restored.error?.rendered(language: .simplifiedChinese), "API 返回了无法识别的响应。")
        XCTAssertEqual(restored.segments[0].translationError?.rendered(language: .english), "Invalid model name.")
        XCTAssertEqual(try JSONDecoder().decode(TranscriptRecord.self, from: JSONEncoder().encode(restored)), restored)
        let failure = LocalizedText(error: AppError("HTTP %@. Rate limit or quota exceeded.", "429"), context: "Summary failed: ")
        XCTAssertEqual(failure.rendered(language: .simplifiedChinese), "摘要失败：HTTP 429。请求限流或额度不足。")

        let html = TranscriptExport.render(record, as: .html, language: .simplifiedChinese)
        XCTAssertTrue(html.contains("<html lang=\"zh-Hans\">"))
        XCTAssertTrue(html.contains("<h2>摘要</h2>"))
        XCTAssertTrue(html.contains("<h2>文稿</h2>"))
        XCTAssertTrue(html.contains("<main lang=\"en\">"))
        XCTAssertTrue(html.contains("class=translation lang=\"zh\""))
        XCTAssertTrue(html.contains("Hello &lt;world&gt;"))
        XCTAssertTrue(html.contains("由 Altranscribe 导出"))
        XCTAssertTrue(TranscriptExport.render(record, as: .markdown, language: .english).contains("## Summary"))
        XCTAssertTrue(TranscriptExport.render(record, as: .markdown, language: .simplifiedChinese).contains("## 摘要"))
    }
}
