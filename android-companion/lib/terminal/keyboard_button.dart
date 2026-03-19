/// Keyboard toggle button for the modifier bar.
///
/// Tapping the button requests or dismisses the soft keyboard by toggling
/// focus on [keyboardFocusNode]. The button uses a blue accent gradient to
/// visually distinguish it from the warm amber palette used by other elements
/// in the modifier bar.
///
/// Active state (keyboard visible) is driven by listening to [keyboardFocusNode]
/// directly, so the visual state always reflects actual focus, not just the
/// last tap action.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';

/// Toggle button that shows or hides the soft keyboard.
///
/// Inputs:
///   [keyboardFocusNode] — the FocusNode that drives soft keyboard visibility.
///
/// Behavior:
///   - Tapping while unfocused calls [FocusNode.requestFocus] to open keyboard.
///   - Tapping while focused calls [FocusNode.unfocus] to close keyboard.
///   - Visual active state tracks actual focus via a listener, not local state.
///   - Press animation scales to 0.93 (matching other modifier bar buttons).
///   - Provides [HapticFeedback.lightImpact] on every tap.
class KeyboardButton extends StatefulWidget {
  final FocusNode keyboardFocusNode;

  const KeyboardButton({super.key, required this.keyboardFocusNode});

  @override
  State<KeyboardButton> createState() => _KeyboardButtonState();
}

class _KeyboardButtonState extends State<KeyboardButton> {
  bool _pressed = false;

  /// Whether the keyboard focus node currently has focus (keyboard is visible).
  bool get _isActive => widget.keyboardFocusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    // Rebuild when focus changes so the visual active state stays in sync.
    widget.keyboardFocusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    widget.keyboardFocusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() {
    // Trigger a rebuild so the active visual state reflects real focus.
    setState(() {});
  }

  void _onTap() {
    HapticFeedback.lightImpact();
    if (widget.keyboardFocusNode.hasFocus) {
      widget.keyboardFocusNode.unfocus();
    } else {
      widget.keyboardFocusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    // When active, boost the border alpha (~2×) and increase glow blur radius
    // to signal the keyboard is visible.
    final borderColor = _isActive
        ? Color.fromARGB(
            (c.keyboardBtnBorder.a * 2.0).round().clamp(0, 255),
            c.keyboardBtnBorder.r.round(),
            c.keyboardBtnBorder.g.round(),
            c.keyboardBtnBorder.b.round(),
          )
        : c.keyboardBtnBorder;
    final glowBlurRadius = _isActive ? 20.0 : 12.0;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        _onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: Semantics(
        label: _isActive ? 'Hide keyboard' : 'Show keyboard',
        button: true,
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            width: 46,
            height: 34,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                // 135 degrees: begin top-left, end bottom-right.
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [c.keyboardBtnGradientStart, c.keyboardBtnGradientEnd],
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor, width: 1),
              boxShadow: [
                BoxShadow(
                  color: c.keyboardBtnGlow,
                  blurRadius: glowBlurRadius,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.keyboard_outlined,
              size: 18,
              color: c.keyboardBtnIcon,
            ),
          ),
        ),
      ),
    );
  }
}
