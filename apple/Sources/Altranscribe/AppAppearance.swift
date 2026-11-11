import AppKit

/// Change the native appearance beneath fading snapshots, without resizing controls.
@MainActor enum AppAppearance {
    private static var snapshots: [NSImageView] = []

    static func apply(_ preference: String, animated: Bool = true,
                      reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        let appearance = preference == "dark" ? NSAppearance(named: .darkAqua) : preference == "light" ? NSAppearance(named: .aqua) : nil
        guard NSApp.appearance?.name != appearance?.name else { return }
        snapshots.forEach { $0.removeFromSuperview() }
        snapshots = []
        if animated {
            for window in NSApp.windows where window.isVisible {
                guard let frame = window.contentView?.superview,
                      let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                let image = NSImage(size: frame.bounds.size); image.addRepresentation(bitmap)
                let overlay = SnapshotView(frame: frame.bounds)
                overlay.image = image; overlay.imageScaling = .scaleAxesIndependently
                overlay.autoresizingMask = [.width, .height]
                overlay.setAccessibilityElement(false)
                frame.addSubview(overlay, positioned: .above, relativeTo: nil)
                snapshots.append(overlay)
            }
        }
        // Application-wide appearance also covers the independently hosted caption panel and future windows.
        NSApp.appearance = appearance
        let fading = snapshots
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.1 : 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fading.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            MainActor.assumeIsolated {
                fading.forEach { $0.removeFromSuperview() }
                snapshots.removeAll { snapshot in fading.contains { $0 === snapshot } }
            }
        }
    }

    private final class SnapshotView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
