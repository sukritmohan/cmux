/// A single pane tile within the minimap overlay.
///
/// Shows a proportionally-sized rectangle representing one pane in the
/// workspace layout. Focused panes have a blue border and glow.
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';
import '../state/pane_provider.dart';

class MinimapPane extends StatelessWidget {
  final Pane pane;
  final Size containerSize;
  final VoidCallback onTap;

  const MinimapPane({
    super.key,
    required this.pane,
    required this.containerSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final left = pane.x * containerSize.width;
    final top = pane.y * containerSize.height;
    final width = pane.width * containerSize.width;
    final height = pane.height * containerSize.height;

    return Positioned(
      left: left + 2, // 2px inner margin
      top: top + 2,
      width: (width - 4).clamp(0, containerSize.width),
      height: (height - 4).clamp(0, containerSize.height),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: pane.focused ? AppColors.chipBgActive : AppColors.bgSurface,
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            border: Border.all(
              color: pane.focused ? AppColors.accentBlue : AppColors.borderSubtle,
              width: pane.focused ? 1.5 : 1,
            ),
            boxShadow: pane.focused
                ? [
                    BoxShadow(
                      color: AppColors.accentBlue.withAlpha(40),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Pane label
              Text(
                pane.type == 'terminal' ? 'Terminal' : pane.type,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 2),

              // Decorative preview text (tiny monospace)
              Expanded(
                child: Text(
                  '\$ _\n\n',
                  style: TextStyle(
                    fontSize: 5,
                    fontFamily: 'monospace',
                    color: AppColors.textMuted.withAlpha(80),
                    height: 1.2,
                  ),
                ),
              ),

              // Tab dots
              if (pane.surfaceId != null)
                Row(
                  children: [
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: pane.focused
                            ? AppColors.accentBlue
                            : AppColors.textMuted,
                        shape: BoxShape.circle,
                      ),
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
