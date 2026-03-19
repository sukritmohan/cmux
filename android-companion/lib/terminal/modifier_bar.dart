/// Floating capsule modifier toolbar — 2-row layout.
///
/// Layout:
///   Row 1: [esc|tab|ctrl] · spacer · · · · · · · · [voice]      ║ joystick
///   Row 2: [~ | / -    ] · spacer · [clipboard] · [keyboard]  ║ return
///
/// Spec: docs/superpowers/specs/2026-03-18-modifier-bar-2row-clipboard-keyboard-design.md
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';
import 'clipboard_button.dart';
import 'clipboard_history.dart';
import 'joystick_button.dart';
import 'keyboard_button.dart';
import 'symbol_capsule.dart';
import 'voice_button.dart';

class ModifierBar extends StatefulWidget {
  final ValueChanged<String> onInput;

  /// Notifier for Ctrl modifier state, so the terminal view can apply
  /// Ctrl to soft keyboard input (e.g., Ctrl+C → \x03).
  final ValueNotifier<bool> ctrlActiveNotifier;

  /// Clipboard history state for badge display and bottom sheet.
  final ClipboardHistoryState clipboardHistoryState;

  /// Clipboard history notifier for mutations (star, search, etc.).
  final ClipboardHistoryNotifier clipboardHistoryNotifier;

  /// Focus node shared with TerminalView's hidden TextField for keyboard toggle.
  final FocusNode keyboardFocusNode;

  /// Autocomplete/suggestion toggle state, shared with TerminalView to
  /// control `enableSuggestions` and `autocorrect` on the hidden TextField.
  final ValueNotifier<bool> autocompleteActiveNotifier;

  /// Callback for pasting clipboard text (wraps in bracketed paste mode).
  final ValueChanged<String> onPaste;

  const ModifierBar({
    super.key,
    required this.onInput,
    required this.ctrlActiveNotifier,
    required this.clipboardHistoryState,
    required this.clipboardHistoryNotifier,
    required this.keyboardFocusNode,
    required this.autocompleteActiveNotifier,
    required this.onPaste,
  });

  @override
  State<ModifierBar> createState() => _ModifierBarState();
}

class _ModifierBarState extends State<ModifierBar> {
  /// Ctrl modifier state: inactive, sticky (single tap), locked (double tap).
  _CtrlState _ctrlState = _CtrlState.inactive;
  DateTime? _lastCtrlTap;

  @override
  void initState() {
    super.initState();
    // Listen for external Ctrl releases (e.g., terminal view consumed Ctrl+key).
    widget.ctrlActiveNotifier.addListener(_onExternalCtrlChange);
  }

  @override
  void dispose() {
    widget.ctrlActiveNotifier.removeListener(_onExternalCtrlChange);
    super.dispose();
  }

  void _onExternalCtrlChange() {
    if (!widget.ctrlActiveNotifier.value && _ctrlState != _CtrlState.inactive) {
      setState(() => _ctrlState = _CtrlState.inactive);
    }
  }

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
      widget.ctrlActiveNotifier.value = _ctrlState != _CtrlState.inactive;
    });
  }

  void _onInput(String data) {
    widget.onInput(data);
    // Auto-release sticky ctrl after consuming an input
    if (_ctrlState == _CtrlState.sticky) {
      setState(() {
        _ctrlState = _CtrlState.inactive;
        widget.ctrlActiveNotifier.value = false;
      });
    }
  }

  void _onEsc() {
    HapticFeedback.mediumImpact();
    widget.onInput('\x1b');
  }

  void _onTab() {
    HapticFeedback.lightImpact();
    widget.onInput('\t');
  }

  void _onShowClipboard() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ClipboardHistorySheet(
        notifier: widget.clipboardHistoryNotifier,
        historyState: widget.clipboardHistoryState,
        onPaste: (text) {
          // Sheet's _pasteAndDismiss handles Navigator.pop — don't pop here.
          widget.onPaste(text);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      height: 86, // two rows + right column (joystick 50 + gap 4 + return 22 + padding 10)
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
              // Left zone: two rows of tool buttons
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Row 1: esc+tab+ctrl | spacer
                    Row(
                      children: [
                        _KeyGroupCapsule(
                          ctrlState: _ctrlState,
                          onEsc: _onEsc,
                          onTab: _onTab,
                          onCtrl: _onCtrlTap,
                        ),
                        const Spacer(),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Row 2: symbol capsule | spacer | clipboard
                    Row(
                      children: [
                        // Symbols bypass Ctrl — use widget.onInput directly
                        SymbolCapsule(onInput: widget.onInput),
                        const Spacer(),
                        ClipboardButton(
                          historyState: widget.clipboardHistoryState,
                          onTap: _onShowClipboard,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Center-right: voice (top) + keyboard (bottom)
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const VoiceButton(),
                  const SizedBox(height: 4),
                  KeyboardButton(
                    keyboardFocusNode: widget.keyboardFocusNode,
                    autocompleteActiveNotifier:
                        widget.autocompleteActiveNotifier,
                  ),
                ],
              ),

              // Vertical divider before right column
              Container(
                width: 1,
                height: 56,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: c.border,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),

              // Right column: joystick (50px) + return (22px), vertically centered
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  JoystickButton(
                    onInput: _onInput,
                    ctrlActive: _ctrlState != _CtrlState.inactive,
                  ),
                  const SizedBox(height: 4),
                  _ReturnKey(onTap: () {
                    HapticFeedback.mediumImpact();
                    widget.onInput('\r');
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _CtrlState { inactive, sticky, locked }

/// Esc + Tab + Ctrl paired capsule. Three keys in a connected group.
class _KeyGroupCapsule extends StatelessWidget {
  final _CtrlState ctrlState;
  final VoidCallback onEsc;
  final VoidCallback onTab;
  final VoidCallback onCtrl;

  const _KeyGroupCapsule({
    required this.ctrlState,
    required this.onEsc,
    required this.onTab,
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
            position: _KeyPosition.first,
            onTap: onEsc,
          ),
          SizedBox(width: 1, height: 34, child: ColoredBox(color: c.border)),
          _GroupedKey(
            label: 'tab',
            isActive: false,
            isLocked: false,
            position: _KeyPosition.middle,
            onTap: onTab,
          ),
          SizedBox(width: 1, height: 34, child: ColoredBox(color: c.border)),
          _GroupedKey(
            label: 'ctrl',
            isActive: ctrlState != _CtrlState.inactive,
            isLocked: ctrlState == _CtrlState.locked,
            position: _KeyPosition.last,
            onTap: onCtrl,
          ),
        ],
      ),
    );
  }
}

enum _KeyPosition { first, middle, last }

/// Individual key within the esc+tab+ctrl capsule.
class _GroupedKey extends StatefulWidget {
  final String label;
  final bool isActive;
  final bool isLocked;
  final _KeyPosition position;
  final VoidCallback onTap;

  const _GroupedKey({
    required this.label,
    required this.isActive,
    required this.isLocked,
    required this.position,
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
              borderRadius: switch (widget.position) {
                _KeyPosition.first => const BorderRadius.horizontal(left: Radius.circular(10)),
                _KeyPosition.middle => BorderRadius.zero,
                _KeyPosition.last => const BorderRadius.horizontal(right: Radius.circular(10)),
              },
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
          width: 50,
          height: 22,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: const Alignment(-0.5, -1),
              end: const Alignment(0.5, 1),
              colors: [c.returnGradientStart, c.returnGradientEnd],
            ),
            borderRadius: BorderRadius.circular(8),
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
              fontSize: 8,
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
