/// A single pane tile within the minimap overlay.
///
/// Shows a proportionally-sized card representing one pane in the
/// workspace layout. Features:
/// - Type-color dot + IBM Plex Mono title
/// - Mock text body placeholder
/// - Amber border + glow for focused panes
/// - Stacked card layers for panes with surfaceCount > 1
/// - Stack count badge (amber circle, top-right)
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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

  /// Returns the type-specific accent color for the pane dot indicator.
  Color _typeColor(AppColorScheme c) {
    switch (pane.type) {
      case 'terminal':
        return c.terminalColor;
      case 'browser':
        return c.browserColor;
      case 'files':
        return c.filesColor;
      default:
        return c.textMuted;
    }
  }

  /// Capitalizes the first letter of the pane type for the title label.
  String get _typeLabel {
    if (pane.type.isEmpty) return 'Pane';
    return pane.type[0].toUpperCase() + pane.type.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    final left = pane.x * containerSize.width;
    final top = pane.y * containerSize.height;
    final width = pane.width * containerSize.width;
    final height = pane.height * containerSize.height;

    // Clamp dimensions to prevent negative values from margin subtraction
    final cardWidth = (width - 4).clamp(0.0, containerSize.width);
    final cardHeight = (height - 4).clamp(0.0, containerSize.height);

    final hasStack = pane.surfaceCount > 1;

    return Positioned(
      left: left + 2, // 2px inner margin
      top: top + 2,
      width: cardWidth,
      height: cardHeight,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Pseudo-layers behind the main card for stacked effect
            if (hasStack) ...[
              // Deepest layer (offset -8px)
              Positioned(
                left: 0,
                right: 0,
                top: -8,
                bottom: 8,
                child: Container(
                  decoration: BoxDecoration(
                    color: c.bgSurface,
                    borderRadius: BorderRadius.circular(AppColors.radiusSm),
                    border: Border.all(color: c.border, width: 0.5),
                  ),
                ),
              ),
              // Middle layer (offset -4px)
              Positioned(
                left: 0,
                right: 0,
                top: -4,
                bottom: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: c.bgSurface,
                    borderRadius: BorderRadius.circular(AppColors.radiusSm),
                    border: Border.all(color: c.border, width: 0.5),
                  ),
                ),
              ),
            ],

            // Main card
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: c.bgElevated,
                  borderRadius: BorderRadius.circular(AppColors.radiusSm),
                  border: Border.all(
                    color: pane.focused ? c.accent : c.border,
                    width: pane.focused ? 1.5 : 1,
                  ),
                  boxShadow: pane.focused
                      ? [
                          BoxShadow(
                            color: c.accent.withAlpha(40),
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
                    // Header row: type-color dot + title
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: _typeColor(c),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _typeLabel,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.ibmPlexMono(
                              fontSize: 9,
                              fontWeight: FontWeight.w500,
                              color: c.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),

                    // Mock text body (placeholder lines)
                    Expanded(
                      child: Text(
                        'lorem ipsum dolor sit\namet consectetur\nadipiscing elit',
                        style: TextStyle(
                          fontSize: 8,
                          fontFamily: 'monospace',
                          color: c.textMuted.withAlpha(128), // 50% alpha
                          height: 1.3,
                        ),
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Stack count badge (top-right, only for surfaceCount > 1)
            if (hasStack)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: c.accent,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${pane.surfaceCount}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
