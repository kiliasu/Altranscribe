import SwiftUI

/// The app's motion vocabulary. Each kind of change moves the same way wherever it happens:
///
/// - New content entering the flow (a line, a translation, a card, a row) rises into place and fades in;
///   when it leaves it fades as it lifts away, so time always reads from bottom to top.
/// - Something changing state in place (a label, a count, a symbol) cross-fades, rolls or replaces its symbol.
/// - A whole view giving way to another (a welcome page and its transcript) blurs across.
/// - Small marks and accessories (a timer, a dot, a chip) pop in and out.
/// - Finished work draws its checkmark; failed work shakes its mark once.
///
/// With Reduce Motion the movement, scaling and blur fall away and every transition becomes a cross-fade.
enum Motion {
    /// Small controls and marks: icons, counts, chips, hover affordances.
    static let quick = Animation.snappy(duration: 0.24)
    /// Content arriving, leaving or rearranging: lines, cards, rows, pages.
    static let content = Animation.smooth(duration: 0.4)
    /// Seconds the end of a task, such as "Saved", stays in view before the controls move on.
    static let acknowledgement: TimeInterval = 1.8
}

extension AnyTransition {
    /// One set of controls replacing another in the same place, such as a settings page: the old set leaves
    /// quickly and the new one settles in after it, so the two never read as one overlapping layout.
    static var swap: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.quick.delay(0.08)),
                    removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
}

extension Transition where Self == MotionTransition {
    static var rise: MotionTransition { MotionTransition(style: .rise) }
    static var pop: MotionTransition { MotionTransition(style: .pop) }
    static var page: MotionTransition { MotionTransition(style: .page) }
}

struct MotionTransition: Transition {
    enum Style { case rise, pop, page }
    let style: Style

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(MotionPhase(style: style, phase: phase))
    }
}

private struct MotionPhase: ViewModifier {
    let style: MotionTransition.Style
    let phase: TransitionPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let moving = !reduceMotion && !phase.isIdentity
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(y: moving && style == .rise ? (phase == .willAppear ? 10 : -6) : 0)
            .scaleEffect(moving ? (style == .pop ? 0.82 : style == .page ? 0.985 : 1) : 1)
            .blur(radius: moving && style == .page ? 6 : 0)
    }
}

/// A checkmark that draws itself in when it first appears, the way Apple Pay confirms a payment.
/// Pass `animated: false` for work that was already finished before the view was shown.
struct DrawnCheckmark: View {
    var symbol = "checkmark.circle.fill"
    var animated = true
    @State private var drawn = false

    var body: some View {
        ZStack {
            Image(systemName: symbol).hidden()
            if drawn {
                Image(systemName: symbol).transition(.symbolEffect(.drawOn))
            }
        }
        .onAppear {
            guard !drawn else { return }
            if animated { withAnimation(Motion.quick.delay(0.06)) { drawn = true } } else { drawn = true }
        }
    }
}

extension View {
    /// Rolls digits instead of swapping the whole string, for timers and counters.
    func rollingNumbers<Value: Equatable>(_ value: Value) -> some View {
        contentTransition(.numericText()).animation(Motion.quick, value: value)
    }
}
