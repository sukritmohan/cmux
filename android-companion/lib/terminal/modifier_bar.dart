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
