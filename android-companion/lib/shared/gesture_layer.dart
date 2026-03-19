/// Gesture recognizers for terminal screen navigation.
///
/// Wraps the terminal content area and recognizes:
///   - Left edge swipe → open workspace drawer
///   - Pinch out → minimap overlay
///   - Single-finger vertical pan → scroll terminal history
///
/// Uses only scale gestures (superset of pan) to avoid the Flutter
/// "Incorrect GestureDetector arguments" error when both pan and scale
/// are registered on the same GestureDetector.
library;

import 'package:flutter/material.dart';

/// Callbacks for gesture events recognized by the [GestureLayer].
class GestureCallbacks {
  /// Called when the user swipes from the left edge to open the drawer.
  final VoidCallback onOpenDrawer;

  /// Called when the user pinches out to show the minimap.
  final VoidCallback onOpenMinimap;

  /// Called continuously during single-finger vertical pan with pixel delta.
  /// Positive delta = finger moved down (scroll up into history).
  final ValueChanged<double> onScroll;

  const GestureCallbacks({
    required this.onOpenDrawer,
    required this.onOpenMinimap,
    required this.onScroll,
  });
}

class GestureLayer extends StatefulWidget {
  final Widget child;
  final GestureCallbacks callbacks;

  const GestureLayer({
    super.key,
    required this.child,
    required this.callbacks,
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Scale gestures handle both single-finger pan (edge swipe, scroll)
      // and two-finger pinch (minimap). Scale is a superset of pan in Flutter.
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

    // Single finger — continuous scroll (unless edge swipe).
    if (!_isEdgeSwipe) {
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

    _panStart = null;
    _pointerCount = 0;
  }
}
