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

class _StreamingTextState extends State<StreamingText> {
  /// A live line changes about once a second. Its fade takes a handful of
  /// steps on the shared slow clock rather than a ticker's frame at the
  /// display's rate: an opacity looks the same either way, and a long
  /// session draws a fraction of the frames.
  late final _pace = AltPace()..addListener(_step);
  Duration _from = Duration.zero;
  double _amount = 1;
  int _settled = 0;

  @override
  void didUpdateWidget(StreamingText old) {
    super.didUpdateWidget(old);
    if (old.text == widget.text) return;
    if (!widget.active || AltMotion.reduced(context)) {
      _settle();
      return;
    }
    _settled = StreamingText.commonPrefix(old.text, widget.text);
    if (_settled >= widget.text.length) {
      _settle();
      return;
    }
    _amount = 0;
    _from = _pace.elapsed;
    _pace.run(true);
  }

  void _step() {
    final amount =
        (_pace.elapsed - _from).inMicroseconds /
        StreamingText.duration.inMicroseconds;
    if (amount >= 1) {
      setState(_settle);
    } else {
      setState(() => _amount = amount);
    }
  }

  void _settle() {
    _pace.run(false);
    _amount = 1;
  }

  @override
  void dispose() {
    _pace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    if (_amount >= 1 || _settled >= text.length) {
      return SelectableText(text, style: widget.style);
    }
    final color =
        widget.style.color ?? DefaultTextStyle.of(context).style.color!;
    final amount = Curves.easeOut.transform(_amount);
    return SelectableText.rich(
      TextSpan(
        style: widget.style,
        children: [
          TextSpan(text: text.substring(0, _settled)),
          TextSpan(
            text: text.substring(_settled),
            style: TextStyle(
              color: color.withValues(alpha: color.a * (.45 + .55 * amount)),
            ),
          ),
        ],
      ),
    );
  }
}
