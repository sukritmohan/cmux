/// Gesture recognizers for terminal screen navigation.
///
/// Wraps the terminal content area and recognizes:
///   - Left edge swipe → open workspace drawer
///   - Pinch out → minimap overlay
///   - Directional swipe on terminal → arrow key input
library;

import 'package:flutter/material.dart';

/// Callbacks for gesture events recognized by the [GestureLayer].
class GestureCallbacks {
  /// Called when the user swipes from the left edge to open the drawer.
  final VoidCallback onOpenDrawer;

  /// Called when the user pinches out to show the minimap.
  final VoidCallback onOpenMinimap;

  /// Called when the user swipes on the terminal to send arrow key input.
  /// The direction is one of: 'left', 'right', 'up', 'down'.
  final ValueChanged<String> onArrowSwipe;

  const GestureCallbacks({
    required this.onOpenDrawer,
    required this.onOpenMinimap,
    required this.onArrowSwipe,
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Pan gestures for edge swipe and arrow swipe
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,

      // Scale gestures for pinch-to-minimap
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd: _onScaleEnd,

      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
  }

  // ---------------------------------------------------------------------------
  // Pan (edge swipe + arrow keys)
  // ---------------------------------------------------------------------------

  void _onPanStart(DragStartDetails details) {
    _panStart = details.localPosition;

    // Check if this is a left-edge swipe.
    _isEdgeSwipe = details.localPosition.dx < _edgeThreshold;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    // Edge swipe is handled on end (velocity check).
  }

  void _onPanEnd(DragEndDetails details) {
    if (_panStart == null) return;

    final velocity = details.velocity.pixelsPerSecond;

    // Edge swipe → open drawer
    if (_isEdgeSwipe) {
      if (velocity.dx > _swipeVelocity) {
        widget.callbacks.onOpenDrawer();
      }
      _isEdgeSwipe = false;
      _panStart = null;
      return;
    }

    // Arrow swipe detection
    final dx = details.velocity.pixelsPerSecond.dx;
    final dy = details.velocity.pixelsPerSecond.dy;

    if (dx.abs() > _swipeVelocity || dy.abs() > _swipeVelocity) {
      if (dx.abs() > dy.abs()) {
        // Horizontal
        widget.callbacks.onArrowSwipe(dx > 0 ? 'right' : 'left');
      } else {
        // Vertical
        widget.callbacks.onArrowSwipe(dy > 0 ? 'down' : 'up');
      }
    }

    _panStart = null;
  }

  // ---------------------------------------------------------------------------
  // Scale (pinch-to-minimap)
  // ---------------------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails details) {
    _pinchTriggered = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_pinchTriggered) return;

    // Pinch-out: scale decreases below threshold.
    if (details.scale < _pinchThresholdScale) {
      _pinchTriggered = true;
      widget.callbacks.onOpenMinimap();
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _pinchTriggered = false;
  }
}
