/// Modifier bar with Esc, Ctrl, Alt, Tab toggles and arrow keys.
///
/// Sits below the terminal content area. Sends escape sequences
/// to the PTY via the [onInput] callback.
/// Full styling/toggle logic in Chunk 5.
library;

import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: AppColors.bgSecondary,
        border: Border(
          top: BorderSide(color: AppColors.borderSubtle),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          // Left group: modifier keys
          _KeyButton(
            label: 'Esc',
            onTap: () => widget.onInput('\x1b'),
          ),
          const SizedBox(width: 4),
          _KeyButton(
            label: 'Ctrl',
            isActive: _ctrlActive,
            onTap: () => setState(() => _ctrlActive = !_ctrlActive),
          ),
          const SizedBox(width: 4),
          _KeyButton(
            label: 'Alt',
            isActive: _altActive,
            onTap: () => setState(() => _altActive = !_altActive),
          ),
          const SizedBox(width: 4),
          _KeyButton(
            label: 'Tab',
            onTap: () => _sendKey('\t'),
          ),

          const Spacer(),

          // Right group: arrow keys
          _KeyButton(
            icon: Icons.arrow_back,
            onTap: () => _sendKey('\x1b[D'),
          ),
          const SizedBox(width: 4),
          _KeyButton(
            icon: Icons.arrow_downward,
            onTap: () => _sendKey('\x1b[B'),
          ),
          const SizedBox(width: 4),
          _KeyButton(
            icon: Icons.arrow_upward,
            onTap: () => _sendKey('\x1b[A'),
          ),
          const SizedBox(width: 4),
          _KeyButton(
            icon: Icons.arrow_forward,
            onTap: () => _sendKey('\x1b[C'),
          ),

          const SizedBox(width: 8),

          // Enter key
          _KeyButton(
            icon: Icons.keyboard_return,
            onTap: () => _sendKey('\r'),
          ),
        ],
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final bool isActive;
  final VoidCallback onTap;

  const _KeyButton({
    this.label,
    this.icon,
    this.isActive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        constraints: const BoxConstraints(minWidth: 40),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: isActive ? AppColors.accentBlue : AppColors.bgTertiary,
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
          border: Border.all(
            color: isActive ? AppColors.accentBlue : AppColors.borderSubtle,
          ),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: AppColors.accentBlue.withAlpha(60),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: icon != null
            ? Icon(
                icon,
                size: 16,
                color: isActive
                    ? AppColors.bgPrimary
                    : AppColors.textPrimary,
              )
            : Text(
                label ?? '',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isActive
                      ? AppColors.bgPrimary
                      : AppColors.textPrimary,
                ),
              ),
      ),
    );
  }
}
