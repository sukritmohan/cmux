/// Fan-out symbol button that reveals ~ | / - on tap.
///
/// Resting state shows a fan icon (three radiating rays).
/// Tap opens a frosted popover above the button with four symbol keys.
/// Tap a symbol to insert it and auto-dismiss.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';

class FanOutButton extends StatefulWidget {
  /// Called with the symbol character to send.
  final ValueChanged<String> onInput;

  const FanOutButton({super.key, required this.onInput});

  @override
  State<FanOutButton> createState() => _FanOutButtonState();
}

class _FanOutButtonState extends State<FanOutButton> {
  bool _isOpen = false;
  bool _pressed = false;
  OverlayEntry? _overlayEntry;

  static const _symbols = ['~', '|', '/', '-'];

  void _toggle() {
    if (_isOpen) {
      _close();
    } else {
      _open();
    }
  }

  void _open() {
    HapticFeedback.lightImpact();
    setState(() => _isOpen = true);

    _overlayEntry = OverlayEntry(
      builder: (context) => _FanPopover(
        anchor: _buttonGlobalRect(),
        symbols: _symbols,
        onSelect: (symbol) {
          HapticFeedback.selectionClick();
          widget.onInput(symbol);
          _close();
        },
        onDismiss: _close,
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _close() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() => _isOpen = false);
  }

  Rect _buttonGlobalRect() {
    final box = context.findRenderObject() as RenderBox;
    final position = box.localToGlobal(Offset.zero);
    return position & box.size;
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        _toggle();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: Semantics(
        label: 'Symbol shortcuts. Tap to open.',
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutExpo,
            width: 38,
            height: 34,
            decoration: BoxDecoration(
              color: _isOpen ? c.fanBtnActive : c.fanBtnResting,
              borderRadius: BorderRadius.circular(10),
            ),
            child: CustomPaint(
              painter: FanIconPainter(
                color: _isOpen ? c.accentText : c.keyGroupText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the fan icon: three rays radiating upward from a base dot.
class FanIconPainter extends CustomPainter {
  final Color color;

  FanIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 + 2);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    const rayLength = 10.0;
    const spreadAngle = 30.0 * 3.14159 / 180; // 30 degrees

    // Three rays from center: -30°, 0°, +30° (measuring from vertical)
    for (final angle in [-spreadAngle, 0.0, spreadAngle]) {
      final endX = center.dx + rayLength * math.sin(angle);
      final endY = center.dy - rayLength * math.cos(angle);
      canvas.drawLine(center, Offset(endX, endY), paint);
    }

    // Base dot
    canvas.drawCircle(
      Offset(center.dx, center.dy + 1),
      1.5,
      Paint()..color = color.withAlpha(150),
    );
  }

  @override
  bool shouldRepaint(FanIconPainter oldDelegate) => color != oldDelegate.color;
}

/// Frosted popover showing symbol keys, positioned above the anchor button.
class _FanPopover extends StatelessWidget {
  final Rect anchor;
  final List<String> symbols;
  final ValueChanged<String> onSelect;
  final VoidCallback onDismiss;

  const _FanPopover({
    required this.anchor,
    required this.symbols,
    required this.onSelect,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    // Popover width: 4 keys * 48px + 3 gaps * 4px + 10px padding = 214px
    const popoverWidth = 214.0;
    const popoverHeight = 52.0;
    const gap = 8.0;

    // Center popover above the anchor button
    final left = anchor.center.dx - popoverWidth / 2;
    final top = anchor.top - popoverHeight - gap;

    return Stack(
      children: [
        // Dismiss scrim (transparent, full screen)
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        // Popover
        Positioned(
          left: left.clamp(8.0, MediaQuery.of(context).size.width - popoverWidth - 8),
          top: top,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: c.fanPopoverBg,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(80),
                      blurRadius: 24,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: symbols.map((s) => Padding(
                    padding: EdgeInsets.only(
                      left: s == symbols.first ? 0 : 4,
                    ),
                    child: _SymbolKey(
                      symbol: s,
                      onTap: () => onSelect(s),
                    ),
                  )).toList(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Individual symbol key inside the fan-out popover.
class _SymbolKey extends StatefulWidget {
  final String symbol;
  final VoidCallback onTap;

  const _SymbolKey({required this.symbol, required this.onTap});

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
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 60),
        child: Container(
          width: 48,
          height: 42,
          decoration: BoxDecoration(
            color: c.symKeyResting,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.symbol,
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
