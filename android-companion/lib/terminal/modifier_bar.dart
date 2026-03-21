/// Floating capsule modifier toolbar — four-section layout.
///
/// Layout (flex row):
///   [Left: Keys flex:1] | [Middle: Tools 2×2] [Voice pill] | [Right: Nav+Submit flex:1]
///
///   Left:                   Middle:           Voice:    Right:
///     Row 1: esc|⇥|⇧|⌃     [+attach] [clip]  [MIC]    [joystick] [RETURN]
///     Row 2: ~ | / | -      [⌫bksp]  [kbd]   [pill]
///                                              [76px]
///
/// Three sections separated by two 56px-tall vertical dividers.
/// Voice mic is a 44×76px full-height pill between the tools grid and right divider.
/// Left and right both flex:1. Middle is a fixed-width 2×2 grid (76px).
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';
import 'attachment_button.dart';
import 'attachment_service.dart';
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

  /// Notifier for Shift modifier state, so the terminal view can apply
  /// Shift to soft keyboard input (e.g., uppercasing characters).
  final ValueNotifier<bool> shiftActiveNotifier;

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

  /// Submit handler that intercepts RETURN when attachments are staged.
  final VoidCallback onSubmit;

  /// Whether an upload is currently in progress (disables input, shows spinner).
  final bool isUploading;

  /// Current attachment state for threading isAtLimit to the (+) button.
  final AttachmentState attachmentState;

  const ModifierBar({
    super.key,
    required this.onInput,
    required this.onSubmit,
    required this.isUploading,
    required this.attachmentState,
    required this.ctrlActiveNotifier,
    required this.shiftActiveNotifier,
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
  _ModifierState _ctrlState = _ModifierState.inactive;
  DateTime? _lastCtrlTap;

  /// Shift modifier state: same sticky/locked pattern as Ctrl.
  _ModifierState _shiftState = _ModifierState.inactive;
  DateTime? _lastShiftTap;

  @override
  void initState() {
    super.initState();
    // Listen for external Ctrl releases (e.g., terminal view consumed Ctrl+key).
    widget.ctrlActiveNotifier.addListener(_onExternalCtrlChange);
    widget.shiftActiveNotifier.addListener(_onExternalShiftChange);
  }

  @override
  void dispose() {
    widget.ctrlActiveNotifier.removeListener(_onExternalCtrlChange);
    widget.shiftActiveNotifier.removeListener(_onExternalShiftChange);
    super.dispose();
  }

  void _onExternalCtrlChange() {
    if (!widget.ctrlActiveNotifier.value && _ctrlState != _ModifierState.inactive) {
      setState(() => _ctrlState = _ModifierState.inactive);
    }
  }

  void _onExternalShiftChange() {
    if (!widget.shiftActiveNotifier.value && _shiftState != _ModifierState.inactive) {
      setState(() => _shiftState = _ModifierState.inactive);
    }
  }

  void _onCtrlTap() {
    HapticFeedback.selectionClick();
    final now = DateTime.now();
    final isDoubleTap = _lastCtrlTap != null &&
        now.difference(_lastCtrlTap!) < const Duration(milliseconds: 400);
    _lastCtrlTap = now;

    setState(() {
      if (isDoubleTap && _ctrlState == _ModifierState.sticky) {
        _ctrlState = _ModifierState.locked;
      } else if (_ctrlState != _ModifierState.inactive) {
        _ctrlState = _ModifierState.inactive;
      } else {
        _ctrlState = _ModifierState.sticky;
      }
      widget.ctrlActiveNotifier.value = _ctrlState != _ModifierState.inactive;
    });
  }

  void _onShiftTap() {
    HapticFeedback.selectionClick();
    final now = DateTime.now();
    final isDoubleTap = _lastShiftTap != null &&
        now.difference(_lastShiftTap!) < const Duration(milliseconds: 400);
    _lastShiftTap = now;

    setState(() {
      if (isDoubleTap && _shiftState == _ModifierState.sticky) {
        _shiftState = _ModifierState.locked;
      } else if (_shiftState != _ModifierState.inactive) {
        _shiftState = _ModifierState.inactive;
      } else {
        _shiftState = _ModifierState.sticky;
      }
      widget.shiftActiveNotifier.value = _shiftState != _ModifierState.inactive;
    });
  }

  void _onInput(String data) {
    widget.onInput(data);
    // Auto-release sticky modifiers after consuming an input
    if (_ctrlState == _ModifierState.sticky) {
      setState(() {
        _ctrlState = _ModifierState.inactive;
        widget.ctrlActiveNotifier.value = false;
      });
    }
    if (_shiftState == _ModifierState.sticky) {
      setState(() {
        _shiftState = _ModifierState.inactive;
        widget.shiftActiveNotifier.value = false;
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

  void _onBackspace() {
    HapticFeedback.selectionClick();
    // Ctrl+Backspace sends Ctrl+W (delete word backward).
    if (_ctrlState != _ModifierState.inactive) {
      _onInput('\x17'); // Ctrl+W
    } else {
      widget.onInput('\x7f'); // DEL
    }
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
      height: 88, // two 36px rows + 4px gap + 12px vertical padding
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: c.modifierBarBg,
      ),
      clipBehavior: Clip.hardEdge,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              // LEFT: Terminal key pills (flex: 1)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Row 1: esc|⇥|⇧|⌃ pill (36px tall, flex:1 per key)
                    _KeyGroupCapsule(
                      ctrlState: _ctrlState,
                      shiftState: _shiftState,
                      onEsc: _onEsc,
                      onTab: _onTab,
                      onShift: _onShiftTap,
                      onCtrl: _onCtrlTap,
                    ),
                    const SizedBox(height: 4),
                    // Row 2: ~|/|- pill (36px tall, flex:1 per key)
                    // Symbols bypass Ctrl — use widget.onInput directly
                    SymbolCapsule(onInput: widget.onInput),
                  ],
                ),
              ),

              // DIVIDER 1 (1px × 56px, margin 0 10px)
              _SectionDivider(),

              // MIDDLE: Tools 2×2 grid (fixed 76px wide)
              SizedBox(
                width: 76, // 36 + 4 + 36
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        AttachmentButton(
                          isDisabled: widget.isUploading || widget.attachmentState.isAtLimit,
                        ), // top-left
                        const SizedBox(width: 4),
                        ClipboardButton(          // top-right
                          historyState: widget.clipboardHistoryState,
                          onTap: _onShowClipboard,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _BackspaceButton(         // bottom-left
                          onBackspace: _onBackspace,
                        ),
                        const SizedBox(width: 4),
                        KeyboardButton(           // bottom-right
                          keyboardFocusNode: widget.keyboardFocusNode,
                          autocompleteActiveNotifier:
                              widget.autocompleteActiveNotifier,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // VOICE: Full-height pill between grid and right section
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: VoiceButton(
                  width: 44,
                  height: 76,
                ),
              ),

              // DIVIDER 2
              _SectionDivider(),

              // RIGHT: Nav + Submit (wraps content, no flex)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  JoystickButton(   // 44px circle
                    onInput: _onInput,
                    ctrlActive: _ctrlState != _ModifierState.inactive,
                  ),
                  const SizedBox(width: 8),
                  _ReturnKey(
                    isUploading: widget.isUploading,
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      widget.onSubmit();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _ModifierState { inactive, sticky, locked }

/// Esc + Tab + Shift + Ctrl capsule. Four keys in a connected group.
/// Labels use symbols: esc (text), ⇥ (tab), ⇧ (shift), ⌃ (ctrl).
/// Stretches to fill parent width; each key uses flex:1 for equal distribution.
class _KeyGroupCapsule extends StatelessWidget {
  final _ModifierState ctrlState;
  final _ModifierState shiftState;
  final VoidCallback onEsc;
  final VoidCallback onTab;
  final VoidCallback onShift;
  final VoidCallback onCtrl;

  const _KeyGroupCapsule({
    required this.ctrlState,
    required this.shiftState,
    required this.onEsc,
    required this.onTab,
    required this.onShift,
    required this.onCtrl,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    // Key definitions: (label, semanticsLabel, isActive, isLocked, onTap, index)
    final keys = [
      ('esc', 'escape', false, false, onEsc),
      ('\u21E5', 'tab', false, false, onTab),
      ('\u21E7', 'shift', shiftState != _ModifierState.inactive, shiftState == _ModifierState.locked, onShift),
      ('\u2303', 'control', ctrlState != _ModifierState.inactive, ctrlState == _ModifierState.locked, onCtrl),
    ];

    return Container(
      height: 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: c.keyGroupResting.withAlpha(10),
      ),
      child: Row(
        children: [
          for (int i = 0; i < keys.length; i++) ...[
            if (i > 0)
              SizedBox(width: 1, height: 36, child: ColoredBox(color: c.border)),
            Expanded(
              child: _GroupedKey(
                label: keys[i].$1,
                semanticsLabel: keys[i].$2,
                isActive: keys[i].$3,
                isLocked: keys[i].$4,
                isFirst: i == 0,
                isLast: i == keys.length - 1,
                onTap: keys[i].$5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Individual key within the modifier capsule.
/// Supports both text labels (esc) and symbol labels (⇥, ⇧, ⌃).
class _GroupedKey extends StatefulWidget {
  final String label;
  final String semanticsLabel;
  final bool isActive;
  final bool isLocked;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;

  const _GroupedKey({
    required this.label,
    required this.semanticsLabel,
    required this.isActive,
    required this.isLocked,
    required this.isFirst,
    required this.isLast,
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

    // Symbol characters (⇥, ⇧, ⌃) render larger than text labels.
    final isSymbol = widget.label.length == 1 && widget.label.codeUnitAt(0) > 0x2000;
    final fontSize = isSymbol ? 14.0 : 10.0;
    final fontWeight = isSymbol ? FontWeight.w500 : FontWeight.w600;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: Semantics(
        label: widget.isActive
            ? '${widget.semanticsLabel}, active${widget.isLocked ? ', locked' : ''}'
            : '${widget.semanticsLabel}, inactive',
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.horizontal(
                left: widget.isFirst ? const Radius.circular(10) : Radius.zero,
                right: widget.isLast ? const Radius.circular(10) : Radius.zero,
              ),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: fontSize,
                    fontWeight: fontWeight,
                    letterSpacing: isSymbol ? 0 : 0.3,
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

/// Subtle vertical divider between the three sections.
class _SectionDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      width: 1,
      height: 56,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.border,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}

/// Backspace button (⌫) for the tools grid.
///
/// Sends DEL (\x7f) on tap. Supports repeat-on-hold: after 300ms initial
/// delay, repeats every 80ms. Respects Ctrl modifier via the [onBackspace]
/// callback (Ctrl+Backspace sends Ctrl+W).
class _BackspaceButton extends StatefulWidget {
  final VoidCallback onBackspace;

  const _BackspaceButton({required this.onBackspace});

  @override
  State<_BackspaceButton> createState() => _BackspaceButtonState();
}

class _BackspaceButtonState extends State<_BackspaceButton> {
  bool _pressed = false;

  /// Timer for repeat-on-hold behavior.
  bool _holding = false;

  void _startRepeat() async {
    _holding = true;
    // Initial delay before repeating.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    while (_holding && mounted) {
      HapticFeedback.lightImpact();
      widget.onBackspace();
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  void _stopRepeat() {
    _holding = false;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        _startRepeat();
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        _stopRepeat();
        widget.onBackspace();
      },
      onTapCancel: () {
        setState(() => _pressed = false);
        _stopRepeat();
      },
      child: Semantics(
        label: 'Backspace',
        button: true,
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: c.keyGroupResting,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.backspace_outlined,
              size: 16,
              color: c.keyGroupText,
            ),
          ),
        ),
      ),
    );
  }
}

/// Return key with warm amber gradient — 44px tall.
/// Shows "RETURN" text on wide screens (>= 600dp), ↩ symbol on narrow screens.
/// Shows a spinner when uploading attachments.
class _ReturnKey extends StatefulWidget {
  final VoidCallback onTap;
  final bool isUploading;

  const _ReturnKey({required this.onTap, this.isUploading = false});

  @override
  State<_ReturnKey> createState() => _ReturnKeyState();
}

class _ReturnKeyState extends State<_ReturnKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isWide = MediaQuery.of(context).size.width >= 600;

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
          constraints: isWide ? const BoxConstraints(minWidth: 72) : null,
          height: 44,
          padding: EdgeInsets.symmetric(horizontal: isWide ? 14 : 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [c.returnGradientStart, c.returnGradientEnd],
            ),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: c.returnGlow,
                blurRadius: 12,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: widget.isUploading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.returnText,
                  ),
                )
              : Text(
                  isWide ? 'RETURN' : '\u21A9',
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: isWide ? 11 : 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: isWide ? 1 : 0,
                    color: c.returnText,
                  ),
                ),
        ),
      ),
    );
  }
}
