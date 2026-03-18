/// Modifier bar with Esc, Ctrl, Alt, Tab toggles and arrow keys.
///
/// Sits below the terminal content area. Sends escape sequences
/// to the PTY via the [onInput] callback.
library;

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
  bool _ctrlActive = false;
  bool _altActive = false;

  void _sendKey(String data) {
    HapticFeedback.lightImpact();

    String prefix = '';
    if (_ctrlActive) prefix += '\x1b';
    if (_altActive) prefix += '\x1b';

    widget.onInput('$prefix$data');

    // Clear toggle modifiers after sending a non-modifier key.
    if (_ctrlActive || _altActive) {
      setState(() {
        _ctrlActive = false;
        _altActive = false;
      });
    }
  }

  void _toggleModifier({required bool Function() getter, required void Function(bool) setter}) {
    HapticFeedback.mediumImpact();
    setState(() => setter(!getter()));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: AppColors.bgSecondary,
        border: Border(
          top: BorderSide(color: AppColors.borderSubtle),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          // Left group: modifier keys
          _KeyButton(
            label: 'Esc',
            onTap: () {
              HapticFeedback.lightImpact();
              widget.onInput('\x1b');
            },
          ),
          const SizedBox(width: 4),
          _KeyButton(
            label: 'Ctrl',
            isActive: _ctrlActive,
            onTap: () => _toggleModifier(
              getter: () => _ctrlActive,
              setter: (v) => _ctrlActive = v,
            ),
          ),
          const SizedBox(width: 4),
          _KeyButton(
            label: 'Alt',
            isActive: _altActive,
            onTap: () => _toggleModifier(
              getter: () => _altActive,
              setter: (v) => _altActive = v,
            ),
          ),
          const SizedBox(width: 4),
          _KeyButton(
            label: 'Tab',
            onTap: () => _sendKey('\t'),
          ),

          const Spacer(),

          // Right group: arrow keys in a grouped pill
          _ArrowKeyGroup(onArrow: _sendKey),

          const SizedBox(width: 8),

          // Enter key with accent background
          _KeyButton(
            icon: Icons.keyboard_return,
            isEnter: true,
            onTap: () => _sendKey('\r'),
          ),
        ],
      ),
    );
  }
}

/// Groups arrow keys into a single rounded pill container.
class _ArrowKeyGroup extends StatelessWidget {
  final void Function(String) onArrow;

  const _ArrowKeyGroup({required this.onArrow});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: AppColors.bgTertiary,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ArrowButton(icon: Icons.arrow_back, onTap: () => onArrow('\x1b[D')),
          _divider(),
          _ArrowButton(icon: Icons.arrow_downward, onTap: () => onArrow('\x1b[B')),
          _divider(),
          _ArrowButton(icon: Icons.arrow_upward, onTap: () => onArrow('\x1b[A')),
          _divider(),
          _ArrowButton(icon: Icons.arrow_forward, onTap: () => onArrow('\x1b[C')),
        ],
      ),
    );
  }

  static Widget _divider() {
    return Container(
      width: 1,
      height: 20,
      color: AppColors.borderSubtle,
    );
  }
}

/// Individual arrow button inside the grouped pill (no outer border).
class _ArrowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ArrowButton({required this.icon, required this.onTap});

  @override
  State<_ArrowButton> createState() => _ArrowButtonState();
}

class _ArrowButtonState extends State<_ArrowButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 16, color: AppColors.textPrimary),
        ),
      ),
    );
  }
}

class _KeyButton extends StatefulWidget {
  final String? label;
  final IconData? icon;
  final bool isActive;
  final bool isEnter;
  final VoidCallback onTap;

  const _KeyButton({
    this.label,
    this.icon,
    this.isActive = false,
    this.isEnter = false,
    required this.onTap,
  });

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isActive;

    // Active modifier glow: accentBlue at 12% bg + 80% border + subtle shadow
    final Color bgColor;
    final Color borderColor;
    final List<BoxShadow>? shadows;

    if (isActive) {
      bgColor = AppColors.accentBlue.withAlpha(31); // ~12%
      borderColor = AppColors.accentBlue.withAlpha(204); // ~80%
      shadows = [
        BoxShadow(
          color: AppColors.accentBlue.withAlpha(40),
          blurRadius: 8,
          spreadRadius: 1,
        ),
      ];
    } else if (widget.isEnter) {
      bgColor = AppColors.accentBlue.withAlpha(38); // ~15%
      borderColor = AppColors.borderSubtle;
      shadows = null;
    } else {
      bgColor = AppColors.bgTertiary;
      borderColor = AppColors.borderSubtle;
      shadows = null;
    }

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          height: 36,
          constraints: const BoxConstraints(minWidth: 40),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            border: Border.all(color: borderColor),
            boxShadow: shadows,
          ),
          alignment: Alignment.center,
          child: widget.icon != null
              ? Icon(
                  widget.icon,
                  size: 16,
                  color: isActive
                      ? AppColors.accentBlue
                      : AppColors.textPrimary,
                )
              : Text(
                  widget.label ?? '',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isActive
                        ? AppColors.accentBlue
                        : AppColors.textPrimary,
                  ),
                ),
        ),
      ),
    );
  }
}
