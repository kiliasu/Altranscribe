import XCTest
import SwiftUI
@testable import Altranscribe
import AltranscribeCore

@MainActor final class TransportLayoutTests: XCTestCase {
    func testRecordingControlsFitTheMinimumDetailColumn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root))
        model.settings.translate = true
        model.phase = .recording
        let view = NSHostingController(rootView: TransportBar(model: model).padding(.horizontal, 20))
        // 860-point window minus the 220-point sidebar and 250-point inspector.
        let minimum = view.sizeThatFits(in: CGSize(width: 390, height: 200))
        let wide = view.sizeThatFits(in: CGSize(width: 800, height: 200))
        XCTAssertGreaterThan(minimum.width, 100)
        XCTAssertGreaterThan(minimum.height, wide.height, "Narrow windows must place controls on two rows")
        XCTAssertLessThanOrEqual(minimum.width, 390, "The transport must not force the split view wider during live translation")
    }
}
