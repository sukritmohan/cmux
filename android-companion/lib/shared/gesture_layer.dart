/// Gesture recognizers for terminal screen navigation.
///
/// Wraps the terminal content area and recognizes:
///   - Left edge swipe → open workspace drawer
///   - Pinch out → minimap overlay
///   - Single-finger vertical pan → scroll terminal history
///   - Single-finger horizontal pan → tab switching (when [canSwipeTabs] is true)
///
/// Uses only scale gestures (superset of pan) to avoid the Flutter
/// "Incorrect GestureDetector arguments" error when both pan and scale
/// are registered on the same GestureDetector.
///
/// Direction-lock state machine (single-finger, non-edge-swipe):
///   Accumulates delta until magnitude exceeds [_directionLockThreshold], then
///   locks to either horizontal (tab swipe) or vertical (scroll) for the
///   remainder of the gesture. This prevents diagonal drift from triggering
///   both behaviors simultaneously.
library;

import 'package:flutter/material.dart';

/// Distinguishes the locked axis for a single-finger non-edge-swipe gesture.
enum _DirectionLock {
  /// No lock established yet — still accumulating delta.
  none,

  /// Gesture is primarily horizontal; routes to tab-swipe callbacks.
  horizontal,

  /// Gesture is primarily vertical; routes to scroll callback.
  vertical,
}

/// Callbacks for gesture events recognized by the [GestureLayer].
class GestureCallbacks {
  /// Called when the user swipes from the left edge to open the drawer.
  final VoidCallback onOpenDrawer;

  /// Called when the user pinches out to show the minimap.
  final VoidCallback onOpenMinimap;

  /// Called continuously during single-finger vertical pan with pixel delta.
  /// Positive delta = finger moved down (scroll up into history).
  final ValueChanged<double> onScroll;

  /// Called once when a single-finger horizontal swipe locks its direction,
  /// indicating a tab-switch gesture has begun. Only fired when
  /// [GestureLayer.canSwipeTabs] is true.
  final VoidCallback? onTabSwipeStart;

  /// Called continuously during a locked horizontal swipe with the cumulative
  /// horizontal pixel displacement from the gesture's start position.
  /// Positive = swiped right. Only fired when [GestureLayer.canSwipeTabs] is true.
  final ValueChanged<double>? onTabSwipeUpdate;

  /// Called when a locked horizontal swipe gesture ends.
  /// [displacement] is the total horizontal pixel offset (positive = right).
  /// [velocity] is the horizontal pixels-per-second at release
  /// (positive = moving right). Only fired when [GestureLayer.canSwipeTabs] is true.
  final void Function(double displacement, double velocity)? onTabSwipeEnd;

  const GestureCallbacks({
    required this.onOpenDrawer,
    required this.onOpenMinimap,
    required this.onScroll,
    this.onTabSwipeStart,
    this.onTabSwipeUpdate,
    this.onTabSwipeEnd,
  });
}

class GestureLayer extends StatefulWidget {
  final Widget child;
  final GestureCallbacks callbacks;

  /// When true, single-finger horizontal swipes (outside the edge zone) are
  /// routed through the direction-lock state machine and fire the
  /// [GestureCallbacks.onTabSwipeStart] / [onTabSwipeUpdate] / [onTabSwipeEnd]
  /// callbacks. When false, all behavior is identical to a build without
  /// direction-lock — horizontal motion simply does nothing.
  final bool canSwipeTabs;

  const GestureLayer({
    super.key,
    required this.child,
    required this.callbacks,
    this.canSwipeTabs = false,
  });

  @override
  State<GestureLayer> createState() => _GestureLayerState();
}

class _GestureLayerState extends State<GestureLayer> {
  // Edge swipe detection
  static const _edgeThreshold = 20.0; // px from left edge to trigger
  static const _swipeVelocity = 200.0; // min velocity to trigger

  bool _isEdgeSwipe = false;
  Offset? _panStart;

  // Pinch detection
  bool _pinchTriggered = false;
  static const _pinchThresholdScale = 0.7; // Scale below this triggers minimap

  // Track pointer count to distinguish single-finger pan from two-finger pinch
  int _pointerCount = 0;

  // Direction-lock state machine for single-finger non-edge gestures.
  // Once the cumulative delta exceeds [_directionLockThreshold], the gesture
  // is locked to whichever axis had greater displacement and stays locked for
  // the entire gesture lifetime.
  static const _directionLockThreshold = 10.0; // px before axis is chosen
  _DirectionLock _directionLock = _DirectionLock.none;
  Offset _cumulativeDelta = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Scale gestures handle both single-finger pan (edge swipe, scroll,
      // tab swipe) and two-finger pinch (minimap). Scale is a superset of pan
      // in Flutter.
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd: _onScaleEnd,

      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
  }

  // ---------------------------------------------------------------------------
  // Unified scale handler (single-finger = pan, two-finger = pinch)
  // ---------------------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails details) {
    _pointerCount = details.pointerCount;
    _pinchTriggered = false;

    if (_pointerCount == 1) {
      // Single finger — treat as pan start.
      _panStart = details.localFocalPoint;
      _isEdgeSwipe = details.localFocalPoint.dx < _edgeThreshold;

      // Reset direction-lock state for this gesture when tab-swipe routing is
      // active and this is not an edge swipe (edge swipes have their own path).
      if (widget.canSwipeTabs && !_isEdgeSwipe) {
        _directionLock = _DirectionLock.none;
        _cumulativeDelta = Offset.zero;
      }
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_pointerCount >= 2) {
      // Two-finger pinch — check for minimap trigger.
      if (_pinchTriggered) return;
      if (details.scale < _pinchThresholdScale) {
        _pinchTriggered = true;
        widget.callbacks.onOpenMinimap();
      }
      return;
    }

    // Single finger — edge swipes bypass the direction-lock state machine
    // entirely. Because _isEdgeSwipe is evaluated before canSwipeTabs, an
    // edge touch is always routed to the drawer path regardless of tab count.
    // The tab-swipe callbacks are never invoked for edge gestures.
    if (_isEdgeSwipe) return;

    // When tab-swipe routing is active, apply the direction-lock state machine.
    if (widget.canSwipeTabs) {
      _handleDirectionLockedUpdate(details);
      return;
    }

    // Default: continuous vertical scroll (original behavior when canSwipeTabs
    // is false).
    widget.callbacks.onScroll(details.focalPointDelta.dy);
  }

  /// Applies the direction-lock state machine for single-finger non-edge
  /// gestures when [canSwipeTabs] is true.
  ///
  /// State transitions:
  ///   [_DirectionLock.none] → accumulate delta; once magnitude > threshold,
  ///     compare |dx| vs |dy| and transition to [horizontal] or [vertical].
  ///   [_DirectionLock.horizontal] → route to tab-swipe update callback.
  ///   [_DirectionLock.vertical] → route to scroll callback.
  void _handleDirectionLockedUpdate(ScaleUpdateDetails details) {
    switch (_directionLock) {
      case _DirectionLock.none:
        _cumulativeDelta += details.focalPointDelta;
        if (_cumulativeDelta.distance > _directionLockThreshold) {
          // Axis with greater absolute displacement wins.
          if (_cumulativeDelta.dx.abs() >= _cumulativeDelta.dy.abs()) {
            _directionLock = _DirectionLock.horizontal;
            widget.callbacks.onTabSwipeStart?.call();
            // Immediately deliver the first update with the accumulated
            // displacement so the caller is not behind by one frame.
            widget.callbacks.onTabSwipeUpdate?.call(_cumulativeDelta.dx);
          } else {
            _directionLock = _DirectionLock.vertical;
            // Deliver the accumulated vertical displacement to catch up.
            widget.callbacks.onScroll(_cumulativeDelta.dy);
          }
        }

      case _DirectionLock.horizontal:
        _cumulativeDelta += details.focalPointDelta;
        widget.callbacks.onTabSwipeUpdate?.call(_cumulativeDelta.dx);

      case _DirectionLock.vertical:
        // Do not accumulate into _cumulativeDelta for vertical — only the
        // per-frame delta is meaningful for smooth scrolling.
        widget.callbacks.onScroll(details.focalPointDelta.dy);
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_pointerCount >= 2) {
      // Pinch ended.
      _pinchTriggered = false;
      _pointerCount = 0;
      return;
    }

    // Single finger — handle as pan end.
    if (_panStart == null) {
      _pointerCount = 0;
      return;
    }

    final velocity = details.velocity.pixelsPerSecond;

    // Edge swipe → open drawer
    if (_isEdgeSwipe) {
      if (velocity.dx > _swipeVelocity) {
        widget.callbacks.onOpenDrawer();
      }
      _isEdgeSwipe = false;
      _panStart = null;
      _pointerCount = 0;
      return;
    }

    // Horizontal tab-swipe ended — deliver final displacement and velocity.
    if (widget.canSwipeTabs && _directionLock == _DirectionLock.horizontal) {
      widget.callbacks.onTabSwipeEnd?.call(
        _cumulativeDelta.dx,
        velocity.dx,
      );
      _directionLock = _DirectionLock.none;
      _cumulativeDelta = Offset.zero;
      _panStart = null;
      _pointerCount = 0;
      return;
    }

    // Reset direction-lock state for any non-horizontal gesture ending.
    _directionLock = _DirectionLock.none;
    _cumulativeDelta = Offset.zero;

    _panStart = null;
    _pointerCount = 0;
  }
}
