import 'dart:async';

import 'package:flutter/widgets.dart';

/// Text that says how long ago [since] was, refreshed every second by
/// itself, so the clock costs one small widget rather than the screen.
class ElapsedText extends StatefulWidget {
  const ElapsedText({
    super.key,
    required this.since,
    required this.label,
    this.style,
  });
  final DateTime since;
  final String Function(Duration elapsed) label;
  final TextStyle? style;
  @override
  State<ElapsedText> createState() => _ElapsedTextState();
}

class _ElapsedTextState extends State<ElapsedText> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    widget.label(DateTime.now().difference(widget.since)),
    style: widget.style,
  );
}
