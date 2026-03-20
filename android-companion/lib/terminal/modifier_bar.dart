/// Floating capsule modifier toolbar — three-section layout.
///
/// Layout (flex row):
///   [Left: Keys flex:1] | [Middle: Tools 2×2 grid] | [Right: Nav+Submit flex:1]
///
///   Left:                   Middle:                      Right:
///     Row 1: esc|tab|ctrl     [+attach]   [clipboard]     [joystick] [RETURN]
///     Row 2: ~ | / | -       [keyboard]  [voice]
///
/// Three sections separated by two 56px-tall vertical dividers.
/// Left and right both flex:1 — middle grid stays perfectly centered.
/// Middle is a fixed-width 2×2 grid (36px cells, 4px gap = 76px total).
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
                    // Row 1: esc|tab|ctrl pill (36px tall, flex:1 per key)
                    _KeyGroupCapsule(
                      ctrlState: _ctrlState,
                      onEsc: _onEsc,
                      onTab: _onTab,
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
                        KeyboardButton(           // bottom-left
                          keyboardFocusNode: widget.keyboardFocusNode,
                          autocompleteActiveNotifier:
                              widget.autocompleteActiveNotifier,
                        ),
                        const SizedBox(width: 4),
                        VoiceButton(),            // bottom-right
                      ],
                    ),
                  ],
                ),
              ),

              // DIVIDER 2
              _SectionDivider(),

              // RIGHT: Nav + Submit (flex: 1, right-aligned)
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    JoystickButton(   // 44px circle
                      onInput: _onInput,
                      ctrlActive: _ctrlState != _CtrlState.inactive,
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
/// Stretches to fill parent width; each key uses flex:1 for equal distribution.
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
      height: 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: c.keyGroupResting.withAlpha(10), // capsule background tint
      ),
      child: Row(
        children: [
          Expanded(
            child: _GroupedKey(
              label: 'esc',
              isActive: false,
              isLocked: false,
              position: _KeyPosition.first,
              onTap: onEsc,
            ),
          ),
          SizedBox(width: 1, height: 36, child: ColoredBox(color: c.border)),
          Expanded(
            child: _GroupedKey(
              label: 'tab',
              isActive: false,
              isLocked: false,
              position: _KeyPosition.middle,
              onTap: onTab,
            ),
          ),
          SizedBox(width: 1, height: 36, child: ColoredBox(color: c.border)),
          Expanded(
            child: _GroupedKey(
              label: 'ctrl',
              isActive: ctrlState != _CtrlState.inactive,
              isLocked: ctrlState == _CtrlState.locked,
              position: _KeyPosition.last,
              onTap: onCtrl,
            ),
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
            height: 36,
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

/// Return key with warm amber gradient — 44px tall, 72px min-width.
/// Shows a spinner instead of "RETURN" text when uploading attachments.
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
          constraints: const BoxConstraints(minWidth: 72),
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
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
                  'RETURN',
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: c.returnText,
                  ),
                ),
        ),
      ),
    );
  }
}
