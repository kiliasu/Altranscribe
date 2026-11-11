import 'dart:async';
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

  /// Content going away, which takes less time than arriving.
  static const leave = Duration(milliseconds: 180);

  /// What every transition becomes with reduced motion.
  static const fade = Duration(milliseconds: 120);

  /// The springs of the art direction: a control that turns or swaps, and
  /// a pressed segment pushing its neighbours aside.
  static const spring = Duration(milliseconds: 500);
  static const springFast = Duration(milliseconds: 350);

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

/// One page giving way to another. The page that leaves fades out quickly
/// while the new one fades in from a slight blur at its own size, so
/// nothing on it is scaled or moved while it settles. Pages are told apart
/// by [page]. With reduced motion the new page is simply there.
class AltPageSwitcher extends StatefulWidget {
  const AltPageSwitcher({
    super.key,
    required this.page,
    required this.child,
    this.lingers = true,
  });
  final String page;
  final Widget child;

  /// Whether this page may still be on screen, fading, once another has
  /// taken its place. A page that owns global keys or a controller must not
  /// be: the page that follows may need them at once.
  final bool lingers;
  @override
  State<AltPageSwitcher> createState() => _AltPageSwitcherState();
}

class _AltPageSwitcherState extends State<AltPageSwitcher>
    with TickerProviderStateMixin {
  late final enter = AnimationController(
    vsync: this,
    duration: AltMotion.content,
  );
  late final leave = AnimationController(
    vsync: this,
    duration: AltMotion.leave,
  );
  late final entering = CurvedAnimation(
    parent: enter,
    curve: AltMotion.contentCurve,
  );
  late final leaving = ReverseAnimation(
    CurvedAnimation(parent: leave, curve: AltMotion.quickCurve),
  );
  Widget? previous;
  String previousPage = '';
  bool started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (started) return;
    started = true;
    if (AltMotion.reduced(context)) {
      enter.value = 1;
    } else {
      enter.forward();
    }
  }

  @override
  void didUpdateWidget(AltPageSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page == widget.page) return;
    if (AltMotion.reduced(context)) {
      previous = null;
      enter.value = 1;
      return;
    }
    previous = oldWidget.lingers ? oldWidget.child : null;
    previousPage = oldWidget.page;
    if (previous != null) {
      leave.forward(from: 0).whenCompleteOrCancel(() {
        if (mounted && leave.isCompleted) setState(() => previous = null);
      });
    }
    enter.forward(from: 0);
  }

  @override
  void dispose() {
    entering.dispose();
    enter.dispose();
    leave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (previous != null)
        _PageLayer(
          key: ValueKey(previousPage),
          animation: leaving,
          leaving: true,
          child: previous!,
        ),
      _PageLayer(
        key: ValueKey(widget.page),
        animation: entering,
        leaving: false,
        child: widget.child,
      ),
    ],
  );
}

/// A page while it arrives or leaves. Both are one widget, so a page keeps
/// its state as it turns from the one to the other.
class _PageLayer extends StatelessWidget {
  const _PageLayer({
    super.key,
    required this.animation,
    required this.leaving,
    required this.child,
  });
  final Animation<double> animation;
  final bool leaving;
  final Widget child;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final value = animation.value.clamp(0.0, 1.0);
      return IgnorePointer(
        ignoring: leaving,
        child: ExcludeSemantics(
          excluding: leaving,
          child: Opacity(
            opacity: value,
            child: ImageFiltered(
              enabled: !leaving && value < 1,
              imageFilter: ImageFilter.blur(
                sigmaX: 6 * (1 - value),
                sigmaY: 6 * (1 - value),
              ),
              child: child,
            ),
          ),
        ),
      );
    },
    child: child,
  );
}

/// Something that comes and goes in the flow: a notice, an extra field, a
/// button beside a title. It makes room for itself as it fades in, and the
/// room closes as it fades out; pass null for nothing. While it leaves it
/// stays as it last was and takes no input, and should it be wanted again
/// meanwhile, it opens again from where it had got to.
class AltReveal extends StatelessWidget {
  const AltReveal({
    super.key,
    required this.child,
    this.axis = Axis.vertical,
    this.stretch = true,
  });
  final Widget? child;
  final Axis axis;

  /// A child that opens downwards takes the full width it is given, as it
  /// would in a column that stretches its children. Turn this off where
  /// the width is unbounded.
  final bool stretch;
  @override
  Widget build(BuildContext context) {
    final vertical = axis == Axis.vertical;
    return _Presence(
      child: child,
      builder: (context, animation, leaving, lifted, child) => SizeTransition(
        axis: axis,
        sizeFactor: animation,
        // It opens from its leading edge, so what is before it stays put.
        alignment: vertical ? Alignment.topCenter : Alignment.centerLeft,
        fixedCrossAxisSizeFactor: vertical && stretch ? null : 1,
        child: FadeTransition(
          opacity: animation,
          child: vertical && stretch
              ? SizedBox(width: double.infinity, child: child)
              : child,
        ),
      ),
    );
  }
}

/// Something that floats over the page, or stands in a fixed place, while
/// it has a reason to: it rises in as it fades in and lifts away as it
/// fades out, taking no room of its own to do so. Pass null for nothing,
/// and a [distance] of zero for a fade alone. Like [AltReveal], it leaves
/// as it last was and comes back from where it had got to.
class AltPresence extends StatelessWidget {
  const AltPresence({super.key, required this.child, this.distance = 10});
  final Widget? child;
  final double distance;
  @override
  Widget build(BuildContext context) => _Presence(
    child: child,
    builder: (context, animation, leaving, lifted, child) {
      if (distance == 0 || AltMotion.reduced(context)) {
        return FadeTransition(opacity: animation, child: child);
      }
      return AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Opacity(
          opacity: animation.value.clamp(0.0, 1.0),
          child: Transform.translate(
            // Up from below; once it has started to lift away, it lifts
            // and returns along the same short way.
            offset: Offset(
              0,
              (1 - animation.value) * (lifted ? -.6 * distance : distance),
            ),
            child: child,
          ),
        ),
        child: child,
      );
    },
  );
}

typedef _PresenceBuilder = Widget Function(
  BuildContext context,
  Animation<double> animation,
  bool leaving,
  bool lifted,
  Widget child,
);

class _Presence extends StatefulWidget {
  const _Presence({required this.child, required this.builder});
  final Widget? child;
  final _PresenceBuilder builder;
  @override
  State<_Presence> createState() => _PresenceState();
}

class _PresenceState extends State<_Presence>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late final CurvedAnimation animation;

  /// What is on screen: the child, or the child as it last was.
  Widget? shown;
  bool leaving = false;

  /// It has started to leave since it last arrived in full.
  bool lifted = false;

  @override
  void initState() {
    super.initState();
    // What is there when this is first built is simply there.
    shown = widget.child;
    controller = AnimationController(vsync: this, value: shown == null ? 0 : 1);
    animation = CurvedAnimation(
      parent: controller,
      curve: AltMotion.contentCurve,
      reverseCurve: Curves.easeOutCubic,
    );
  }

  @override
  void didUpdateWidget(_Presence oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduced = AltMotion.reduced(context);
    if (widget.child != null) {
      shown = widget.child;
      if (!leaving && oldWidget.child != null) return;
      leaving = false;
      controller
        ..duration = reduced ? AltMotion.fade : AltMotion.content
        ..forward().whenCompleteOrCancel(() {
          if (controller.isCompleted) lifted = false;
        });
    } else if (oldWidget.child != null) {
      leaving = true;
      lifted = true;
      controller
        ..reverseDuration = reduced ? AltMotion.fade : AltMotion.quick
        ..reverse().whenCompleteOrCancel(() {
          if (!mounted || !controller.isDismissed) return;
          setState(() {
            shown = null;
            leaving = false;
            lifted = false;
          });
        });
    }
  }

  @override
  void dispose() {
    animation.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = this.shown;
    if (shown == null) return const SizedBox.shrink();
    return widget.builder(
      context,
      animation,
      leaving,
      lifted,
      IgnorePointer(
        ignoring: leaving,
        child: ExcludeSemantics(excluding: leaving, child: shown),
      ),
    );
  }
}

/// One thing replacing another in the same place: the controls of one mode
/// for those of another. The old child fades out where it was as the new
/// one fades in, and the room they take goes smoothly from one size to the
/// other. Children are told apart by type and key. It needs a width to fill,
/// as a column that stretches its children gives.
class AltSwap extends StatelessWidget {
  const AltSwap({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final reduced = AltMotion.reduced(context);
    // A size animation that took no time would change its own layout while
    // laying out; with reduced motion it is only short.
    final duration = reduced ? AltMotion.fade : AltMotion.content;
    return ClipRect(
      child: AnimatedSize(
        duration: duration,
        curve: AltMotion.contentCurve,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: duration,
          reverseDuration: reduced ? AltMotion.fade : AltMotion.quick,
          switchInCurve: AltMotion.contentCurve,
          switchOutCurve: Curves.easeOutCubic,
          // The new child alone decides the size; the old ones keep their
          // place at the top until they have faded.
          layoutBuilder: (current, previous) => Stack(
            clipBehavior: Clip.none,
            children: [
              for (final child in previous)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(child: ExcludeSemantics(child: child)),
                ),
              ?current,
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A column whose children come and go, each told apart by its key. One
/// that is new makes room for itself as it fades in; one that is gone fades
/// as the room closes. Nothing moves when the column is first shown, or
/// while [animate] is off, as when a search narrows a list at every
/// keystroke.
class AltFlow extends StatefulWidget {
  const AltFlow({super.key, required this.children, this.animate = true});
  final List<Widget> children;
  final bool animate;
  @override
  State<AltFlow> createState() => _AltFlowState();
}

class _FlowEntry {
  _FlowEntry(this.child, this.controller);
  Widget child;
  final AnimationController controller;
  bool leaving = false;
  Key get key => child.key!;
}

class _AltFlowState extends State<AltFlow> with TickerProviderStateMixin {
  late List<_FlowEntry> entries = [
    for (final child in widget.children) _entry(child, shown: true),
  ];

  _FlowEntry _entry(Widget child, {required bool shown}) {
    assert(child.key != null, 'Every child of an AltFlow needs a key.');
    return _FlowEntry(
      child,
      AnimationController(vsync: this, value: shown ? 1 : 0),
    );
  }

  @override
  void didUpdateWidget(AltFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduced = AltMotion.reduced(context);
    final animate = widget.animate;
    final known = {for (final entry in entries) entry.key: entry};
    final merged = <_FlowEntry>[];
    final present = <Key>{};
    // The children, in their own order: those already here, and new ones
    // that open.
    for (final child in widget.children) {
      if (!present.add(child.key!)) continue;
      var entry = known[child.key];
      if (entry == null) {
        entry = _entry(child, shown: !animate);
        if (animate) {
          entry.controller
            ..duration = reduced ? AltMotion.fade : AltMotion.content
            ..forward();
        }
      } else {
        entry.child = child;
        if (entry.leaving) {
          // Wanted again while it closes: it opens from where it had got.
          entry.leaving = false;
          if (animate) {
            entry.controller
              ..duration = reduced ? AltMotion.fade : AltMotion.content
              ..forward();
          } else {
            entry.controller.value = 1;
          }
        }
      }
      merged.add(entry);
    }
    // Those that are gone keep the place they had, after what was before
    // them, until they have closed.
    for (final (i, entry) in entries.indexed) {
      if (present.contains(entry.key)) continue;
      if (!entry.leaving) {
        if (!animate) {
          entry.controller.dispose();
          continue;
        }
        entry.leaving = true;
        entry.controller
          ..duration = reduced ? AltMotion.fade : AltMotion.quick
          ..reverse().whenCompleteOrCancel(() {
            if (!mounted || !entry.leaving || !entry.controller.isDismissed) {
              return;
            }
            setState(() => entries.remove(entry));
            entry.controller.dispose();
          });
      } else if (!animate) {
        entry.controller.dispose();
        continue;
      }
      var at = 0;
      for (var j = i - 1; j >= 0; j--) {
        final before = merged.indexOf(entries[j]);
        if (before >= 0) {
          at = before + 1;
          break;
        }
      }
      merged.insert(at, entry);
    }
    entries = merged;
  }

  @override
  void dispose() {
    for (final entry in entries) {
      entry.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final entry in entries)
        _FlowItem(
          key: entry.key,
          animation: entry.controller,
          leaving: entry.leaving,
          child: entry.child,
        ),
    ],
  );
}

class _FlowItem extends StatelessWidget {
  const _FlowItem({
    super.key,
    required this.animation,
    required this.leaving,
    required this.child,
  });
  final Animation<double> animation;
  final bool leaving;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final curved = CurveTween(
      curve: leaving ? Curves.easeOutCubic : AltMotion.contentCurve,
    ).animate(animation);
    return SizeTransition(
      sizeFactor: curved,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: curved,
        child: IgnorePointer(
          ignoring: leaving,
          child: ExcludeSemantics(
            excluding: leaving,
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      ),
    );
  }
}

/// Opens a dialog the way content arrives everywhere else: it rises a
/// little as it fades in, and lifts away as it fades out. With reduced
/// motion it only fades.
Future<T?> showAltDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final reduced = AltMotion.reduced(context);
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    animationStyle: AnimationStyle(
      duration: reduced ? AltMotion.fade : AltMotion.quick,
      curve: AltMotion.contentCurve,
      // Leaving, it is mostly gone in the first moments.
      reverseCurve: Curves.easeInCubic,
    ),
    builder: (context) => reduced
        ? builder(context)
        : _DialogRise(child: Builder(builder: builder)),
  );
}

class _DialogRise extends StatelessWidget {
  const _DialogRise({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null) return child;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final leaving = animation.status == AnimationStatus.reverse;
        final value = leaving
            ? animation.value
            : AltMotion.contentCurve.transform(animation.value);
        return Transform.translate(
          offset: Offset(0, (1 - value) * (leaving ? -6 : 14)),
          child: child,
        );
      },
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

class _PulsingDotState extends State<PulsingDot> {
  /// The dot is on screen for as long as a session lasts. A ticker would
  /// draw the whole window at the display's rate for it; fifteen steps a
  /// second are as smooth for a slow fade and leave the screen at rest
  /// between them.
  static const _step = Duration(milliseconds: 66);
  static const _period = 1800;
  Timer? _timer;
  final _clock = Stopwatch();
  double _opacity = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(PulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  void _update() {
    final pulse = widget.pulsing && !AltMotion.reduced(context);
    if (pulse && _timer == null) {
      _clock
        ..reset()
        ..start();
      _timer = Timer.periodic(_step, (_) {
        final phase = _clock.elapsedMilliseconds % _period / _period;
        // Down to 35 % and back, easing at both ends.
        setState(() => _opacity = .675 + .325 * math.cos(2 * math.pi * phase));
      });
    } else if (!pulse && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _opacity = 1;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // A plain box: an implicitly animated one would start a new animation
  // at every step and run at the display's rate after all.
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox.square(
      dimension: widget.size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: widget.color.a * _opacity),
          shape: BoxShape.circle,
        ),
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
