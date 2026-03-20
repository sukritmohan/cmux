/// Keyboard toggle button for the modifier bar.
///
/// Short tap toggles the soft keyboard by toggling focus on
/// [keyboardFocusNode]. Long-press toggles autocomplete suggestions
/// via [autocompleteActiveNotifier].
///
/// Visual state reflects autocomplete status:
///   - Autocomplete ON (default): blue accent gradient, blue border/glow/icon.
///   - Autocomplete OFF: dim background, no gradient/border/glow, dim icon.
///
/// Active keyboard state (border boost, glow increase) layers on top of the
/// autocomplete-driven base style.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';

/// Toggle button that shows/hides the soft keyboard (tap) and toggles
/// autocomplete suggestions (long-press).
///
/// Inputs:
///   [keyboardFocusNode] — the FocusNode that drives soft keyboard visibility.
///   [autocompleteActiveNotifier] — shared notifier controlling whether the
///   hidden TextField has `enableSuggestions` and `autocorrect` enabled.
///
/// Behavior:
///   - Tapping while unfocused calls [FocusNode.requestFocus] to open keyboard.
///   - Tapping while focused calls [FocusNode.unfocus] to close keyboard.
///   - Long-press toggles [autocompleteActiveNotifier.value] with medium haptic.
///   - Visual base style tracks autocomplete state (blue = ON, dim = OFF).
///   - Keyboard active state boosts border alpha and glow when autocomplete ON.
///   - Press animation scales to 0.93 (matching other modifier bar buttons).
///   - Provides [HapticFeedback.lightImpact] on every tap.
class KeyboardButton extends StatefulWidget {
  final FocusNode keyboardFocusNode;
  final ValueNotifier<bool> autocompleteActiveNotifier;

  const KeyboardButton({
    super.key,
    required this.keyboardFocusNode,
    required this.autocompleteActiveNotifier,
  });

  @override
  State<KeyboardButton> createState() => _KeyboardButtonState();
}

class _KeyboardButtonState extends State<KeyboardButton> {
  bool _pressed = false;

  /// Whether the keyboard focus node currently has focus (keyboard is visible).
  bool get _isKeyboardActive => widget.keyboardFocusNode.hasFocus;

  /// Whether autocomplete suggestions are enabled.
  bool get _isAutocompleteOn => widget.autocompleteActiveNotifier.value;

  @override
  void initState() {
    super.initState();
    // Rebuild when focus changes so the visual active state stays in sync.
    widget.keyboardFocusNode.addListener(_rebuild);
    widget.autocompleteActiveNotifier.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.keyboardFocusNode.removeListener(_rebuild);
    widget.autocompleteActiveNotifier.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
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

  void _onLongPress() {
    HapticFeedback.mediumImpact();
    widget.autocompleteActiveNotifier.value =
        !widget.autocompleteActiveNotifier.value;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    // Autocomplete ON: blue accent style. OFF: dim style.
    if (_isAutocompleteOn) {
      // When keyboard is active, boost border alpha and glow.
      final borderColor = _isKeyboardActive
          ? Color.fromARGB(
              (c.keyboardBtnBorder.a * 2.0).round().clamp(0, 255),
              c.keyboardBtnBorder.r.round(),
              c.keyboardBtnBorder.g.round(),
              c.keyboardBtnBorder.b.round(),
            )
          : c.keyboardBtnBorder;
      final glowBlurRadius = _isKeyboardActive ? 20.0 : 12.0;

      return _buildGesture(
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [c.keyboardBtnGradientStart, c.keyboardBtnGradientEnd],
            ),
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
            size: 16,
            color: c.keyboardBtnIcon,
          ),
        ),
      );
    }

    // Autocomplete OFF: dim style.
    return _buildGesture(
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x0FFFFFFF), // rgba(255,255,255,0.06)
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.keyboard_outlined,
          size: 16,
          color: c.keyGroupText.withAlpha(100),
        ),
      ),
    );
  }

  /// Wraps the button content with gesture handling, semantics, and press
  /// animation.
  Widget _buildGesture({required Widget child}) {
    final autocompleteLabel =
        _isAutocompleteOn ? 'autocomplete on' : 'autocomplete off';
    final keyboardLabel =
        _isKeyboardActive ? 'Hide keyboard' : 'Show keyboard';

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        _onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      onLongPress: _onLongPress,
      child: Semantics(
        label: '$keyboardLabel, $autocompleteLabel, long press to toggle',
        button: true,
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: child,
        ),
      ),
    );
  }
}
