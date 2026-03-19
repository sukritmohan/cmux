/// Echo SSH-inspired joystick button for arrow key input.
///
/// Two interaction modes:
/// - Quick swipe: flick in a cardinal direction to fire one arrow key
/// - Hold + drag: press >200ms, then drag to repeat arrows with acceleration
///
/// Renders a circular button with a custom crosshair icon (✥).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';

/// Cardinal direction resolved from a gesture vector.
enum CardinalDirection { up, down, left, right }

/// Resolves an offset to a cardinal direction using 90° sectors.
/// Returns null if the offset magnitude is below [threshold].
CardinalDirection? resolveDirection(Offset delta, double threshold) {
  if (delta.distance < threshold) return null;
  // Use atan2; sectors are 90° each centered on the axis
  final angle = math.atan2(delta.dy, delta.dx);
  if (angle >= -math.pi / 4 && angle < math.pi / 4) {
    return CardinalDirection.right;
  } else if (angle >= math.pi / 4 && angle < 3 * math.pi / 4) {
    return CardinalDirection.down;
  } else if (angle >= -3 * math.pi / 4 && angle < -math.pi / 4) {
    return CardinalDirection.up;
  } else {
    return CardinalDirection.left;
  }
}

/// Maps a cardinal direction to xterm escape sequence.
String arrowSequence(CardinalDirection dir, {bool ctrl = false}) {
  final suffix = switch (dir) {
    CardinalDirection.up => 'A',
    CardinalDirection.down => 'B',
    CardinalDirection.right => 'C',
    CardinalDirection.left => 'D',
  };
  return ctrl ? '\x1b[1;5$suffix' : '\x1b[$suffix';
}

class JoystickButton extends StatefulWidget {
  /// Called with the arrow escape sequence to send.
  final ValueChanged<String> onInput;

  /// Whether ctrl modifier is currently active (sticky).
  final bool ctrlActive;

  const JoystickButton({
    super.key,
    required this.onInput,
    this.ctrlActive = false,
  });

  @override
  State<JoystickButton> createState() => _JoystickButtonState();
}

class _JoystickButtonState extends State<JoystickButton> {
  // Gesture state machine
  bool _isDown = false;
  bool _isDragReady = false;
  Offset _startPosition = Offset.zero;
  CardinalDirection? _activeDirection;
  Timer? _holdTimer;
  Timer? _repeatTimer;
  int _repeatCount = 0;

  static const _holdDelay = Duration(milliseconds: 200);
  static const _swipeThreshold = 8.0;
  static const _dragThreshold = 12.0;
  static const _holdMoveTolerance = 4.0;
  static const _initialRepeatInterval = Duration(milliseconds: 200);
  static const _minRepeatInterval = Duration(milliseconds: 40);

  void _fireArrow(CardinalDirection dir) {
    HapticFeedback.selectionClick();
    widget.onInput(arrowSequence(dir, ctrl: widget.ctrlActive));
  }

  void _onPanStart(DragStartDetails details) {
    _isDown = true;
    _isDragReady = false;
    _startPosition = details.localPosition;
    _activeDirection = null;
    _repeatCount = 0;

    // Start hold timer — if finger stays still for 200ms, enter drag-ready
    _holdTimer = Timer(_holdDelay, () {
      if (!_isDown) return;
      setState(() => _isDragReady = true);
      HapticFeedback.mediumImpact();
    });

    setState(() {});
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_isDown) return;
    final delta = details.localPosition - _startPosition;

    // If we haven't entered drag-ready yet, check for quick swipe
    if (!_isDragReady) {
      if (delta.distance > _holdMoveTolerance) {
        // Movement detected before hold timer — this is a quick swipe
        _holdTimer?.cancel();
        final dir = resolveDirection(delta, _swipeThreshold);
        if (dir != null && _activeDirection == null) {
          _activeDirection = dir;
          HapticFeedback.lightImpact();
          widget.onInput(arrowSequence(dir, ctrl: widget.ctrlActive));
        }
      }
      return;
    }

    // In drag-ready mode — check for directional drag
    final dir = resolveDirection(delta, _dragThreshold);
    if (dir != _activeDirection) {
      // Direction changed (or first direction established)
      _repeatTimer?.cancel();
      if (dir != null) {
        if (_activeDirection != null) {
          // Crossing through center to new direction
          HapticFeedback.selectionClick();
        }
        _activeDirection = dir;
        _repeatCount = 0;
        _fireArrow(dir);
        _startRepeatTimer(dir);
      } else {
        // Returned to center dead zone
        _activeDirection = null;
      }
      setState(() {});
    }
  }

  void _onPanEnd(DragEndDetails details) {
    _cleanup();
    // If it was a quick swipe that hasn't fired yet (very fast flick)
    // the swipe was already handled in _onPanUpdate
  }

  void _startRepeatTimer(CardinalDirection dir) {
    _repeatTimer?.cancel();
    final interval = Duration(
      milliseconds: math.max(
        _minRepeatInterval.inMilliseconds,
        _initialRepeatInterval.inMilliseconds -
            (_repeatCount * 16), // accelerate ~16ms per tick
      ),
    );
    _repeatTimer = Timer(interval, () {
      if (!_isDown || _activeDirection != dir) return;
      _repeatCount++;
      _fireArrow(dir);
      _startRepeatTimer(dir); // schedule next with shorter interval
    });
  }

  void _cleanup() {
    _holdTimer?.cancel();
    _repeatTimer?.cancel();
    _holdTimer = null;
    _repeatTimer = null;
    setState(() {
      _isDown = false;
      _isDragReady = false;
      _activeDirection = null;
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _repeatTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isPressed = _isDragReady || (_isDown && _activeDirection != null);

    return GestureDetector(
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: AnimatedScale(
        scale: isPressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutExpo,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isPressed ? c.joystickPressed : c.joystickFill,
            border: Border.all(
              color: isPressed ? c.joystickPressedBorder : c.joystickBorder,
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: isPressed
                    ? c.joystickPressedBorder.withAlpha(40)
                    : Colors.black.withAlpha(50),
                blurRadius: isPressed ? 16 : 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: CustomPaint(
            painter: CrosshairPainter(
              color: isPressed ? c.accentText : c.keyGroupText,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the ✥ crosshair icon: four arrow-tipped arms from a center dot.
class CrosshairPainter extends CustomPainter {
  final Color color;

  CrosshairPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    const armLength = 7.0;
    const tipSize = 3.0;

    // Horizontal arm
    canvas.drawLine(
      Offset(center.dx - armLength, center.dy),
      Offset(center.dx + armLength, center.dy),
      paint,
    );
    // Vertical arm
    canvas.drawLine(
      Offset(center.dx, center.dy - armLength),
      Offset(center.dx, center.dy + armLength),
      paint,
    );

    // Arrow tips
    final tipPaint = Paint()..color = color;
    // Up tip
    final upPath = Path()
      ..moveTo(center.dx, center.dy - armLength - 1)
      ..lineTo(center.dx - tipSize, center.dy - armLength + tipSize)
      ..lineTo(center.dx + tipSize, center.dy - armLength + tipSize)
      ..close();
    canvas.drawPath(upPath, tipPaint);
    // Down tip
    final downPath = Path()
      ..moveTo(center.dx, center.dy + armLength + 1)
      ..lineTo(center.dx - tipSize, center.dy + armLength - tipSize)
      ..lineTo(center.dx + tipSize, center.dy + armLength - tipSize)
      ..close();
    canvas.drawPath(downPath, tipPaint);
    // Left tip
    final leftPath = Path()
      ..moveTo(center.dx - armLength - 1, center.dy)
      ..lineTo(center.dx - armLength + tipSize, center.dy - tipSize)
      ..lineTo(center.dx - armLength + tipSize, center.dy + tipSize)
      ..close();
    canvas.drawPath(leftPath, tipPaint);
    // Right tip
    final rightPath = Path()
      ..moveTo(center.dx + armLength + 1, center.dy)
      ..lineTo(center.dx + armLength - tipSize, center.dy - tipSize)
      ..lineTo(center.dx + armLength - tipSize, center.dy + tipSize)
      ..close();
    canvas.drawPath(rightPath, tipPaint);

    // Center dot
    canvas.drawCircle(center, 1.5, Paint()..color = color.withAlpha(150));
  }

  @override
  bool shouldRepaint(CrosshairPainter oldDelegate) => color != oldDelegate.color;
}
