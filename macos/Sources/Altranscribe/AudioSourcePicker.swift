import SwiftUI
import AltranscribeCore

/// Keep AppKit's selection, keyboard and accessibility behavior; only fade its rendered selection change.
struct AudioSourcePicker: NSViewRepresentable {
    @Binding var selection: AudioSource

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [AudioSource.microphone.title, AudioSource.system.title],
                                         trackingMode: .selectOne, target: context.coordinator,
                                         action: #selector(Coordinator.selectSource(_:)))
        control.controlSize = .large
        control.segmentDistribution = .fillEqually
        control.selectedSegment = selection == .microphone ? 0 : 1
        control.wantsLayer = true
        control.setAccessibilityLabel(L("Audio Source"))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.reduceMotion = context.environment.accessibilityReduceMotion
        control.isEnabled = context.environment.isEnabled
        control.setAccessibilityLabel(L("Audio Source"))
        for (index, source) in [AudioSource.microphone, .system].enumerated() where control.label(forSegment: index) != source.title {
            control.setLabel(source.title, forSegment: index)
        }
        let index = selection == .microphone ? 0 : 1
        if control.selectedSegment != index {
            context.coordinator.fadeSelection(control)
            control.selectedSegment = index
        }
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<AudioSource>
        var reduceMotion = false

        init(selection: Binding<AudioSource>) { self.selection = selection }

        @objc func selectSource(_ control: NSSegmentedControl) {
            let source: AudioSource = control.selectedSegment == 0 ? .microphone : .system
            guard source != selection.wrappedValue else { return }
            fadeSelection(control)
            selection.wrappedValue = source
        }

        func fadeSelection(_ control: NSSegmentedControl) {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = reduceMotion ? 0.1 : 0.24
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            control.layer?.add(transition, forKey: kCATransition)
        }
    }
}
