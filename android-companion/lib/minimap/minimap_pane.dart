/// A single pane tile within the minimap overlay.
///
/// Shows a proportionally-sized card representing one pane in the
/// workspace layout. Features:
/// - Type-color dot + IBM Plex Mono title
/// - Live terminal content via colored-block minimap painter
/// - Amber border + glow for focused panes
/// - Stacked card layers for panes with surfaceCount > 1
/// - Stack count badge (amber circle, top-right)
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/colors.dart';
import '../app/providers.dart';
import '../state/pane_provider.dart';
import 'minimap_cell_consumer.dart';
import 'minimap_terminal_painter.dart';

class MinimapPane extends ConsumerStatefulWidget {
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
  ConsumerState<MinimapPane> createState() => _MinimapPaneState();
}

class _MinimapPaneState extends ConsumerState<MinimapPane> {
  MinimapCellConsumer? _consumer;

  @override
  void initState() {
    super.initState();
    _maybeSubscribe();
  }

  @override
  void dispose() {
    _consumer?.dispose();
    super.dispose();
  }

  /// Subscribe to cell stream if this is a terminal pane with a surface.
  void _maybeSubscribe() {
    final pane = widget.pane;
    debugPrint('[MinimapPane] pane=${pane.id} type=${pane.type} surfaceId=${pane.surfaceId}');
    if (pane.surfaceId == null || pane.type != 'terminal') {
      debugPrint('[MinimapPane] Skipping: surfaceId=${pane.surfaceId}, type=${pane.type}');
      return;
    }

    final manager = ref.read(connectionManagerProvider);
    _consumer = MinimapCellConsumer(
      manager: manager,
      surfaceId: pane.surfaceId!,
      onUpdate: () {
        debugPrint('[MinimapPane] onUpdate fired for ${pane.surfaceId}, hasData=${_consumer?.hasData}');
        if (mounted) setState(() {});
      },
    );
    _consumer!.subscribe();
  }

  /// Returns the type-specific accent color for the pane dot indicator.
  Color _typeColor(AppColorScheme c) {
    switch (widget.pane.type) {
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
    if (widget.pane.type.isEmpty) return 'Pane';
    return widget.pane.type[0].toUpperCase() + widget.pane.type.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final pane = widget.pane;

    final left = pane.x * widget.containerSize.width;
    final top = pane.y * widget.containerSize.height;
    final width = pane.width * widget.containerSize.width;
    final height = pane.height * widget.containerSize.height;

    // Clamp dimensions to prevent negative values from margin subtraction
    final cardWidth = (width - 4).clamp(0.0, widget.containerSize.width);
    final cardHeight = (height - 4).clamp(0.0, widget.containerSize.height);

    final hasStack = pane.surfaceCount > 1;

    return Positioned(
      left: left + 2, // 2px inner margin
      top: top + 2,
      width: cardWidth,
      height: cardHeight,
      child: GestureDetector(
        onTap: widget.onTap,
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
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppColors.radiusSm - 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header row: type-color dot + title
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 6, 6, 3),
                        child: Row(
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
                      ),

                      // Body: live terminal content or placeholder
                      Expanded(child: _buildBody(c)),
                    ],
                  ),
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

  /// Builds the pane body content.
  ///
  /// For terminal panes with live data: colored-block minimap painter.
  /// For non-terminal panes or while waiting for first frame: placeholder.
  Widget _buildBody(AppColorScheme c) {
    final consumer = _consumer;
    if (consumer != null && consumer.hasData) {
      return CustomPaint(
        painter: MinimapTerminalPainter(
          cells: consumer.cells,
          cols: consumer.cols,
          rows: consumer.rows,
          defaultBg: c.terminalDefaultBg,
          defaultFg: c.terminalDefaultFg,
        ),
        child: const SizedBox.expand(),
      );
    }

    // Placeholder with debug status for diagnostics.
    final status = consumer?.debugStatus ?? (widget.pane.surfaceId == null ? 'no surfaceId' : 'no consumer');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        status,
        style: TextStyle(
          fontSize: 8,
          fontFamily: 'monospace',
          color: c.textMuted.withAlpha(64),
          height: 1.3,
        ),
        overflow: TextOverflow.clip,
      ),
    );
  }
}
