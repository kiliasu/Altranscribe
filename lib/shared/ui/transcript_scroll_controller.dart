import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:altranscribe/data/models/transcript_record.dart';

/// Corrects the reading position during layout, before a resized transcript is
/// painted. Post-frame jumps leave a frame at the old offset and visibly shake.
class TranscriptScrollController extends ScrollController {
  TranscriptScrollController({required this.following});
  final bool Function() following;
  final _keys = <Object, GlobalKey>{};
  GlobalKey? _anchor;
  double _anchorDistance = 0;
  GlobalKey keyFor(Object line) => _keys.putIfAbsent(line, GlobalKey.new);

  /// One key per row. A row keeps its key when the next hypothesis for the
  /// same audio replaces its line; rows that share a source and start time,
  /// such as an untimed cloud segment, are told apart by their order.
  List<GlobalKey> keysFor(String record, List<TranscriptLine> lines) {
    final seen = <(String, int), int>{};
    return [
      for (final line in lines)
        keyFor((
          record,
          line.source,
          line.startMs,
          seen.update(
            (line.source, line.startMs),
            (count) => count + 1,
            ifAbsent: () => 0,
          ),
        )),
    ];
  }

  double? _top(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport is! RenderObject || !hasClients) return null;
    // Transform the origin only: getOffsetToReveal reads descendant sizes,
    // which are not available to the viewport during its own layout pass.
    return MatrixUtils.transformPoint(
          box.getTransformTo(viewport),
          Offset.zero,
        ).dy +
        offset;
  }

  void captureAnchor() {
    _anchor = null;
    if (following() || !hasClients) return;
    for (final key in _keys.values) {
      final top = _top(key);
      final box = key.currentContext?.findRenderObject();
      if (top != null &&
          box is RenderBox &&
          top + box.size.height > offset &&
          top < offset + position.viewportDimension) {
        _anchor = key;
        _anchorDistance = top - offset;
        break;
      }
    }
  }

  void releaseAnchor() => _anchor = null;
  void resetAnchors() {
    releaseAnchor();
    _keys.clear();
  }

  double? get anchoredOffset {
    final top = _anchor == null ? null : _top(_anchor!);
    return top == null ? null : top - _anchorDistance;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _TranscriptPosition(
    controller: this,
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
  );
}

class _TranscriptPosition extends ScrollPositionWithSingleContext {
  _TranscriptPosition({
    required this.controller,
    required super.physics,
    required super.context,
    super.oldPosition,
    super.initialPixels,
    super.keepScrollOffset,
  });
  final TranscriptScrollController controller;

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    final desired = controller.following()
        ? newPosition.maxScrollExtent
        : controller.anchoredOffset;
    if (desired != null) {
      final target = desired.clamp(
        newPosition.minScrollExtent,
        newPosition.maxScrollExtent,
      );
      if ((target - pixels).abs() > .1) {
        correctPixels(target);
        return false;
      }
      return true;
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }
}
