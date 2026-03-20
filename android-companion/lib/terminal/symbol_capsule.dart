/// Inline symbol capsule for the modifier bar — replaces the old FanOutButton popover.
///
/// Displays four terminal symbols (~, |, /, -) in a connected horizontal capsule
/// with 1px dividers between each key. Tapping any symbol fires [onInput] directly
/// with the raw character, bypassing any Ctrl modifier state.
///
/// Spec: docs/superpowers/specs/2026-03-18-modifier-bar-joystick-redesign.md
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';

/// Connected capsule of four symbol keys: ~, |, /, -.
///
/// Each key is 36px tall (flex:1 width) with JetBrains Mono 15px weight-500 text.
/// Tapping a key fires [onInput] with the symbol character and
/// triggers [HapticFeedback.selectionClick].
///
/// IMPORTANT: [onInput] sends raw characters directly to the terminal PTY.
/// It does NOT go through the modifier bar's Ctrl-consuming wrapper, so
/// these symbols always bypass the Ctrl modifier state.
class SymbolCapsule extends StatelessWidget {
  final ValueChanged<String> onInput;

  const SymbolCapsule({super.key, required this.onInput});

  static const _symbols = ['~', '|', '/', '-'];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      height: 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: const Color(0x08FFFFFF), // rgba(255,255,255,0.03)
      ),
      child: Row(
        children: [
          for (int i = 0; i < _symbols.length; i++) ...[
            if (i > 0)
              SizedBox(width: 1, height: 36, child: ColoredBox(color: c.border)),
            Expanded(
              child: _SymbolKey(
                symbol: _symbols[i],
                position: i == 0
                    ? _KeyPosition.first
                    : i == _symbols.length - 1
                        ? _KeyPosition.last
                        : _KeyPosition.middle,
                onTap: () => onInput(_symbols[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _KeyPosition { first, middle, last }

/// Single symbol key within [SymbolCapsule].
///
/// Renders a 34×34px tap target with a press-scale animation (0.93 on tap down).
/// Fires haptic feedback and the parent [onTap] callback on release.
class _SymbolKey extends StatefulWidget {
  final String symbol;
  final _KeyPosition position;
  final VoidCallback onTap;

  const _SymbolKey({
    required this.symbol,
    required this.position,
    required this.onTap,
  });

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
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: Semantics(
        label: widget.symbol,
        button: true,
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              borderRadius: switch (widget.position) {
                _KeyPosition.first =>
                  const BorderRadius.horizontal(left: Radius.circular(10)),
                _KeyPosition.middle => BorderRadius.zero,
                _KeyPosition.last =>
                  const BorderRadius.horizontal(right: Radius.circular(10)),
              },
            ),
            alignment: Alignment.center,
            child: Text(
              widget.symbol,
              style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: c.keyGroupText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
