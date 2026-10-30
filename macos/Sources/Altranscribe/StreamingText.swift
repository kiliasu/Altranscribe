import SwiftUI

/// Draw the complete result immediately; only its changed suffix settles into place.
/// A single Text preserves native wrapping, selection and accessibility for both scripts and emoji.
struct StreamingText: View {
    let text: String
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stableCharacters = Int.max
    @State private var changedAt: Date?

    init(_ text: String, active: Bool = true) { self.text = text; self.active = active }

    var body: some View {
        Group {
            if active && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: changedAt == nil)) { timeline in
                    let progress = changedAt.map { min(1, max(0, timeline.date.timeIntervalSince($0) / 0.18)) } ?? 1
                    Self.content(text, stableCharacters: stableCharacters)
                        .textRenderer(StreamingTextRenderer(progress: progress))
                }
            } else {
                Text(verbatim: text)
            }
        }
        .onChange(of: text) { old, new in
            if active && !reduceMotion {
                stableCharacters = Self.commonPrefix(old, new)
                changedAt = .now
            }
        }
        .task(id: changedAt) {
            guard changedAt != nil else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            settle()
        }
        .onDisappear { settle() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in settle() }
    }

    private func settle() {
        changedAt = nil
        stableCharacters = Int.max
    }

    static func commonPrefix(_ old: String, _ new: String) -> Int {
        zip(old, new).prefix { $0 == $1 }.count
    }

    static func content(_ text: String, stableCharacters: Int) -> Text {
        let boundary = text.index(text.startIndex, offsetBy: min(stableCharacters, text.count))
        let prefix = Text(verbatim: String(text[..<boundary]))
        let suffix = Text(verbatim: String(text[boundary...])).customAttribute(StreamingSuffix())
        return Text("\(prefix)\(suffix)")
    }
}

/// Keep layout at its full reading size while the previous sentence gently recedes.
struct SentenceEmphasis: ViewModifier {
    let current: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(current == false && !reduceMotion ? 0.96 : 1, anchor: .leading)
            .opacity(current == false ? 0.72 : 1)
            .animation(reduceMotion ? .easeInOut(duration: 0.12) : .smooth(duration: 0.55), value: current)
    }
}

private struct StreamingSuffix: TextAttribute { }

struct StreamingTextRenderer: TextRenderer {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    var displayPadding: EdgeInsets { EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 0) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                var drawing = context
                if run[StreamingSuffix.self] != nil {
                    let amount = min(1, max(0, progress))
                    drawing.opacity *= 0.45 + 0.55 * amount
                    drawing.translateBy(x: 0, y: 2 * (1 - amount))
                }
                drawing.draw(run)
            }
        }
    }
}
