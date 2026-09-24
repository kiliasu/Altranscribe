import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

// Account for the native chip's two-pixel border to keep a 32px height.
const altChipDensity = VisualDensity(vertical: -1);
const altChipIconBounds = BoxConstraints.tightFor(width: 18, height: 18);

// Keep value-indicator portals within the slider's semantic subtree. Flutter
// 3.47.3 can otherwise serialize orphan nodes when a dialog route is pushed.
// https://github.com/flutter/flutter/issues/190357
Widget sliderWithLocalOverlay(Slider slider) => Overlay.wrap(
  alwaysSizeToContent: true,
  clipBehavior: Clip.none,
  child: slider,
);

// Sampled spring curves and floating elevation.
const altSpatial = _SampledCurve(
  [0, .281, .66, .891, .988, 1.014, 1.013, 1.007, 1.002, 1],
  [0, .1, .2, .3, .4, .5, .6, .7, .8, 1],
);
const altSpatialFast = _SampledCurve([
  0,
  .318,
  .775,
  1.034,
  1.095,
  1.063,
  1.02,
  .997,
  .991,
  .995,
  1,
]);
const altFloatingShadow = [
  BoxShadow(color: Color(0x4D000000), offset: Offset(0, 1), blurRadius: 3),
  BoxShadow(
    color: Color(0x26000000),
    offset: Offset(0, 4),
    blurRadius: 8,
    spreadRadius: 3,
  ),
];

class _SampledCurve extends Curve {
  const _SampledCurve(this.values, [this.stops]);
  final List<double> values;
  final List<double>? stops;
  @override
  double transformInternal(double t) {
    for (var i = 1; i < values.length; i++) {
      final end = stops?[i] ?? i / (values.length - 1);
      if (t <= end) {
        final start = stops?[i - 1] ?? (i - 1) / (values.length - 1);
        return values[i - 1] +
            (values[i] - values[i - 1]) * (t - start) / (end - start);
      }
    }
    return 1;
  }
}

class AltGroupItem {
  const AltGroupItem(this.label, {this.icon, this.key});
  final String label;
  final IconData? icon;
  final Key? key;
}

/// Connected buttons with a two-pixel gap and press expansion.
class AltButtonGroup extends StatefulWidget {
  const AltButtonGroup({
    super.key,
    required this.items,
    required this.selected,
    required this.onPressed,
    this.height = 40,
    this.stretch = false,
  });
  final List<AltGroupItem> items;
  final Set<int> selected;
  final ValueChanged<int>? onPressed;
  final double height;
  final bool stretch;
  @override
  State<AltButtonGroup> createState() => _AltButtonGroupState();
}

class _AltButtonGroupState extends State<AltButtonGroup> {
  int? pressed;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final medium = widget.height >= 56;
    final style = medium
        ? Theme.of(context).textTheme.titleMedium!
              .copyWith(fontWeight: FontWeight.w500)
        : Theme.of(context).textTheme.labelLarge!;
    final horizontal = medium
        ? 24.0
        : widget.height <= 32
        ? 12.0
        : 16.0;
    double natural = 0;
    for (final item in widget.items) {
      final painter = TextPainter(
        text: TextSpan(text: item.label, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      natural = math.max(
        natural,
        painter.width +
            horizontal * 2 +
            (item.icon == null ? 0 : (medium ? 32 : 28)),
      );
      painter.dispose();
    }
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final count = widget.items.length;
          final width = widget.stretch
              ? constraints.maxWidth
              : math.min(
                  constraints.maxWidth,
                  natural * count + 2 * (count - 1),
                );
          final weights = List<double>.generate(
            count,
            (i) => pressed == null
                ? 1
                : pressed == i
                ? 1.15
                : (pressed! - i).abs() == 1
                ? .9
                : 1,
          );
          final sum = weights.reduce((a, b) => a + b);
          return SizedBox(
            width: width,
            height: widget.height,
            child: Row(
              children: [
                for (var i = 0; i < count; i++) ...[
                  if (i != 0) const SizedBox(width: 2),
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: weights[i] / sum),
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 350),
                    curve: altSpatialFast,
                    builder: (context, weight, child) => Expanded(
                      flex: (weight * 1000000).round(),
                      child: child!,
                    ),
                    child: Semantics(
                      selected: widget.selected.contains(i),
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: widget.onPressed == null
                            ? null
                            : (_) => setState(() => pressed = i),
                        onPointerUp: (_) => setState(() => pressed = null),
                        onPointerCancel: (_) => setState(() => pressed = null),
                        child: FilledButton(
                          key: widget.items[i].key,
                          onPressed: widget.onPressed == null
                              ? null
                              : () => widget.onPressed!(i),
                          onHover: (hover) {
                            if (!hover && pressed == i) {
                              setState(() => pressed = null);
                            }
                          },
                          style: ButtonStyle(
                            minimumSize: WidgetStatePropertyAll(
                              Size(0, widget.height),
                            ),
                            padding: const WidgetStatePropertyAll(
                              EdgeInsets.symmetric(horizontal: 8),
                            ),
                            backgroundColor: WidgetStatePropertyAll(
                              widget.selected.contains(i)
                                  ? colors.primary
                                  : colors.surfaceContainer,
                            ),
                            foregroundColor: WidgetStatePropertyAll(
                              widget.selected.contains(i)
                                  ? colors.onPrimary
                                  : colors.onSurfaceVariant,
                            ),
                            textStyle: WidgetStatePropertyAll(style),
                            shape: WidgetStateProperty.resolveWith((states) {
                              final down = states.contains(WidgetState.pressed);
                              // The shape follows the same tokens for mouse and keyboard presses.
                              final inner = down || widget.selected.contains(i)
                                  ? (medium ? 12.0 : 8.0)
                                  : 8.0;
                              return RoundedRectangleBorder(
                                borderRadius: BorderRadius.horizontal(
                                  left: Radius.circular(
                                    i == 0 ? widget.height : inner,
                                  ),
                                  right: Radius.circular(
                                    i == count - 1 ? widget.height : inner,
                                  ),
                                ),
                              );
                            }),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (widget.items[i].icon != null) ...[
                                Icon(
                                  widget.items[i].icon,
                                  size: medium ? 24 : 20,
                                  fill: widget.selected.contains(i) ? 1 : 0,
                                ),
                                const SizedBox(width: 8),
                              ],
                              Flexible(
                                child: Text(
                                  widget.items[i].label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class AltBlob extends StatelessWidget {
  const AltBlob({
    super.key,
    required this.icon,
    this.size = 64,
    this.iconSize = 32,
    this.background,
    this.foreground,
  });
  final IconData icon;
  final double size, iconSize;
  final Color? background, foreground;
  @override
  Widget build(BuildContext context) => ClipPath(
    clipper: const _BlobClipper(),
    child: ColoredBox(
      color: background ?? Theme.of(context).colorScheme.primaryContainer,
      child: SizedBox.square(
        dimension: size,
        child: Icon(
          icon,
          size: iconSize,
          color: foreground ?? Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    ),
  );
}

class _BlobClipper extends CustomClipper<Path> {
  const _BlobClipper();
  @override
  Path getClip(Size size) => Path()
    ..addRRect(
      RRect.fromRectAndCorners(
        Offset.zero & size,
        topLeft: Radius.elliptical(size.width * .44, size.height * .52),
        topRight: Radius.elliptical(size.width * .56, size.height * .44),
        bottomRight: Radius.elliptical(size.width * .52, size.height * .56),
        bottomLeft: Radius.elliptical(size.width * .48, size.height * .48),
      ),
    );
  @override
  bool shouldReclip(_BlobClipper oldClipper) => false;
}

class AltLoading extends StatefulWidget {
  const AltLoading({super.key, this.size = 40, this.shape = 0});
  final double size;
  final int shape;
  static const shapeCount = 7;
  @override
  State<AltLoading> createState() => _AltLoadingState();
}

class _AltLoadingState extends State<AltLoading>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3500),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      animation.stop();
    } else {
      animation.repeat();
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: Localizations.localeOf(context).languageCode == 'zh'
        ? '正在处理'
        : 'Processing',
    child: SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: animation,
        builder: (_, _) => CustomPaint(
          painter: _LoadingPainter(
            animation.value,
            Theme.of(context).colorScheme.primary,
            widget.shape,
          ),
        ),
      ),
    ),
  );
}

class _LoadingPainter extends CustomPainter {
  _LoadingPainter(this.progress, this.color, this.shapeIndex);
  final double progress;
  final Color color;
  final int shapeIndex;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(progress * math.pi * 2);
    canvas.scale(size.width * .8, size.height * .8);
    canvas.translate(-.5, -.5);
    canvas.drawPath(shape(shapeIndex), Paint()..color = color);
  }

  RRect inset(int index) {
    final amount = index == 3
        ? .08
        : index == 6
        ? .05
        : 0.0;
    final radii = switch (index) {
      3 => const [
        Radius.elliptical(.30, .30),
        Radius.elliptical(.70, .30),
        Radius.elliptical(.70, .70),
        Radius.elliptical(.30, .70),
      ],
      5 => const [
        Radius.elliptical(.50, .60),
        Radius.elliptical(.50, .60),
        Radius.elliptical(.50, .40),
        Radius.elliptical(.50, .40),
      ],
      6 => const [
        Radius.circular(.20),
        Radius.circular(.20),
        Radius.circular(.20),
        Radius.circular(.20),
      ],
      _ => const [
        Radius.circular(.50),
        Radius.circular(.50),
        Radius.circular(.50),
        Radius.circular(.50),
      ],
    };
    return RRect.fromRectAndCorners(
      Rect.fromLTRB(amount, amount, 1 - amount, 1 - amount),
      topLeft: radii[0],
      topRight: radii[1],
      bottomRight: radii[2],
      bottomLeft: radii[3],
    );
  }

  Path shape(int index) {
    final vertices = switch (index) {
      0 => const [
        Offset(.50, 0),
        Offset(.61, .35),
        Offset(.98, .35),
        Offset(.68, .57),
        Offset(.79, .91),
        Offset(.50, .70),
        Offset(.21, .91),
        Offset(.32, .57),
        Offset(.02, .35),
        Offset(.39, .35),
      ],
      2 => const [
        Offset(.50, 0),
        Offset(.80, .10),
        Offset(1, .35),
        Offset(1, .70),
        Offset(.80, .90),
        Offset(.50, 1),
        Offset(.20, .90),
        Offset(0, .70),
        Offset(0, .35),
        Offset(.20, .10),
      ],
      4 => const [
        Offset(.50, 0),
        Offset(1, .50),
        Offset(.50, 1),
        Offset(0, .50),
      ],
      _ => null,
    };
    return vertices == null
        ? (Path()..addRRect(inset(index)))
        : (Path()..addPolygon(vertices, true));
  }

  @override
  bool shouldRepaint(_LoadingPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      color != oldDelegate.color ||
      shapeIndex != oldDelegate.shapeIndex;
}

/// Custom track geometry with Slider's native input and accessibility.
class AltSliderTrack extends GappedSliderTrackShape {
  const AltSliderTrack();
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final active = Color.lerp(
      sliderTheme.disabledActiveTrackColor,
      sliderTheme.activeTrackColor,
      enableAnimation.value,
    )!;
    final inactive = Color.lerp(
      sliderTheme.disabledInactiveTrackColor,
      sliderTheme.inactiveTrackColor,
      enableAnimation.value,
    )!;
    final ltr = textDirection == TextDirection.ltr;
    const outer = Radius.circular(12), inner = Radius.circular(2);
    final left = Rect.fromLTRB(
      rect.left,
      rect.top,
      math.max(rect.left, thumbCenter.dx - 6),
      rect.bottom,
    );
    final right = Rect.fromLTRB(
      math.min(rect.right, thumbCenter.dx + 6),
      rect.top,
      rect.right,
      rect.bottom,
    );
    if (!left.isEmpty) {
      context.canvas.drawRRect(
        RRect.fromRectAndCorners(
          left,
          topLeft: outer,
          bottomLeft: outer,
          topRight: inner,
          bottomRight: inner,
        ),
        Paint()..color = ltr ? active : inactive,
      );
    }
    if (!right.isEmpty) {
      context.canvas.drawRRect(
        RRect.fromRectAndCorners(
          right,
          topLeft: inner,
          bottomLeft: inner,
          topRight: outer,
          bottomRight: outer,
        ),
        Paint()..color = ltr ? inactive : active,
      );
    }
    final stopX = ltr ? rect.right - 20 : rect.left + 20;
    if (ltr ? stopX > right.left + 2 : stopX < left.right - 2) {
      context.canvas.drawCircle(
        Offset(stopX, rect.center.dy),
        2,
        Paint()..color = sliderTheme.inactiveTickMarkColor!,
      );
    }
  }
}
