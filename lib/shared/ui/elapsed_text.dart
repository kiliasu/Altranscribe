import 'dart:async';

import 'package:flutter/widgets.dart';

import 'motion.dart';

/// Text that says how much time has passed, refreshed every second by
/// itself, so a clock costs one small widget rather than the screen.
class ElapsedText extends StatefulWidget {
  /// The time since [since].
  const ElapsedText({
    super.key,
    required DateTime this.since,
    required this.label,
    this.style,
    this.rolling = false,
  }) : read = null;

  /// The time [read] reports, such as a session's listening time that
  /// holds while it is paused.
  const ElapsedText.reading(
    Duration Function() this.read, {
    super.key,
    required this.label,
    this.style,
    this.rolling = false,
  }) : since = null;
  final DateTime? since;
  final Duration Function()? read;
  final String Function(Duration elapsed) label;
  final TextStyle? style;

  /// Changed digits roll instead of the text being replaced.
  final bool rolling;
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
  Widget build(BuildContext context) {
    final value = widget.label(
      widget.read?.call() ?? DateTime.now().difference(widget.since!),
    );
    return widget.rolling
        ? RollingText(value, style: widget.style)
        : Text(value, style: widget.style);
  }
}

/// A length the way a recorder shows it: 0:42, 3:05, 1:02:10.
String durationLabel(Duration duration) {
  final seconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  String two(int value) => value.toString().padLeft(2, '0');
  final hours = seconds ~/ 3600;
  final minutes = seconds ~/ 60 % 60;
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds % 60)}'
      : '$minutes:${two(seconds % 60)}';
}
