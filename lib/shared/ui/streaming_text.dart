import 'package:material_ui/material_ui.dart';

import 'motion.dart';

/// Selectable text that shows each new result in full at once. When it
/// changes while [active], the part after what it had in common with the
/// previous text fades in, so a line growing word by word reads steadily
/// and nothing waits on a typing effect. The settled part never moves.
class StreamingText extends StatefulWidget {
  const StreamingText(
    this.text, {
    super.key,
    required this.style,
    this.active = true,
  });
  final String text;
  final TextStyle style;
  final bool active;

  /// How long the new part takes to settle.
  static const duration = Duration(milliseconds: 180);

  /// Where [next] stops sharing [previous]'s beginning, never inside a
  /// surrogate pair.
  static int commonPrefix(String previous, String next) {
    final limit = previous.length < next.length ? previous.length : next.length;
    var i = 0;
    while (i < limit && previous.codeUnitAt(i) == next.codeUnitAt(i)) {
      i++;
    }
    if (i > 0 && i < next.length) {
      final unit = next.codeUnitAt(i - 1);
      if (unit >= 0xD800 && unit <= 0xDBFF) i--;
    }
    return i;
  }

  @override
  State<StreamingText> createState() => _StreamingTextState();
}

class _StreamingTextState extends State<StreamingText>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: StreamingText.duration,
    value: 1,
  );
  int settled = 0;

  @override
  void didUpdateWidget(StreamingText old) {
    super.didUpdateWidget(old);
    if (old.text == widget.text) return;
    if (!widget.active || AltMotion.reduced(context)) {
      controller.value = 1;
      return;
    }
    settled = StreamingText.commonPrefix(old.text, widget.text);
    if (settled < widget.text.length) controller.forward(from: 0);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final text = widget.text;
      if (controller.value >= 1 || settled >= text.length) {
        return SelectableText(text, style: widget.style);
      }
      final color =
          widget.style.color ?? DefaultTextStyle.of(context).style.color!;
      final amount = Curves.easeOut.transform(controller.value);
      return SelectableText.rich(
        TextSpan(
          style: widget.style,
          children: [
            TextSpan(text: text.substring(0, settled)),
            TextSpan(
              text: text.substring(settled),
              style: TextStyle(
                color: color.withValues(alpha: color.a * (.45 + .55 * amount)),
              ),
            ),
          ],
        ),
      );
    },
  );
}
