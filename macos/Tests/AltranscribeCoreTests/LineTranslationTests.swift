import XCTest
@testable import AltranscribeCore

/// What a line's translation request holds, and which replies are taken as its translation. The refused
/// replies have the shapes a live session's text model actually produced.
final class LineTranslationTests: XCTestCase {
    private let earlier = [
        "So the address is split into a network part and a host part.",
        "The mask tells you where that split is.",
        "You write a run of ones and then a run of zeros."
    ]
    private let line = "Where the ones stop is the dividing line, and it is not an address of its own."
    private let translation = "一停止写1的地方就是分界线，它本身并不是一个地址。"

    func testTheLineAndTheLinesBeforeItHaveTheirOwnTags() {
        let message = LineTranslation.message("  \(line)\n", previous: earlier + ["  "])
        XCTAssertEqual(message, "<previous>\n\(earlier.joined(separator: "\n"))\n</previous>\n<source>\n\(line)\n</source>")
        XCTAssertEqual(LineTranslation.message(line), "<source>\n\(line)\n</source>")

        let instructions = LineTranslation.instructions(target: "zh", vocabulary: ["CIDR", "subnet mask"])
        XCTAssertTrue(instructions.contains("into Simplified Chinese"), "A language name, not a code")
        XCTAssertTrue(instructions.contains("These terms may be spoken: CIDR, subnet mask."))
        XCTAssertTrue(instructions.contains("<translation>"))
        // The earlier lines are never part of the instructions, where a model took them for the text.
        XCTAssertFalse(instructions.contains(earlier[0]))
        XCTAssertFalse(LineTranslation.instructions(target: "ja").contains("These terms"))
        XCTAssertTrue(LineTranslation.instructions(target: "ja").contains("into Japanese"))
    }

    func testTheTranslationComesOutOfItsTag() {
        func taken(_ reply: String, lenient: Bool = false) -> String? {
            LineTranslation.translation(in: reply, of: line, target: "zh", lenient: lenient)
        }
        XCTAssertEqual(taken("<translation>\(translation)</translation>"), translation)
        XCTAssertEqual(taken("Here is the line in Chinese.\n\n<translation>\n\(translation)\n</translation>\n\nLet me know if you need more."), translation)
        XCTAssertEqual(taken("<TRANSLATION>\(translation)"), translation, "A reply cut off before the closing tag")
        // A model that ignores the tag is taken at its word, without the sentence that announces it.
        XCTAssertEqual(taken(translation), translation)
        XCTAssertEqual(taken("以下是翻译：\n\(translation)"), translation)
        XCTAssertEqual(taken("我可以把这段话翻译成中文，保留原意和专有名词：\n\n\"\(translation)\""), translation)
        XCTAssertEqual(taken("“\(translation)”"), translation, "Quotation marks around the whole reply are the model's")
        XCTAssertEqual(LineTranslation.translation(in: "“好的。”", of: "“Okay.”", target: "zh"), "“好的。”", "A quoted line stays quoted")
        XCTAssertEqual(taken("他说“停”的地方就是分界线，它本身不是地址。"), "他说“停”的地方就是分界线，它本身不是地址。")
    }

    func testRepliesThatAreNotTheLinesTranslationAreRefused() {
        func taken(_ reply: String, of source: String? = nil, lenient: Bool = false) -> String? {
            LineTranslation.translation(in: reply, of: source ?? line, target: "zh", lenient: lenient)
        }
        let earlierTranslated = "所以地址被分成网络部分和主机部分。掩码告诉你分界在哪里。先写一串1，再写一串0。"
        // The lines before it translated again, in paragraphs or run together, with or without the line.
        XCTAssertNil(taken("\(earlierTranslated)\n\n\(translation)"))
        XCTAssertNil(taken("<translation>\(earlierTranslated)\n\n\(translation)</translation>"))
        XCTAssertNil(taken("<translation>\(earlierTranslated)</translation>\n<translation>\(translation)</translation>"))
        XCTAssertNil(taken(earlierTranslated + earlierTranslated + translation))
        XCTAssertNil(taken(earlierTranslated, of: "We have two examples."), "Another line's translation under a short line")
        // An answer to the speaker, or a lecture of the model's own.
        XCTAssertNil(taken("你说得对，掩码中从1变为0的位置就是网络号和主机号的分界线。当年设计地址时，三十二位在当时看来已经足够，而更长的地址意味着每个数据包的头部都要更大，在带宽非常有限的年代，这是需要认真权衡的事情。"))
        // A remark in place of the translation, or the request handed back.
        XCTAssertNil(taken("I can't see any text to translate. You only provided the previous context, which contains a passage of English and no explicit text to translate."))
        XCTAssertNil(taken("<source>\(line)</source>"))
        XCTAssertNil(taken("<previous>\(earlier[2])</previous><translation>\(translation)</translation>"))
        XCTAssertNil(taken("</translation>"))
        XCTAssertNil(taken("<translation>  </translation>"))
        XCTAssertNil(taken(""))
        // The wrong language, in both directions.
        XCTAssertNil(taken("The place where the ones stop is the dividing line; it is not an address of its own."))
        XCTAssertNil(LineTranslation.translation(in: "一停止写1的地方就是分界线，它本身并不是一个地址。", of: "一停止写一的地方就是分界线，它本身并不是一个地址。", target: "en"))
        XCTAssertNotNil(LineTranslation.translation(in: "Where the ones stop is the dividing line; it is not an address itself.",
                                                    of: "一停止写一的地方就是分界线，它本身并不是一个地址。", target: "en"))
        // A few words for a whole paragraph.
        let paragraph = String(repeating: "The mask tells you where the split is, so read it bit by bit. ", count: 4)
        XCTAssertNil(taken("好的。", of: paragraph))
    }

    func testLineBreaksAreOnlyClosedUpWhenNoEarlierLinesWereSent() {
        let reply = "<translation>一停止写1的地方就是分界线，\n它本身并不是一个地址。</translation>"
        XCTAssertNil(LineTranslation.translation(in: reply, of: line, target: "zh"))
        XCTAssertEqual(LineTranslation.translation(in: reply, of: line, target: "zh", lenient: true), translation)
        XCTAssertEqual(LineTranslation.translation(in: "It is where the ones stop,\nnot an address.", of: "一停止写一的地方就是分界线，它不是地址。", target: "en", lenient: true),
                       "It is where the ones stop, not an address.")
        // A line that has breaks of its own keeps them.
        XCTAssertEqual(LineTranslation.translation(in: "第一行\n第二行", of: "First line\nSecond line", target: "zh"), "第一行\n第二行")
    }

    func testShortLinesNamesAndNumbersPass() {
        XCTAssertEqual(LineTranslation.translation(in: "嗯", of: "Um", target: "zh"), "嗯")
        XCTAssertEqual(LineTranslation.translation(in: "Altranscribe 2.0", of: "Altranscribe 2.0", target: "zh"), "Altranscribe 2.0")
        XCTAssertEqual(LineTranslation.translation(in: "translation", of: "Hello", target: "zh"), "translation")
        XCTAssertEqual(LineTranslation.translation(in: "255.255.255.0", of: "255.255.255.0", target: "ja"), "255.255.255.0")
        XCTAssertEqual(LineTranslation.translation(in: "<translation>그 지점이 경계선입니다.</translation>", of: "That point is the dividing line.", target: "ko"), "그 지점이 경계선입니다.")
        XCTAssertNil(LineTranslation.translation(in: "那个点就是分界线。", of: "That point is the dividing line.", target: "ko"))
    }
}

/// The request for one line, and what happens to a reply that is not its translation.
final class LineTranslationRequestTests: XCTestCase, @unchecked Sendable {
    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (status, data) = try Self.handler!(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return APIClient(session: URLSession(configuration: configuration))
    }
    /// The system and user texts of an Anthropic Messages request.
    private func texts(_ request: URLRequest) throws -> (system: String, user: String) {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "The reply is not started for the model: current models refuse a prefilled turn")
        XCTAssertNil(object["temperature"]); XCTAssertNil(object["top_p"])
        return (try XCTUnwrap(object["system"] as? String), try XCTUnwrap(messages[0]["content"] as? String))
    }
    private func reply(_ text: String) throws -> (Int, Data) {
        (200, try JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn", "content": [["type": "text", "text": text]]]))
    }
    private var settings: AppSettings {
        var settings = AppSettings()
        settings.textProvider = .anthropic; settings.textModel = "claude-haiku-5-5"
        settings.targetLanguage = "zh"; settings.vocabulary = "CIDR, 子网掩码"
        return settings
    }
    private let earlier = "The mask tells you where that split is.\nYou write a run of ones and then a run of zeros."
    private let line = "Where the ones stop is the dividing line, and it is not an address of its own."
    private let translation = "一停止写1的地方就是分界线，它本身并不是一个地址。"

    func testALineIsSentWithTheLinesBeforeItAndItsTranslationReturned() async throws {
        var requests: [(system: String, user: String)] = []
        Stub.handler = { request in
            requests.append(try self.texts(request))
            return try self.reply("<translation>\(self.translation)</translation>")
        }
        let output = try await client().translate(line, sourceLanguage: "en", context: earlier, settings: settings, key: "test-key")
        XCTAssertEqual(output, translation)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].user, LineTranslation.message(line, previous: earlier.components(separatedBy: "\n")))
        XCTAssertEqual(requests[0].system, LineTranslation.instructions(target: "zh", vocabulary: ["CIDR", "子网掩码"]))
        XCTAssertFalse(requests[0].system.contains("run of ones"), "Earlier lines belong to the message, not the instructions")
    }

    func testALineIsAskedForAgainOnItsOwnWhenTheReplyIsNotItsTranslation() async throws {
        var users: [String] = []
        Stub.handler = { request in
            users.append(try self.texts(request).user)
            // First the earlier lines come back translated as well; alone, the line comes back with a line break.
            return try self.reply(users.count == 1
                ? "掩码告诉你分界在哪里。\n\n先写一串1，再写一串0。\n\n\(self.translation)"
                : "<translation>一停止写1的地方就是分界线，\n它本身并不是一个地址。</translation>")
        }
        let output = try await client().translate(line, sourceLanguage: "en", context: earlier, settings: settings, key: "test-key")
        XCTAssertEqual(output, translation)
        XCTAssertEqual(users.count, 2)
        XCTAssertTrue(users[0].contains("<previous>"))
        XCTAssertEqual(users[1], LineTranslation.message(line))
    }

    func testAReplyThatIsNeverATranslationIsAnErrorAndNotText() async throws {
        var calls = 0
        Stub.handler = { _ in
            calls += 1
            return try self.reply("I can't see any text to translate. You only provided the previous context, which contains a passage of English and no explicit text to translate.")
        }
        do {
            _ = try await client().translate(line, sourceLanguage: "en", context: earlier, settings: settings, key: "test-key")
            XCTFail("A remark about the request must not be shown as the line's translation")
        } catch let error as AppError {
            XCTAssertEqual(error.message.key, "The text model did not return a translation of this line. The original text was saved; translate it again from Library.")
        }
        XCTAssertEqual(calls, 2)
        // Without earlier lines there is nothing to leave out, so the line is asked for once.
        calls = 0
        do { _ = try await client().translate(line, sourceLanguage: "en", context: "", settings: settings, key: "test-key"); XCTFail("Expected an error") }
        catch is AppError { }
        XCTAssertEqual(calls, 1)
    }

    func testAFailedRequestIsNotRepeated() async throws {
        var calls = 0
        Stub.handler = { _ in calls += 1; return (429, Data("{}".utf8)) }
        do { _ = try await client().translate(line, sourceLanguage: "en", context: earlier, settings: settings, key: "test-key"); XCTFail("Expected an error") }
        catch let error as AppError { XCTAssertTrue(error.localizedDescription.contains("429")) }
        XCTAssertEqual(calls, 1)
        // A line already in the language asked for is returned without a request.
        Stub.handler = { _ in XCTFail("No request for a line in the target language"); return (500, Data()) }
        let same = try await client().translate("已经是中文。", sourceLanguage: "zh", context: "", settings: settings, key: "test-key")
        XCTAssertEqual(same, "已经是中文。")
    }
}
