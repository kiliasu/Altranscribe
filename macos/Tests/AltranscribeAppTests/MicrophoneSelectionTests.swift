import XCTest
import SwiftUI
import AVFoundation
import AudioToolbox
@testable import Altranscribe
import AltranscribeCore

@MainActor final class MicrophoneSelectionTests: XCTestCase {
    func testSelectionPersistsAndFitsBeforeStarting() throws {
        var settings = AppSettings()
        let legacy = try JSONEncoder().encode(settings)
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: legacy).microphoneDeviceUID)
        settings.microphoneDeviceUID = "disconnected-test-microphone"
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).microphoneDeviceUID,
                       settings.microphoneDeviceUID)
        XCTAssertThrowsError(try MicrophoneDevice.resolve(settings.microphoneDeviceUID), "A missing selection must never fall back to the default microphone")

        let picker = NSHostingController(rootView: MicrophonePicker(selection: .constant(nil)))
        let window = NSWindow(contentViewController: picker)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func popup(in view: NSView) -> NSPopUpButton? {
            (view as? NSPopUpButton) ?? view.subviews.compactMap { popup(in: $0) }.first
        }
        let control = try XCTUnwrap(popup(in: picker.view), "Use the native microphone popup, including its title and keyboard support")
        XCTAssertFalse(control.title.isEmpty)
        XCTAssertGreaterThan(control.numberOfItems, 0)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root))
        let view = NSHostingController(rootView: TransportBar(model: model).padding(.horizontal, 20))
        for source in [AudioSource.microphone, .system] {
            model.source = source
            for uid in [nil, settings.microphoneDeviceUID] {
                model.settings.microphoneDeviceUID = uid
                let size = view.sizeThatFits(in: CGSize(width: 390, height: 250))
                XCTAssertLessThanOrEqual(size.width, 390, "The microphone menu must fit the narrow detail column")
                XCTAssertLessThan(size.height, 220)
            }
        }
    }

    func testSelectedAudioUnitKeepsSystemDefaultUnchanged() throws {
        guard let uid = ProcessInfo.processInfo.environment["ALTRANSCRIBE_TEST_MICROPHONE_UID"] else {
            throw XCTSkip("Set ALTRANSCRIBE_TEST_MICROPHONE_UID to check routing on a real input; no capture is started.")
        }
        let device = try MicrophoneDevice.resolve(uid)
        let systemDefault = MicrophoneDevice.defaultID
        for voiceProcessing in [false, true] {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            if voiceProcessing { try input.setVoiceProcessingEnabled(true) }
            try AudioCapture.select(device, on: input)
            var actual = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
            XCTAssertEqual(AudioUnitGetProperty(try XCTUnwrap(input.audioUnit), kAudioOutputUnitProperty_CurrentDevice,
                                               kAudioUnitScope_Global, 0, &actual, &size), noErr)
            XCTAssertEqual(actual, device.audioID)
            XCTAssertEqual(MicrophoneDevice.defaultID, systemDefault, "Per-app selection must leave the system input unchanged")
        }
    }
}
