/// Floating capsule modifier toolbar matching the pane-type-switcher spec.
///
/// Spec design (sections 8-9):
/// - Floating capsule: rounded 18px, backdrop blur(24px), semi-transparent bg
/// - Margin: 0 8px 2px
/// - Three zones with 1px dividers:
///   (1) (+) amber accent button + clipboard button
///   (2) Inverted-T arrow grid (3x2, 26px cells)
///   (3) "RETURN" key (9px, 700 weight, uppercase)
/// - All keys: 32px height, rounded 10px, borderless
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';

class ModifierBar extends StatefulWidget {
  /// Called with the escape sequence or character to send to the PTY.
  final ValueChanged<String> onInput;

  const ModifierBar({super.key, required this.onInput});

  @override
  State<ModifierBar> createState() => _ModifierBarState();
}

class _ModifierBarState extends State<ModifierBar> {
  void _sendKey(String data) {
    HapticFeedback.lightImpact();
    widget.onInput(data);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      height: 42,
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
              // Zone 1: (+) accent button + clipboard button
              _FanButton(
                icon: Icons.add,
                isAccent: true,
                onTap: () {
                  // Fan-out will expand to show Esc/Ctrl/Alt/Tab
                  HapticFeedback.mediumImpact();
                },
              ),
              const SizedBox(width: 4),
              _FanButton(
                icon: Icons.content_paste,
                isAccent: false,
                onTap: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null && data!.text!.isNotEmpty) {
                    _sendKey(data.text!);
                  }
                },
              ),

              // Divider
              _BarDivider(),

              // Zone 2: inverted-T arrow cluster
              _ArrowCluster(onArrow: _sendKey),

              // Divider
              _BarDivider(),

              // Zone 3: RETURN key
              _ReturnKey(onTap: () => _sendKey('\r')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fan-out action button: (+) or clipboard. 38x32, rounded 10px.
class _FanButton extends StatefulWidget {
  final IconData icon;
  final bool isAccent;
  final VoidCallback onTap;

  const _FanButton({
    required this.icon,
    required this.isAccent,
    required this.onTap,
  });

  @override
  State<_FanButton> createState() => _FanButtonState();
}

class _FanButtonState extends State<_FanButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Color bg;
    Color fg;

    if (widget.isAccent) {
      bg = isDark
          ? const Color(0x38E0A030) // amber gradient-like
          : const Color(0x28E0A030);
      fg = c.accentText;
    } else {
      bg = isDark
          ? Colors.white.withAlpha(18)
          : Colors.black.withAlpha(13);
      fg = isDark
          ? Colors.white.withAlpha(128)
          : Colors.black.withAlpha(102);
    }

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
          width: 38,
          height: 32,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 15, color: fg),
        ),
      ),
    );
  }
}

/// Subtle vertical divider between zones.
class _BarDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withAlpha(18)
            : Colors.black.withAlpha(18),
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}

/// Inverted-T arrow key cluster: 3x2 grid, 26px cells.
class _ArrowCluster extends StatelessWidget {
  final void Function(String) onArrow;

  const _ArrowCluster({required this.onArrow});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 26 * 3 + 4, // 3 columns + gaps
      height: 32,
      child: Stack(
        children: [
          // Top row: up arrow centered
          Positioned(
            left: 27,
            top: 0,
            child: _ArrowKey(
              icon: Icons.keyboard_arrow_up,
              onTap: () => onArrow('\x1b[A'),
            ),
          ),
          // Bottom row: left, down, right
          Positioned(
            left: 0,
            top: 16,
            child: _ArrowKey(
              icon: Icons.keyboard_arrow_left,
              onTap: () => onArrow('\x1b[D'),
            ),
          ),
          Positioned(
            left: 27,
            top: 16,
            child: _ArrowKey(
              icon: Icons.keyboard_arrow_down,
              onTap: () => onArrow('\x1b[B'),
            ),
          ),
          Positioned(
            left: 54,
            top: 16,
            child: _ArrowKey(
              icon: Icons.keyboard_arrow_right,
              onTap: () => onArrow('\x1b[C'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Individual arrow key: 26x14, rounded 6px, borderless.
class _ArrowKey extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ArrowKey({required this.icon, required this.onTap});

  @override
  State<_ArrowKey> createState() => _ArrowKeyState();
}

class _ArrowKeyState extends State<_ArrowKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.90 : 1.0,
        duration: const Duration(milliseconds: 60),
        child: Container(
          width: 26,
          height: 14,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withAlpha(15)
                : Colors.black.withAlpha(10),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: 10,
            color: isDark
                ? Colors.white.withAlpha(102)
                : Colors.black.withAlpha(89),
          ),
        ),
      ),
    );
  }
}

/// "RETURN" key: elevated action button. 9px, 700 weight, uppercase.
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          margin: const EdgeInsets.only(left: 3),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withAlpha(20)
                : Colors.black.withAlpha(15),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            'RETURN',
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: isDark
                  ? Colors.white.withAlpha(191)
                  : Colors.black.withAlpha(140),
            ),
          ),
        ),
      ),
    );
  }
}
