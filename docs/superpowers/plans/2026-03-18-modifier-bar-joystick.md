# Modifier Bar & Joystick Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the tiny inverted-T arrow cluster with an Echo SSH-inspired joystick button, add esc+ctrl capsule, fan-out symbol popover, and amber Return key.

**Architecture:** Rewrite `modifier_bar.dart` with four new widget components (key capsule, fan button, joystick, return key). Add new color tokens to `colors.dart`. The joystick uses `GestureDetector` with `onPanStart/Update/End` for swipe detection and a `Timer` for hold+drag repeat. Fan-out uses an `OverlayEntry` popover.

**Tech Stack:** Flutter/Dart, `GestureDetector`, `CustomPainter` (crosshair icon, fan icon), `Timer`, `HapticFeedback`, `OverlayEntry`

**Spec:** `docs/superpowers/specs/2026-03-18-modifier-bar-joystick-redesign.md`
**Visual reference:** `docs/mobile-ux/modifier-bar-joystick-design.html`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `android-companion/lib/app/colors.dart` | Modify | Add 13 new color tokens for the redesigned bar |
| `android-companion/lib/terminal/modifier_bar.dart` | Rewrite | New bar layout: esc+ctrl capsule, fan button, joystick, return |
| `android-companion/lib/terminal/joystick_button.dart` | Create | Joystick widget with swipe/hold+drag gesture handling and crosshair painter |
| `android-companion/lib/terminal/fan_out_button.dart` | Create | Fan-out button with popover overlay for symbol keys |

---

### Task 1: Add Color Tokens

**Files:**
- Modify: `android-companion/lib/app/colors.dart`

- [ ] **Step 1: Add token fields to AppColorScheme**

Add these fields after `modifierBarBg` (line 51):

```dart
// -- Modifier bar components --
final Color keyGroupResting;
final Color keyGroupText;
final Color keyGroupActive;
final Color fanBtnResting;
final Color fanBtnActive;
final Color fanPopoverBg;
final Color symKeyResting;
final Color joystickFill;
final Color joystickBorder;
final Color joystickPressed;
final Color joystickPressedBorder;
final Color returnGradientStart;
final Color returnGradientEnd;
final Color returnGlow;
```

Add the corresponding `required this.xxx` entries in the constructor (after line 82).

- [ ] **Step 2: Add dark theme values**

Add to `AppColors.dark` (after `modifierBarBg` at line 116):

```dart
keyGroupResting: Color(0x0FFFFFFF),     // rgba(255,255,255,0.06)
keyGroupText: Color(0x73FFFFFF),        // rgba(255,255,255,0.45)
keyGroupActive: Color(0x26E0A030),      // rgba(224,160,48,0.15)
fanBtnResting: Color(0x0FFFFFFF),       // rgba(255,255,255,0.06)
fanBtnActive: Color(0x1FE0A030),        // rgba(224,160,48,0.12)
fanPopoverBg: Color(0xF214141E),        // rgba(20,20,30,0.95)
symKeyResting: Color(0x0FFFFFFF),       // rgba(255,255,255,0.06)
joystickFill: Color(0x0FFFFFFF),        // rgba(255,255,255,0.06)
joystickBorder: Color(0x14FFFFFF),      // rgba(255,255,255,0.08)
joystickPressed: Color(0x1FE0A030),     // rgba(224,160,48,0.12)
joystickPressedBorder: Color(0x40E0A030), // rgba(224,160,48,0.25)
returnGradientStart: Color(0x47E0A030), // rgba(224,160,48,0.28)
returnGradientEnd: Color(0x1FE0A030),   // rgba(224,160,48,0.12)
returnGlow: Color(0x14E0A030),          // rgba(224,160,48,0.08)
```

- [ ] **Step 3: Add light theme values**

Add to `AppColors.light` (after `modifierBarBg` at line 147):

```dart
keyGroupResting: Color(0x0A000000),     // rgba(0,0,0,0.04)
keyGroupText: Color(0x61000000),        // rgba(0,0,0,0.38)
keyGroupActive: Color(0x1FE0A030),      // rgba(224,160,48,0.12)
fanBtnResting: Color(0x0A000000),       // rgba(0,0,0,0.04)
fanBtnActive: Color(0x1AE0A030),        // rgba(224,160,48,0.10)
fanPopoverBg: Color(0xEBFFFFFF),        // rgba(255,255,255,0.92)
symKeyResting: Color(0x0A000000),       // rgba(0,0,0,0.04)
joystickFill: Color(0x0A000000),        // rgba(0,0,0,0.04)
joystickBorder: Color(0x0F000000),      // rgba(0,0,0,0.06)
joystickPressed: Color(0x1AE0A030),     // rgba(224,160,48,0.10)
joystickPressedBorder: Color(0x33E0A030), // rgba(224,160,48,0.20)
returnGradientStart: Color(0x38E0A030), // rgba(224,160,48,0.22)
returnGradientEnd: Color(0x14E0A030),   // rgba(224,160,48,0.08)
returnGlow: Color(0x0FE0A030),          // rgba(224,160,48,0.06)
```

- [ ] **Step 4: Verify build compiles**

Run:
```bash
cd android-companion && flutter analyze lib/app/colors.dart
```
Expected: No errors

- [ ] **Step 5: Commit**

```bash
git add android-companion/lib/app/colors.dart
git commit -m "feat(android): add modifier bar component color tokens"
```

---

### Task 2: Joystick Button Widget

**Files:**
- Create: `android-companion/lib/terminal/joystick_button.dart`

This is the most complex widget. It handles two gesture modes (quick swipe vs hold+drag repeat) and renders a custom crosshair icon.

- [ ] **Step 1: Create joystick_button.dart with CrosshairPainter**

```dart
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
```

- [ ] **Step 2: Verify build compiles**

Run:
```bash
cd android-companion && flutter analyze lib/terminal/joystick_button.dart
```
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add android-companion/lib/terminal/joystick_button.dart
git commit -m "feat(android): add joystick button widget with swipe/hold+drag gestures"
```

---

### Task 3: Fan-out Symbol Button

**Files:**
- Create: `android-companion/lib/terminal/fan_out_button.dart`

- [ ] **Step 1: Create fan_out_button.dart**

```dart
/// Fan-out symbol button that reveals ~ | / - on tap.
///
/// Resting state shows a fan icon (three radiating rays).
/// Tap opens a frosted popover above the button with four symbol keys.
/// Tap a symbol to insert it and auto-dismiss.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';

class FanOutButton extends StatefulWidget {
  /// Called with the symbol character to send.
  final ValueChanged<String> onInput;

  const FanOutButton({super.key, required this.onInput});

  @override
  State<FanOutButton> createState() => _FanOutButtonState();
}

class _FanOutButtonState extends State<FanOutButton> {
  bool _isOpen = false;
  bool _pressed = false;
  OverlayEntry? _overlayEntry;

  static const _symbols = ['~', '|', '/', '-'];

  void _toggle() {
    if (_isOpen) {
      _close();
    } else {
      _open();
    }
  }

  void _open() {
    HapticFeedback.lightImpact();
    setState(() => _isOpen = true);

    _overlayEntry = OverlayEntry(
      builder: (context) => _FanPopover(
        anchor: _buttonGlobalRect(),
        symbols: _symbols,
        onSelect: (symbol) {
          HapticFeedback.selectionClick();
          widget.onInput(symbol);
          _close();
        },
        onDismiss: _close,
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _close() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() => _isOpen = false);
  }

  Rect _buttonGlobalRect() {
    final box = context.findRenderObject() as RenderBox;
    final position = box.localToGlobal(Offset.zero);
    return position & box.size;
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        _toggle();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: Semantics(
        label: 'Symbol shortcuts. Tap to open.',
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutExpo,
            width: 38,
            height: 34,
            decoration: BoxDecoration(
              color: _isOpen ? c.fanBtnActive : c.fanBtnResting,
              borderRadius: BorderRadius.circular(10),
            ),
            child: CustomPaint(
              painter: FanIconPainter(
                color: _isOpen ? c.accentText : c.keyGroupText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the fan icon: three rays radiating upward from a base dot.
class FanIconPainter extends CustomPainter {
  final Color color;

  FanIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 2);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    const rayLength = 10.0;
    const spreadAngle = 30.0 * 3.14159 / 180; // 30 degrees

    // Three rays from center: -30°, 0°, +30° (measuring from vertical)
    for (final angle in [-spreadAngle, 0.0, spreadAngle]) {
      final endX = center.dx + rayLength * math.sin(angle);
      final endY = center.dy - rayLength * math.cos(angle);
      canvas.drawLine(center, Offset(endX, endY), paint);
    }

    // Base dot
    canvas.drawCircle(
      Offset(center.dx, center.dy + 1),
      1.5,
      Paint()..color = color.withAlpha(150),
    );
  }

  @override
  bool shouldRepaint(FanIconPainter oldDelegate) => color != oldDelegate.color;
}

/// Frosted popover showing symbol keys, positioned above the anchor button.
class _FanPopover extends StatelessWidget {
  final Rect anchor;
  final List<String> symbols;
  final ValueChanged<String> onSelect;
  final VoidCallback onDismiss;

  const _FanPopover({
    required this.anchor,
    required this.symbols,
    required this.onSelect,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    // Popover width: 4 keys * 48px + 3 gaps * 4px + 10px padding = 214px
    const popoverWidth = 214.0;
    const popoverHeight = 52.0;
    const gap = 8.0;

    // Center popover above the anchor button
    final left = anchor.center.dx - popoverWidth / 2;
    final top = anchor.top - popoverHeight - gap;

    return Stack(
      children: [
        // Dismiss scrim (transparent, full screen)
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        // Popover
        Positioned(
          left: left.clamp(8.0, MediaQuery.of(context).size.width - popoverWidth - 8),
          top: top,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: c.fanPopoverBg,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(80),
                      blurRadius: 24,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: symbols.map((s) => Padding(
                    padding: EdgeInsets.only(
                      left: s == symbols.first ? 0 : 4,
                    ),
                    child: _SymbolKey(
                      symbol: s,
                      onTap: () => onSelect(s),
                    ),
                  )).toList(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Individual symbol key inside the fan-out popover.
class _SymbolKey extends StatefulWidget {
  final String symbol;
  final VoidCallback onTap;

  const _SymbolKey({required this.symbol, required this.onTap});

  @override
  State<_SymbolKey> createState() => _SymbolKeyState();
}

class _SymbolKeyState extends State<_SymbolKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 60),
        child: Container(
          width: 48,
          height: 42,
          decoration: BoxDecoration(
            color: c.symKeyResting,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.symbol,
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
```

**Note:** The `FanIconPainter` uses `math.sin`/`math.cos` from `dart:math`. The rays go at -30°, 0°, +30° from vertical, radiating upward from a base dot. Verify visually on device.

- [ ] **Step 2: Verify build compiles**

Run:
```bash
cd android-companion && flutter analyze lib/terminal/fan_out_button.dart
```
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add android-companion/lib/terminal/fan_out_button.dart
git commit -m "feat(android): add fan-out symbol button with popover"
```

---

### Task 4: Rewrite Modifier Bar

**Files:**
- Modify: `android-companion/lib/terminal/modifier_bar.dart`

Replace the entire file content. The new bar has: esc+ctrl capsule, divider, fan-out button, spacer, joystick, divider, return key.

- [ ] **Step 1: Rewrite modifier_bar.dart**

Replace the full contents of `modifier_bar.dart` with the new layout. Key changes from the current implementation:

1. **Remove:** `_FanButton` (old +/clipboard buttons), `_ArrowCluster`, `_ArrowKey`
2. **Add:** `_KeyGroupCapsule` (esc + ctrl), import `JoystickButton` and `FanOutButton`
3. **Modify:** `_ReturnKey` gets amber gradient treatment
4. **Add:** Ctrl sticky state management in `_ModifierBarState`

```dart
/// Floating capsule modifier toolbar — redesigned with joystick arrows.
///
/// Layout: esc ctrl | fan | ——— spacer ——— | joystick | return
///
/// Spec: docs/superpowers/specs/2026-03-18-modifier-bar-joystick-redesign.md
/// Visual: docs/mobile-ux/modifier-bar-joystick-design.html
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';
import 'fan_out_button.dart';
import 'joystick_button.dart';

class ModifierBar extends StatefulWidget {
  final ValueChanged<String> onInput;

  const ModifierBar({super.key, required this.onInput});

  @override
  State<ModifierBar> createState() => _ModifierBarState();
}

class _ModifierBarState extends State<ModifierBar> {
  /// Ctrl modifier state: inactive, sticky (single tap), locked (double tap).
  _CtrlState _ctrlState = _CtrlState.inactive;
  DateTime? _lastCtrlTap;

  void _onCtrlTap() {
    HapticFeedback.selectionClick();
    final now = DateTime.now();
    final isDoubleTap = _lastCtrlTap != null &&
        now.difference(_lastCtrlTap!) < const Duration(milliseconds: 400);
    _lastCtrlTap = now;

    setState(() {
      if (isDoubleTap && _ctrlState == _CtrlState.sticky) {
        _ctrlState = _CtrlState.locked;
      } else if (_ctrlState != _CtrlState.inactive) {
        _ctrlState = _CtrlState.inactive;
      } else {
        _ctrlState = _CtrlState.sticky;
      }
    });
  }

  void _onInput(String data) {
    widget.onInput(data);
    // Auto-release sticky ctrl after consuming an input
    if (_ctrlState == _CtrlState.sticky) {
      setState(() => _ctrlState = _CtrlState.inactive);
    }
  }

  void _onEsc() {
    HapticFeedback.mediumImpact();
    widget.onInput('\x1b');
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      height: 50, // taller to accommodate 40px joystick + padding
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: c.modifierBarBg,
      ),
      clipBehavior: Clip.hardEdge,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Row(
            children: [
              // Zone 1: esc + ctrl capsule
              _KeyGroupCapsule(
                ctrlState: _ctrlState,
                onEsc: _onEsc,
                onCtrl: _onCtrlTap,
              ),

              // Divider
              _BarDivider(),

              // Zone 2: fan-out symbol button
              FanOutButton(onInput: _onInput),

              // Spacer — generous gap between left tools and right actions
              const Spacer(),

              // Zone 3: joystick
              JoystickButton(
                onInput: _onInput,
                ctrlActive: _ctrlState != _CtrlState.inactive,
              ),

              // Divider
              _BarDivider(),

              // Zone 4: return key
              _ReturnKey(onTap: () {
                HapticFeedback.mediumImpact();
                widget.onInput('\r');
              }),
            ],
          ),
        ),
      ),
    );
  }
}

enum _CtrlState { inactive, sticky, locked }

/// Esc + Ctrl paired capsule. Two keys in a connected group.
class _KeyGroupCapsule extends StatelessWidget {
  final _CtrlState ctrlState;
  final VoidCallback onEsc;
  final VoidCallback onCtrl;

  const _KeyGroupCapsule({
    required this.ctrlState,
    required this.onEsc,
    required this.onCtrl,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: c.keyGroupResting.withAlpha(10), // capsule background tint
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GroupedKey(
            label: 'esc',
            isActive: false,
            isLocked: false,
            isFirst: true,
            onTap: onEsc,
          ),
          SizedBox(width: 1, height: 34, child: ColoredBox(color: c.border)),
          _GroupedKey(
            label: 'ctrl',
            isActive: ctrlState != _CtrlState.inactive,
            isLocked: ctrlState == _CtrlState.locked,
            isFirst: false,
            onTap: onCtrl,
          ),
        ],
      ),
    );
  }
}

/// Individual key within the esc+ctrl capsule.
class _GroupedKey extends StatefulWidget {
  final String label;
  final bool isActive;
  final bool isLocked;
  final bool isFirst;
  final VoidCallback onTap;

  const _GroupedKey({
    required this.label,
    required this.isActive,
    required this.isLocked,
    required this.isFirst,
    required this.onTap,
  });

  @override
  State<_GroupedKey> createState() => _GroupedKeyState();
}

class _GroupedKeyState extends State<_GroupedKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    final bg = widget.isActive ? c.keyGroupActive : c.keyGroupResting;
    final fg = widget.isActive ? c.accentText : c.keyGroupText;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: Semantics(
        label: widget.isActive
            ? '${widget.label}, active${widget.isLocked ? ', locked' : ''}'
            : '${widget.label}, inactive',
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            width: 44,
            height: 34,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: widget.isFirst
                  ? const BorderRadius.horizontal(left: Radius.circular(10))
                  : const BorderRadius.horizontal(right: Radius.circular(10)),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: fg,
                  ),
                ),
                // Locked indicator: 2px amber underline
                if (widget.isLocked)
                  Container(
                    width: 16,
                    height: 2,
                    margin: const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      color: c.accent,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Subtle vertical divider between zones.
class _BarDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: c.border,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}

/// Return key with warm amber gradient.
class _ReturnKey extends StatefulWidget {
  final VoidCallback onTap;

  const _ReturnKey({required this.onTap});

  @override
  State<_ReturnKey> createState() => _ReturnKeyState();
}

class _ReturnKeyState extends State<_ReturnKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: const Alignment(-0.5, -1),
              end: const Alignment(0.5, 1),
              colors: [c.returnGradientStart, c.returnGradientEnd],
            ),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: c.returnGlow,
                blurRadius: 20,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            'RETURN',
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: c.accentText,
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify build compiles**

Run:
```bash
cd android-companion && flutter analyze lib/terminal/modifier_bar.dart
```
Expected: No errors

- [ ] **Step 3: Build and test on device**

Run:
```bash
cd /Users/sm/code/cmux && ./scripts/reload.sh --tag joystick-bar
```

Verify visually:
1. Bar shows: `esc ctrl | ⌇ | ——— | ⊞ | return`
2. Esc sends ESC (exits vim insert mode)
3. Ctrl toggles amber on single tap, underline on double tap
4. Fan button opens popover with ~ | / - symbols
5. Joystick: swipe sends single arrow, hold+drag repeats
6. Return key has amber gradient glow

- [ ] **Step 4: Commit**

```bash
git add android-companion/lib/terminal/modifier_bar.dart
git commit -m "feat(android): rewrite modifier bar with joystick, esc/ctrl, fan-out layout"
```

---

### Task 5: Polish and Edge Cases

**Files:**
- Modify: `android-companion/lib/terminal/joystick_button.dart`
- Modify: `android-companion/lib/terminal/fan_out_button.dart`

- [ ] **Step 1: Add Semantics to JoystickButton**

Wrap the `GestureDetector` in `joystick_button.dart`'s build method with:

```dart
Semantics(
  label: 'Arrow key joystick. Swipe for single arrow, press and hold then drag for repeat.',
  child: GestureDetector(...)
)
```

- [ ] **Step 2: Test all interactions on device**

Run:
```bash
cd /Users/sm/code/cmux && ./scripts/reload.sh --tag joystick-bar
```

Test matrix:
- [ ] Quick swipe left → fires `\x1b[D` once
- [ ] Quick swipe right → fires `\x1b[C` once
- [ ] Quick swipe up → fires `\x1b[A` once
- [ ] Quick swipe down → fires `\x1b[B` once
- [ ] Hold + drag right → repeats `\x1b[C` with acceleration
- [ ] Hold + drag, change direction mid-hold → switches direction
- [ ] Release → repeat stops instantly
- [ ] Tap ctrl → amber highlight, then swipe → `\x1b[1;5X`, ctrl auto-releases
- [ ] Double-tap ctrl → amber + underline (locked), swipes send Ctrl+arrow, ctrl stays active
- [ ] Tap ctrl again → deactivates
- [ ] Tap esc → sends `\x1b`
- [ ] Tap fan → popover appears with ~ | / -
- [ ] Tap ~ → inserts ~, popover closes
- [ ] Tap outside popover → closes
- [ ] Return → amber gradient, sends `\r`

- [ ] **Step 3: Commit**

```bash
git add android-companion/lib/terminal/joystick_button.dart android-companion/lib/terminal/fan_out_button.dart
git commit -m "fix(android): add joystick semantics and verify interactions"
```

---

### Task 6: Update Documentation

**Files:**
- Modify: `docs/mobile-ux/modifier-bar-joystick-design.html` (if any visual changes)
- Modify: `docs/superpowers/specs/2026-03-18-modifier-bar-joystick-redesign.md` (mark as implemented)

- [ ] **Step 1: Mark spec as implemented**

Change the status line in the spec from `Approved` to `Implemented`.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-03-18-modifier-bar-joystick-redesign.md
git commit -m "docs: mark modifier bar joystick redesign as implemented"
```
