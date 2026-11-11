import XCTest
import SwiftUI
@testable import Altranscribe
import AltranscribeCore

/// The library around a session: what a dropped folder adds, what the search keeps, what a transcript's
/// commands need before they run, and how the welcome page's controls wrap.
@MainActor final class LibraryTests: XCTestCase {
    private func temporaryModel() -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (AppModel(paths: AppPaths(root: root)), root)
    }

    func testDroppedFolderAddsItsAudioAndVideoInOrder() throws {
        let (model, root) = temporaryModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Lectures", isDirectory: true)
        let nested = folder.appendingPathComponent("Week 2", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["lecture 10.m4a", "lecture 2.m4a", "notes.txt", ".hidden.mp3", "Week 2/seminar.mp4", "Week 2/slides.pdf"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let single = root.appendingPathComponent("interview.wav")
        try Data("x".utf8).write(to: single)

        XCTAssertEqual(AppModel.mediaFiles(at: folder).map(\.lastPathComponent), ["lecture 2.m4a", "lecture 10.m4a", "seminar.mp4"],
                       "Audio and video only, in the order Finder lists them")
        XCTAssertEqual(AppModel.mediaFiles(at: single), [single], "A file stands for itself, whatever its type")
        XCTAssertEqual(AppModel.mediaFiles(at: URL(string: "https://example.com/a.mp3")!), [])

        model.addFiles([folder, single, single])
        XCTAssertEqual(model.queue.map(\.url.lastPathComponent), ["lecture 2.m4a", "lecture 10.m4a", "seminar.mp4", "interview.wav"])
        XCTAssertEqual(model.destination, .files)
    }

    func testSearchFollowsATranscriptWhoseTextChanges() {
        let (model, root) = temporaryModel()
        defer { try? FileManager.default.removeItem(at: root) }
        var first = TranscriptRecord(title: "Networks", source: .microphone, language: "en", speechModel: "tiny")
        first.segments = [TranscriptSegment(start: 0, end: 4, text: "A subnet mask marks the dividing line")]
        var second = TranscriptRecord(title: "Weekly sync", source: .system, language: "en", speechModel: "tiny")
        second.segments = [TranscriptSegment(start: 0, end: 4, text: "Nothing about addresses yet")]
        model.records = [first, second]
        XCTAssertEqual(model.filteredRecords.map(\.id), [first.id, second.id])

        model.search = "subnet"
        XCTAssertEqual(model.filteredRecords.map(\.id), [first.id])
        XCTAssertEqual(model.filteredRecords.map(\.id), [first.id], "Asked again, as the sidebar does with every word")
        // A running session adds the word to the other transcript.
        model.records[1].segments.append(TranscriptSegment(start: 5, end: 9, text: "Now the subnet comes up"))
        XCTAssertEqual(model.filteredRecords.map(\.id), [first.id, second.id])
        // A line still being recognized grows in place.
        model.records[1].segments[1].text = "Now the network comes up"
        XCTAssertEqual(model.filteredRecords.map(\.id), [first.id])
        model.records[1].segments[1].translation = "现在说到 subnet"
        XCTAssertEqual(model.filteredRecords.map(\.id), [first.id, second.id])
        model.records[0].title = "Renamed"; model.records[0].segments = []
        XCTAssertEqual(model.filteredRecords.map(\.id), [second.id])
        model.search = "renamed"
        XCTAssertEqual(model.filteredRecords.map(\.id), [first.id], "Another search starts afresh")
        model.search = ""
        XCTAssertEqual(model.filteredRecords.count, 2)
    }

    func testTranslatingOrSummarizingAgainNamesWhatIsMissing() {
        let (model, root) = temporaryModel()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = TranscriptRecord(title: "Lecture", source: .microphone, language: "en", speechModel: "tiny")
        record.segments = [TranscriptSegment(start: 0, end: 4, text: "A line")]
        model.records = [record]
        model.settings.textProvider = .anthropic; model.settings.textModel = ""; model.settings.textModelOverride = nil
        for summary in [true, false] {
            model.error = nil
            model.postProcess(record, summary: summary)
            XCTAssertEqual(model.error, LocalizedText("Translation or summary needs a text model."))
            XCTAssertFalse(model.busy, "Nothing starts, and no saved key is read")
        }
        model.error = nil
        model.settings.textModel = "claude-haiku-5-5"
        model.postProcess(TranscriptRecord(title: "Empty", source: .microphone, language: "en", speechModel: "tiny"), summary: true)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.busy, "A transcript without text has nothing to send")
    }

    func testSearchedWordsAreMarkedTheWayTheSearchFindsThem() {
        func found(_ words: String, in text: String) -> [String] {
            SearchHighlight.ranges(of: words, in: text).map { String(text[$0]) }
        }
        XCTAssertEqual(found("subnet", in: "A Subnet mask, a SUBNET, and subnets."), ["Subnet", "SUBNET", "subnet"])
        XCTAssertEqual(found("cafe", in: "The café and the CAFE"), ["café", "CAFE"], "Accents and case do not matter, as in the sidebar")
        XCTAssertEqual(found("子网", in: "子网掩码把地址分成网络和主机两部分，子网由此而来。"), ["子网", "子网"])
        XCTAssertEqual(found("aa", in: "aaaa"), ["aa", "aa"], "Matches do not overlap")
        XCTAssertEqual(found("", in: "Anything"), [])
        XCTAssertEqual(found("absent", in: "Nothing here"), [])
        let marked = SearchHighlight.marked("A Subnet mask", "subnet")
        XCTAssertEqual(String(marked.characters), "A Subnet mask", "Marking changes no text")
        XCTAssertEqual(marked.runs.filter { $0.backgroundColor != nil }.map { String(marked[$0.range].characters) }, ["Subnet"])
        XCTAssertEqual(SearchHighlight.marked("Plain", "").runs.count, 1)

        var record = TranscriptRecord(title: "Subnet lecture", source: .microphone, language: "en", speechModel: "tiny")
        record.segments = [TranscriptSegment(start: 0, end: 4, text: "An introduction"), TranscriptSegment(start: 4, end: 8, text: "Then the mask"),
                           TranscriptSegment(start: 8, end: 12, text: "And the subnet")]
        record.segments[1].translation = "然后是 Subnet 掩码"
        XCTAssertEqual(SearchHighlight.firstLine(with: "subnet", in: record), record.segments[1].id, "A translation counts")
        XCTAssertNil(SearchHighlight.firstLine(with: "lecture", in: record), "Words only in the title leave the transcript where it is")
        XCTAssertNil(SearchHighlight.firstLine(with: "", in: record))
    }

    func testBalancedRowsAreAboutAsLongAsEachOther() {
        // The welcome page's four controls in a column that holds three of them: two and two, not three and one.
        let chips: [CGFloat] = [181, 160, 105, 142]
        XCTAssertEqual(FlowLayout.rowLengths(chips, in: 580, spacing: 8, balanced: false), [3, 1])
        XCTAssertEqual(FlowLayout.rowLengths(chips, in: 580, spacing: 8, balanced: true), [2, 2])
        XCTAssertEqual(FlowLayout.rowLengths(chips, in: 640, spacing: 8, balanced: true), [4], "One row stays one row")
        XCTAssertEqual(FlowLayout.rowLengths([150, 150, 100, 140, 140], in: 580, spacing: 8, balanced: false), [4, 1])
        XCTAssertEqual(FlowLayout.rowLengths([150, 150, 100, 140, 140], in: 580, spacing: 8, balanced: true), [2, 3])
        XCTAssertEqual(FlowLayout.rowLengths(chips, in: 150, spacing: 8, balanced: true), [1, 1, 1, 1], "Narrower than an item: one to a row")
        XCTAssertEqual(FlowLayout.rowLengths(chips, in: .infinity, spacing: 8, balanced: true), [4])
        XCTAssertEqual(FlowLayout.rowLengths([], in: 580, spacing: 8, balanced: true), [0])
        for width in stride(from: CGFloat(200), through: 700, by: 7) {
            let plain = FlowLayout.rowLengths(chips, in: width, spacing: 8, balanced: false)
            let balanced = FlowLayout.rowLengths(chips, in: width, spacing: 8, balanced: true)
            XCTAssertEqual(balanced.count, plain.count, "Balancing never adds a row (width \(width))")
            XCTAssertEqual(balanced.reduce(0, +), chips.count)
        }
    }

    func testIdleBarStandsOnOneLineInTheDefaultWindow() {
        let (model, root) = temporaryModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let bar = NSHostingController(rootView: TransportBar(model: model).padding(.horizontal, 20))
        let wide = bar.sizeThatFits(in: CGSize(width: 1_000, height: 300))
        // The default 1,240-point window, less its 240-point sidebar and 280-point inspector.
        XCTAssertEqual(bar.sizeThatFits(in: CGSize(width: 720, height: 300)).height, wide.height,
                       "The source, the microphone and Start fit one line")
        // The narrowest the column gets: the 860-point window with the widest sidebar and inspector.
        let narrow = bar.sizeThatFits(in: CGSize(width: 270, height: 300))
        XCTAssertLessThanOrEqual(narrow.width, 270)
        XCTAssertGreaterThan(narrow.height, wide.height, "Two lines where one does not fit")
    }
}
