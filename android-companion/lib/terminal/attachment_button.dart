/// Attachment (+) button for the modifier bar tools grid.
///
/// Renders a 36px circular button with a (+) icon. Tapping opens a spring-
/// animated action sheet popover with Photos and Files placeholder options.
/// Both options are non-functional placeholders for now.
///
/// The action sheet is 170px wide with a 12px border radius and appears above
/// the button with a spring entry animation.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colors.dart';

/// A 36px circular (+) button that opens an attachment action sheet.
///
/// Inputs:
///   None — both action sheet options are non-functional placeholders.
///
/// The action sheet popover appears above the button on tap, with a spring
/// animation (overshoot curve). Tapping outside or selecting an option
/// dismisses it.
class AttachmentButton extends StatefulWidget {
  const AttachmentButton({super.key});

  @override
  State<AttachmentButton> createState() => _AttachmentButtonState();
}

class _AttachmentButtonState extends State<AttachmentButton>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  bool _sheetOpen = false;
  late final AnimationController _sheetController;
  late final Animation<double> _sheetScale;
  late final Animation<double> _sheetOpacity;

  @override
  void initState() {
    super.initState();
    _sheetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 120),
    );
    _sheetScale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(
        parent: _sheetController,
        curve: const Cubic(0.34, 1.56, 0.64, 1), // bouncy spring
        reverseCurve: Curves.easeIn,
      ),
    );
    _sheetOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _sheetController,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
    );
  }

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  void _toggleSheet() {
    HapticFeedback.lightImpact();
    if (_sheetOpen) {
      _closeSheet();
    } else {
      setState(() => _sheetOpen = true);
      _sheetController.forward();
    }
  }

  void _closeSheet() {
    _sheetController.reverse().then((_) {
      if (mounted) setState(() => _sheetOpen = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // The (+) button.
        GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) {
            setState(() => _pressed = false);
            _toggleSheet();
          },
          onTapCancel: () => setState(() => _pressed = false),
          child: Semantics(
            label: 'Add attachment',
            button: true,
            child: AnimatedScale(
              scale: _pressed ? 0.92 : 1.0,
              duration: const Duration(milliseconds: 80),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.keyGroupResting,
                ),
                child: Center(
                  child: Icon(
                    Icons.add_rounded,
                    size: 18,
                    color: c.keyGroupText,
                  ),
                ),
              ),
            ),
          ),
        ),

        // Action sheet popover (positioned above the button).
        if (_sheetOpen) ...[
          // Backdrop to catch taps outside.
          Positioned.fill(
            left: -200,
            right: -200,
            top: -400,
            bottom: -200,
            child: GestureDetector(
              onTap: _closeSheet,
              behavior: HitTestBehavior.translucent,
              child: const SizedBox.expand(),
            ),
          ),
          // The sheet itself.
          Positioned(
            bottom: 44, // above the button with 8px gap
            left: -67, // center the 170px sheet on the 36px button
            child: AnimatedBuilder(
              animation: _sheetController,
              builder: (context, child) {
                return Opacity(
                  opacity: _sheetOpacity.value,
                  child: Transform.scale(
                    scale: _sheetScale.value,
                    alignment: Alignment.bottomCenter,
                    child: child,
                  ),
                );
              },
              child: _ActionSheet(
                onPhotos: _closeSheet,
                onFiles: _closeSheet,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Action sheet popover with Photos and Files options.
class _ActionSheet extends StatelessWidget {
  final VoidCallback onPhotos;
  final VoidCallback onFiles;

  const _ActionSheet({
    required this.onPhotos,
    required this.onFiles,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      width: 170,
      decoration: BoxDecoration(
        color: c.fanPopoverBg,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(128),
            blurRadius: 36,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: c.border,
            blurRadius: 0,
            spreadRadius: 1,
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionSheetItem(
            icon: Icons.photo_library_outlined,
            label: 'Photos',
            onTap: onPhotos,
          ),
          Container(
            height: 1,
            color: c.border,
          ),
          _ActionSheetItem(
            icon: Icons.folder_outlined,
            label: 'Files',
            onTap: onFiles,
          ),
        ],
      ),
    );
  }
}

/// Single action sheet item row.
class _ActionSheetItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionSheetItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(icon, size: 16, color: c.textMuted),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
