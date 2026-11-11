import 'dart:math' as math;
import 'dart:ui' show ImageFilter, PathMetric;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

/// The app's motion vocabulary. Each kind of change moves the same way
/// wherever it happens:
///
/// - Content entering the flow (a line, a translation, a notice) rises into
///   place as it fades in; content leaving fades as it lifts away, so time
///   always reads from bottom to top.
/// - Something changing in place (a status, a count, an icon) cross-fades,
///   and digits roll.
/// - A page giving way to another blurs across at its own size.
/// - Finished work draws its checkmark.
///
/// With reduced motion, movement and blur fall away and every change is a
/// short cross-fade.
abstract final class AltMotion {
  /// Small controls and marks: icons, counts, chips, a status.
  static const quick = Duration(milliseconds: 240);

  /// Content arriving, leaving or rearranging: lines, panels, pages.
  static const content = Duration(milliseconds: 400);

  /// A line giving way to the next one as it recedes.
  static const settle = Duration(milliseconds: 550);

  /// How long the end of a task, such as "Saved", stays in view.
  static const acknowledgement = Duration(milliseconds: 1800);

  /// What every transition becomes with reduced motion.
  static const fade = Duration(milliseconds: 120);

  static const quickCurve = Curves.easeOutCubic;
  static const contentCurve = Cubic(.2, 0, 0, 1);

  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// The new child rises in while the old one lifts away. For an
  /// [AnimatedSwitcher] whose children replace each other in place.
  static Widget rise(Widget child, Animation<double> animation) =>
      _Moving(animation: animation, enter: 10, leave: -6, child: child);

  /// Digits that change roll: the old one leaves upwards as the new one
  /// comes up from below.
  static Widget roll(Widget child, Animation<double> animation) => ClipRect(
    child: _Moving(
      animation: animation,
      enter: 12,
      leave: -12,
      curve: quickCurve,
      child: child,
    ),
  );
}

/// Fades [child] with [animation] and moves it: from [enter] pixels below
/// while it arrives, to [leave] pixels while it goes, which an
/// [AnimatedSwitcher] tells apart by the reversing animation.
class _Moving extends StatelessWidget {
  const _Moving({
    required this.animation,
    required this.enter,
    required this.leave,
    required this.child,
    this.curve = AltMotion.contentCurve,
  });
  final Animation<double> animation;
  final double enter;
  final double leave;
  final Curve curve;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (AltMotion.reduced(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final leaving = animation.status == AnimationStatus.reverse;
        final value = curve.transform(animation.value);
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * (leaving ? leave : enter)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Rises into place and fades in when it is first built and [animate] is
/// set; otherwise, and once it has arrived, it is simply its child.
class AltRise extends StatefulWidget {
  const AltRise({
    super.key,
    required this.child,
    this.animate = true,
    this.distance = 10,
    this.delay = Duration.zero,
  });
  final Widget child;
  final bool animate;
  final double distance;
  final Duration delay;
  @override
  State<AltRise> createState() => _AltRiseState();
}

class _AltRiseState extends State<AltRise> with SingleTickerProviderStateMixin {
  AnimationController? controller;
  bool reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (controller != null || !widget.animate) return;
    reduced = AltMotion.reduced(context);
    final total = (reduced ? AltMotion.fade : AltMotion.content) + widget.delay;
    controller = AnimationController(vsync: this, duration: total)..forward();
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null) return widget.child;
    final start =
        widget.delay.inMicroseconds / controller.duration!.inMicroseconds;
    final progress = CurvedAnimation(
      parent: controller,
      curve: Interval(
        start.clamp(0, 1),
        1,
        curve: reduced ? Curves.linear : AltMotion.contentCurve,
      ),
    );
    return AnimatedBuilder(
      animation: progress,
      builder: (context, child) => Opacity(
        opacity: progress.value,
        child: Transform.translate(
          offset: Offset(
            0,
            reduced ? 0 : (1 - progress.value) * widget.distance,
          ),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// A page coming into view: it fades in from a slight blur at its own size,
/// so nothing on it is scaled or moved while it settles.
class AltPageIn extends StatelessWidget {
  const AltPageIn({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    // With reduced motion the page is simply there.
    final reduced = AltMotion.reduced(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduced ? 1 : 0, end: 1),
      duration: reduced ? Duration.zero : AltMotion.content,
      curve: AltMotion.contentCurve,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: ImageFiltered(
          enabled: !reduced && value < 1,
          imageFilter: ImageFilter.blur(
            sigmaX: 6 * (1 - value),
            sigmaY: 6 * (1 - value),
          ),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Text whose characters roll when they change, for clocks and counters.
/// Figures keep one width, so the text does not shift as they change.
class RollingText extends StatelessWidget {
  const RollingText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) {
    final style = (this.style ?? const TextStyle()).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (AltMotion.reduced(context)) return Text(text, style: style);
    final characters = text.characters.toList();
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          for (final (i, character) in characters.indexed)
            AnimatedSwitcher(
              duration: AltMotion.quick,
              transitionBuilder: AltMotion.roll,
              child: Text(
                character,
                // Counted from the end, so a number that gains a digit
                // keeps its ones and tens where they were.
                key: ValueKey('${characters.length - i} $character'),
                style: style,
              ),
            ),
        ],
      ),
    );
  }
}

/// The red of a recording in progress, which reads the same in light and
/// dark themes.
const recordingRed = Color(0xFFE53935);

/// A dot that pulses while something is live and holds still otherwise.
/// It repaints only itself.
class PulsingDot extends StatefulWidget {
  const PulsingDot({
    super.key,
    required this.color,
    this.pulsing = true,
    this.size = 10,
  });
  final Color color;
  final bool pulsing;
  final double size;
  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final opacity = Tween<double>(
    begin: 1,
    end: .35,
  ).animate(CurvedAnimation(parent: controller, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    update();
  }

  @override
  void didUpdateWidget(PulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    update();
  }

  void update() {
    if (widget.pulsing && !AltMotion.reduced(context)) {
      if (!controller.isAnimating) controller.repeat(reverse: true);
    } else {
      controller.value = 0;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: FadeTransition(
      opacity: opacity,
      child: AnimatedContainer(
        duration: AltMotion.quick,
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    ),
  );
}

/// A checkmark in a filled circle that draws itself in when it first
/// appears; pass [animate] false for work that was finished before it was
/// shown.
class DrawnCheckmark extends StatefulWidget {
  const DrawnCheckmark({
    super.key,
    this.size = 22,
    this.color,
    this.checkColor,
    this.animate = true,
  });
  final double size;
  final Color? color;
  final Color? checkColor;
  final bool animate;
  @override
  State<DrawnCheckmark> createState() => _DrawnCheckmarkState();
}

class _DrawnCheckmarkState extends State<DrawnCheckmark>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (controller.isAnimating || controller.value > 0) return;
    if (widget.animate && !AltMotion.reduced(context)) {
      controller.forward();
    } else {
      controller.value = 1;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _CheckPainter(
          controller,
          widget.color ?? colors.primary,
          widget.checkColor ?? colors.onPrimary,
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.progress, this.color, this.checkColor)
    : super(repaint: progress);
  final Animation<double> progress;
  final Color color;
  final Color checkColor;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final circle = Curves.easeOutBack.transform((t / .45).clamp(0, 1));
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      size.shortestSide / 2 * (.6 + .4 * circle),
      Paint()..color = color.withValues(alpha: color.a * circle.clamp(0, 1)),
    );
    final drawn = Curves.easeInOutCubic.transform(
      ((t - .35) / .65).clamp(0, 1),
    );
    if (drawn <= 0) return;
    final s = size.shortestSide;
    final check = Path()
      ..moveTo(s * .29, s * .52)
      ..lineTo(s * .44, s * .66)
      ..lineTo(s * .72, s * .37);
    final paint = Paint()
      ..color = checkColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, s * .11)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final metrics = check.computeMetrics().toList();
    final length = metrics.fold<double>(0, (sum, m) => sum + m.length);
    var remaining = length * drawn;
    for (final PathMetric metric in metrics) {
      if (remaining <= 0) break;
      canvas.drawPath(
        metric.extractPath(0, math.min(remaining, metric.length)),
        paint,
      );
      remaining -= metric.length;
    }
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.color != color || old.checkColor != checkColor;
}

/// The last moments of input level as bars that scroll from right to left,
/// the way a voice recorder shows them.
class LevelMeter extends StatelessWidget {
  const LevelMeter({
    super.key,
    required this.samples,
    required this.color,
    this.bars = 24,
    this.height = 20,
  });
  final List<double> samples;
  final Color color;
  final int bars;
  final double height;
  static const _bar = 2.5;
  static const _gap = 2.0;
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size(bars * (_bar + _gap) - _gap, height),
      painter: _MeterPainter(
        samples.length > bars
            ? samples.sublist(samples.length - bars)
            : samples,
        bars,
        color,
      ),
    ),
  );
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.samples, this.bars, this.color);
  final List<double> samples;
  final int bars;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final missing = bars - samples.length;
    for (var i = 0; i < bars; i++) {
      final level = i < missing ? 0.0 : samples[i - missing].clamp(0.0, 1.0);
      // Perceptual scaling keeps quiet speech visible and silence flat.
      final height = 3 + math.sqrt(level) * (size.height - 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i * (LevelMeter._bar + LevelMeter._gap),
            (size.height - height) / 2,
            LevelMeter._bar,
            height,
          ),
          const Radius.circular(LevelMeter._bar / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.color != color || !listEquals(old.samples, samples);
}

/// Content fades out where it passes under a bar that floats over it,
/// instead of showing through the bar's labels. The fade is drawn in the
/// page's own color, so it needs no layer of its own.
class EdgeFade extends StatelessWidget {
  const EdgeFade({
    super.key,
    required this.child,
    this.top = 16,
    this.bottom = 0,
    this.bottomClear = 0,
    this.color,
  });
  final Widget child;

  /// How far the fade reaches at the top edge.
  final double top;

  /// How far the fade reaches above the bottom edge, and how much of that,
  /// from the edge up, is fully covered.
  final double bottom;
  final double bottomClear;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Theme.of(context).colorScheme.surface;
    final clear = color.withValues(alpha: 0);
    return Stack(
      children: [
        child,
        if (top > 0)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: top,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [color, clear],
                  ),
                ),
              ),
            ),
          ),
        if (bottom > 0)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: bottom,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    stops: [0, bottomClear / bottom, 1],
                    colors: [color, color, clear],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
