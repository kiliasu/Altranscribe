import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case text = "txt", markdown = "md", html = "html"
    public var id: String { rawValue }
    public var title: String { switch self { case .text: L("Plain text (TXT)"); case .markdown: "Markdown"; case .html: L("Web page (HTML)") } }
}

public enum TranscriptExport {
    public static func render(_ record: TranscriptRecord, as format: ExportFormat, language: InterfaceLanguage = .current) -> String {
        let summaryHeading = Localization.text("Summary", language: language)
        let transcriptHeading = Localization.text("Transcript", language: language)
        let generatedBy = Localization.text("Exported from Altranscribe", language: language)
        switch format {
        case .text:
            return ([record.title, record.summary ?? ""] + record.segments.map {
                "[\($0.estimated ? "≈" : "")\(timestamp($0.start))] \($0.text)" + ($0.translation.map { "\n\($0)" } ?? "")
            }).filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .markdown:
            return (["# \(record.title)", record.summary.map { "## \(summaryHeading)\n\n\($0)" } ?? "", "## \(transcriptHeading)"] + record.segments.map {
                "**\($0.estimated ? "≈" : "")\(timestamp($0.start))**  \n\($0.text)" + ($0.translation.map { "\n\n> \($0.replacingOccurrences(of: "\n", with: "\n> "))" } ?? "")
            }).filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .html:
            let lines = record.segments.map {
                "<article><time>\($0.estimated ? "≈" : "")\(timestamp($0.start))</time><p>\(escape($0.text))</p>" +
                ($0.translation.map { "<p class=translation\(languageAttribute(record.targetLanguage))>\(escape($0))</p>" } ?? "") + "</article>"
            }.joined(separator: "\n")
            return """
            <!doctype html><html lang="\(language.resolved().rawValue)"><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>\(escape(record.title))</title><style>
            :root{color-scheme:light dark}body{font:17px/1.6 system-ui;margin:48px auto;padding:0 24px;max-width:780px}
            article{padding:16px 0;border-bottom:1px solid #8884}time,.translation{color:light-dark(#555,#bbb)}
            p{white-space:pre-wrap;margin:8px 0}h1{line-height:1.2}aside{padding:20px;background:#8881;border-radius:12px}
            </style><h1>\(escape(record.title))</h1>
            \(record.summary.map { "<aside><h2>\(escape(summaryHeading))</h2><p\(languageAttribute(record.summaryLanguage))>\(escape($0))</p></aside>" } ?? "")
            <h2>\(escape(transcriptHeading))</h2><main\(languageAttribute(record.language))>\(lines)</main><footer><p>\(escape(generatedBy))</p></footer></html>
            """
        }
    }
    private static func languageAttribute(_ language: String?) -> String {
        guard let language, !language.isEmpty, language != "auto" else { return "" }
        return " lang=\"\(escape(language))\""
    }
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
