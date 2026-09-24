import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/features/transcription/realtime_controller.dart';

const _curveStrokeWidth = 4.0;
const _levelInterval = Duration(milliseconds: 200);
const _waveLength = 48.0;

/// A scrolling envelope of measured RMS levels, not a synthesized PCM waveform.
class AudioLevelHistory extends StatefulWidget {
  const AudioLevelHistory({
    super.key,
    required this.samples,
    required this.running,
    required this.label,
    required this.color,
  });

  final List<double> samples;
  final bool running;
  final String label;
  final Color color;

  @override
  State<AudioLevelHistory> createState() => _AudioLevelHistoryState();
}

class _AudioLevelHistoryState extends State<AudioLevelHistory>
    with SingleTickerProviderStateMixin {
  late final _scroll = AnimationController(
    vsync: this,
    duration: _levelInterval,
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _scroll.value = 1;
  }

  @override
  void didUpdateWidget(AudioLevelHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.running) {
      _scroll.stop();
    } else if (!identical(widget.samples, oldWidget.samples)) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.value = 1;
      } else {
        _scroll.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    child: RepaintBoundary(
      child: SizedBox(
        height: 44,
        width: double.infinity,
        child: CustomPaint(
          painter: _LevelPainter(
            samples: widget.samples,
            scroll: _scroll,
            color: widget.color,
            track: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
    ),
  );
}

class _LevelPainter extends CustomPainter {
  _LevelPainter({
    required this.samples,
    required this.scroll,
    required this.color,
    required this.track,
  }) : super(repaint: scroll);

  final List<double> samples;
  final Animation<double> scroll;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = size.height - 4;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      Paint()..color = track.withValues(alpha: .6),
    );
    if (samples.isNotEmpty) {
      final step = size.width / (RealtimeController.levelHistorySamples - 1);
      Offset point(int i) => Offset(
        size.width -
            (samples.length - 1 - i) * step +
            (1 - scroll.value) * step,
        // Perceptual scaling makes quiet speech visible while keeping silence flat.
        baseline - math.sqrt(samples[i].clamp(0, 1)) * (size.height - 8),
      );
      final first = point(0);
      final path = Path()..moveTo(first.dx, first.dy);
      for (var i = 1; i < samples.length; i++) {
        final previous = point(i - 1);
        final next = point(i);
        final middleX = (previous.dx + next.dx) / 2;
        path.cubicTo(middleX, previous.dy, middleX, next.dy, next.dx, next.dy);
      }
      final last = point(samples.length - 1);
      final fill = Path.from(path)
        ..lineTo(last.dx, baseline)
        ..lineTo(first.dx, baseline)
        ..close();
      canvas.drawPath(fill, Paint()..color = color.withValues(alpha: .12));
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = _curveStrokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LevelPainter old) =>
      !identical(samples, old.samples) ||
      color != old.color ||
      track != old.track;
}

/// Playback-style decoration. The measured volume is shown in the histories above.
class RecordingWave extends StatefulWidget {
  const RecordingWave({
    super.key,
    required this.running,
    required this.historyWidth,
  });
  final bool running;
  final double historyWidth;

  @override
  State<RecordingWave> createState() => _RecordingWaveState();
}

class _RecordingWaveState extends State<RecordingWave>
    with SingleTickerProviderStateMixin {
  late final _phase = AnimationController(vsync: this);

  void _updateAnimation() {
    // Match the history's pixels per second, including when the window resizes.
    final period = Duration(
      microseconds:
          (_levelInterval.inMicroseconds *
                  (RealtimeController.levelHistorySamples - 1) *
                  _waveLength /
                  widget.historyWidth)
              .round(),
    );
    final speedChanged = _phase.duration != period;
    _phase.duration = period;
    if (widget.running && !MediaQuery.disableAnimationsOf(context)) {
      if (!_phase.isAnimating || speedChanged) _phase.repeat();
    } else {
      _phase.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAnimation();
  }

  @override
  void didUpdateWidget(RecordingWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnimation();
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: SizedBox(
        height: 20,
        width: double.infinity,
        child: CustomPaint(
          painter: _RecordingWavePainter(
            _phase,
            Theme.of(context).colorScheme.primary.withValues(alpha: .65),
          ),
        ),
      ),
    ),
  );
}

class _RecordingWavePainter extends CustomPainter {
  _RecordingWavePainter(this.phase, this.color) : super(repaint: phase);
  final Animation<double> phase;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    for (var x = 0.0; x <= size.width; x += 1) {
      final taper = (math.min(x, size.width - x) / 24).clamp(0.0, 1.0);
      final y =
          size.height / 2 +
          math.sin((x / _waveLength + phase.value) * math.pi * 2) * 5 * taper;
      if (x == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _curveStrokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RecordingWavePainter old) => color != old.color;
}
