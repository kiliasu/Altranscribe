import SwiftUI
import CoreAudio
import Observation
import AltranscribeCore

struct MicrophoneDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let audioID: AudioDeviceID

    static var defaultID: AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    static func available() -> [Self] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Self(id: uid, name: name, audioID: id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func resolve(_ uid: String?) throws -> Self {
        let devices = available()
        if let uid {
            guard let device = devices.first(where: { $0.id == uid }) else {
                throw AppError("The selected microphone is unavailable. Connect it or choose another microphone.")
            }
            return device
        }
        guard let device = devices.first(where: { $0.audioID == defaultID }) else { throw AppError("No microphone is available.") }
        return device
    }

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

@MainActor @Observable private final class MicrophoneList {
    var devices = MicrophoneDevice.available()
    var defaultID = MicrophoneDevice.defaultID
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    init() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.devices = MicrophoneDevice.available()
                self?.defaultID = MicrophoneDevice.defaultID
            }
        }
        self.listener = listener
        for selector in Self.selectors {
            var address = MicrophoneDevice.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    isolated deinit {
        guard let listener else { return }
        for selector in Self.selectors {
            var address = MicrophoneDevice.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }
}

struct MicrophonePicker: View {
    @Binding var selection: String?
    @State private var microphones = MicrophoneList()
    @Environment(\.isEnabled) private var isEnabled

    private var defaultName: String? {
        microphones.devices.first { $0.audioID == microphones.defaultID }?.name
    }
    private var defaultTitle: String {
        defaultName.map { L("System Default · %@", $0) } ?? L("System Default")
    }
    private var title: String {
        guard let selection else { return defaultTitle }
        return microphones.devices.first { $0.id == selection }?.name ?? L("Unavailable Microphone")
    }

    var body: some View {
        // Closed, the control names the microphone in use, which fits; its menu says which entry follows the system.
        MicrophonePopup(selection: $selection, devices: microphones.devices, defaultTitle: defaultTitle,
                        closedDefaultTitle: defaultName ?? L("System Default"), help: L("Microphone: %@", title))
            // Wide enough for a built-in microphone's name; narrower only where the bar has no room left.
            .frame(minWidth: 120, idealWidth: 212, maxWidth: 212, minHeight: 28, maxHeight: 28)
            .glassEffect(.regular.interactive(isEnabled), in: .capsule)
    }
}

struct MicrophonePopup: NSViewRepresentable {
    @Binding var selection: String?
    let devices: [MicrophoneDevice]
    /// The first entry's title in the open menu, and the shorter one the closed control shows for it.
    let defaultTitle: String
    let closedDefaultTitle: String
    let help: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.cell = MicrophonePopupCell(textCell: "", pullsDown: false)
        control.controlSize = .large
        control.isBordered = false
        control.wantsLayer = true
        control.cell?.lineBreakMode = .byTruncatingMiddle
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectMicrophone(_:))
        context.coordinator.control = control
        return control
    }
    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.reduceMotion = context.environment.accessibilityReduceMotion
        context.coordinator.defaultTitles = (defaultTitle, closedDefaultTitle)
        var items = [("", context.coordinator.menuIsOpen ? defaultTitle : closedDefaultTitle)] + devices.map { ($0.id, $0.name) }
        let missing = selection != nil && !devices.contains { $0.id == selection }
        if let selection, missing { items.append((selection, L("Unavailable Microphone"))) }
        let index = items.firstIndex { $0.0 == (selection ?? "") } ?? 0
        if control.numberOfItems > 0,
           control.selectedItem?.representedObject as? String != items[index].0 || control.title != items[index].1 {
            context.coordinator.fadeSelection(control)
        }
        if control.itemArray.map(\.title) != items.map(\.1) ||
            control.itemArray.map({ $0.representedObject as? String }) != items.map({ Optional($0.0) }) {
            control.removeAllItems()
            for (uid, name) in items {
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.representedObject = uid
                control.menu?.addItem(item)
            }
            control.menu?.autoenablesItems = false
        }
        control.menu?.delegate = context.coordinator
        for item in control.itemArray { item.isEnabled = !(missing && item.representedObject as? String == selection) }
        control.selectItem(at: index)
        control.isEnabled = context.environment.isEnabled
        control.toolTip = help
        control.setAccessibilityLabel(help)
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var selection: Binding<String?>
        var reduceMotion = false
        var defaultTitles = (open: "", closed: "")
        weak var control: NSPopUpButton?
        private(set) var menuIsOpen = false
        init(selection: Binding<String?>) { self.selection = selection }

        // The first entry reads "System Default · name" while the menu is open and "name" on the closed control.
        func menuWillOpen(_ menu: NSMenu) {
            menuIsOpen = true
            menu.items.first?.title = defaultTitles.open
        }
        func menuDidClose(_ menu: NSMenu) {
            menuIsOpen = false
            menu.items.first?.title = defaultTitles.closed
            control?.synchronizeTitleAndSelectedItem()
        }
        @objc func selectMicrophone(_ control: NSPopUpButton) {
            guard let uid = control.selectedItem?.representedObject as? String else { return }
            let selected = uid.isEmpty ? nil : uid
            guard selected != selection.wrappedValue else { return }
            fadeSelection(control)
            selection.wrappedValue = selected
        }

        func fadeSelection(_ control: NSPopUpButton) {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = reduceMotion ? 0.1 : 0.24
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            control.layer?.add(transition, forKey: kCATransition)
        }
    }
}

/// Keep the glass margins inside the native control's clickable bounds.
private final class MicrophonePopupCell: NSPopUpButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.draw(withFrame: cellFrame.insetBy(dx: 12, dy: 6), in: controlView)
    }
}
