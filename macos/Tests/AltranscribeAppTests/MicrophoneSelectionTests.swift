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

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root))
        let selection = Binding(get: { model.settings.microphoneDeviceUID }, set: { model.settings.microphoneDeviceUID = $0 })
        let picker = NSHostingController(rootView: MicrophonePicker(selection: selection).disabled(false))
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
        if let device = MicrophoneDevice.available().first(where: { $0.audioID == MicrophoneDevice.defaultID }) {
            // Closed, the control names the microphone in use; its menu says that the first entry follows the system.
            let delegate = try XCTUnwrap(control.menu?.delegate)
            let menu = try XCTUnwrap(control.menu)
            XCTAssertEqual(control.title, device.name)
            delegate.menuWillOpen?(menu)
            XCTAssertEqual(menu.items.first?.title, L("System Default · %@", device.name))
            delegate.menuDidClose?(menu)
            XCTAssertEqual(control.title, device.name)
        }
        XCTAssertFalse(control.isBordered, "The system glass effect must be the only background")
        let frame = control.frame
        XCTAssertEqual(frame.height, 28, "The entire large glass button must be clickable, including its vertical margins")
        XCTAssertTrue(window.makeFirstResponder(control))
        let responder = window.firstResponder
        let coordinator = try XCTUnwrap(control.target as? MicrophonePopup.Coordinator)
        for reduceMotion in [false, true] where control.numberOfItems > 1 {
            for index in [1, 0] {
                coordinator.reduceMotion = reduceMotion
                control.selectItem(at: index)
                control.sendAction(control.action, to: control.target)
                let uid = try XCTUnwrap(control.selectedItem?.representedObject as? String)
                XCTAssertEqual(model.settings.microphoneDeviceUID, uid.isEmpty ? nil : uid)
                let fade = try XCTUnwrap(control.layer?.animation(forKey: kCATransition) as? CATransition)
                XCTAssertEqual(fade.type, .fade)
                XCTAssertEqual(fade.duration, reduceMotion ? 0.1 : 0.24)
                RunLoop.main.run(until: Date().addingTimeInterval(0.04))
                XCTAssertTrue(popup(in: picker.view) === control, "Selection changes must retain the native control")
                XCTAssertTrue(window.firstResponder === responder)
                XCTAssertEqual(control.frame, frame, "Fade the contents without resizing the native control")
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertNil(control.layer?.animation(forKey: kCATransition))
        picker.rootView = MicrophonePicker(selection: selection).disabled(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(control.isEnabled)

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
