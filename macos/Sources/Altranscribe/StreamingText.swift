import SwiftUI

/// Draw the complete result immediately; only its changed suffix settles into place.
/// A single Text preserves native wrapping, selection and accessibility for both scripts and emoji.
struct StreamingText: View {
    let text: String
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stableCharacters = Int.max

    init(_ text: String, active: Bool = true) { self.text = text; self.active = active }

    var body: some View {
        let animate = active && !reduceMotion
        Self.content(text, stableCharacters: stableCharacters)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: text) { content, progress in
                content.textRenderer(StreamingTextRenderer(progress: animate ? progress : 1))
            } keyframes: { _ in
                MoveKeyframe(0)
                CubicKeyframe(1, duration: 0.18)
            }
            .onChange(of: text) { old, new in
                stableCharacters = Self.commonPrefix(old, new)
            }
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
