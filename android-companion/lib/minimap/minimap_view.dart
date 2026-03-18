/// Full-screen minimap overlay showing the workspace pane layout.
///
/// Triggered by pinch-out gesture on the terminal area. Shows a
/// proportional representation of all panes from `workspace.layout`.
/// Tapping a pane dismisses the minimap and focuses that pane's surface.
///
/// Features:
/// - Dot grid background pattern
/// - Workspace name + LIVE badge header
/// - Optional branch badge
/// - 16:10 aspect ratio pane layout container
/// - Hint text with usage instructions
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';
import '../app/theme.dart';
import '../state/pane_provider.dart';
import 'minimap_pane.dart';

class MinimapView extends StatefulWidget {
  final List<Pane> panes;
  final String? focusedPaneId;
  final ValueChanged<String> onPaneTapped;
  final VoidCallback onDismiss;

  /// Display name for the current workspace (shown in header).
  final String? workspaceName;

  /// Git branch name for the current workspace (shown as badge).
  final String? workspaceBranch;

  const MinimapView({
    super.key,
    required this.panes,
    this.focusedPaneId,
    required this.onPaneTapped,
    required this.onDismiss,
    this.workspaceName,
    this.workspaceBranch,
  });

  @override
  State<MinimapView> createState() => _MinimapViewState();
}

class _MinimapViewState extends State<MinimapView>
    with TickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();

    // Entry/exit fade + scale animation
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _scaleAnim = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward();

    // Pulsing green dot for LIVE badge (2-second cycle, 0.4..1.0 opacity)
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _animController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _dismiss() async {
    await _animController.reverse();
    widget.onDismiss();
  }

  void _onPaneTap(String paneId) async {
    await _animController.reverse();
    widget.onPaneTapped(paneId);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return FadeTransition(
      opacity: _fadeAnim,
      child: GestureDetector(
        onTap: _dismiss,
        child: CustomPaint(
          painter: _DotGridPainter(
            dotColor: c.textMuted.withAlpha(38), // ~15% alpha
            backgroundColor: c.bgPrimary.withAlpha(230),
          ),
          child: Center(
            child: ScaleTransition(
              scale: _scaleAnim,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Section header label
                    Text(
                      'WORKSPACE',
                      style: AppTheme.sectionHeader(c),
                    ),
                    const SizedBox(height: 8),

                    // Workspace name
                    Text(
                      widget.workspaceName ?? 'Workspace',
                      style: AppTheme.headingLarge(c),
                    ),
                    const SizedBox(height: 8),

                    // LIVE badge + optional branch badge
                    _buildBadgeRow(c),
                    const SizedBox(height: 20),

                    // Pane layout area (16:10 aspect ratio, capped width
                    // so the container height stays reasonable on wide screens)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: AspectRatio(
                        aspectRatio: 16 / 10,
                      child: Container(
                        decoration: BoxDecoration(
                          color: c.bgElevated,
                          borderRadius: BorderRadius.circular(
                            AppColors.radiusMd,
                          ),
                          border: Border.all(color: c.border),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final size = Size(
                              constraints.maxWidth,
                              constraints.maxHeight,
                            );

                            if (widget.panes.isEmpty) {
                              return Center(
                                child: Text(
                                  'No panes',
                                  style: TextStyle(
                                    color: c.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                              );
                            }

                            return Stack(
                              children: widget.panes.map((pane) {
                                return MinimapPane(
                                  pane: pane,
                                  containerSize: size,
                                  onTap: () {
                                    if (pane.surfaceId != null) {
                                      _onPaneTap(pane.id);
                                    }
                                  },
                                );
                              }).toList(),
                            );
                          },
                        ),
                      ),
                    ),
                    ),

                    const SizedBox(height: 12),

                    // Hint text
                    Text(
                      'Tap a pane to focus \u00b7 Pinch in to dismiss',
                      style: TextStyle(
                        fontSize: 11,
                        color: c.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds the row containing the LIVE badge and optional branch badge.
  Widget _buildBadgeRow(AppColorScheme c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // LIVE badge: pulsing green dot + "LIVE" label
        _buildLiveBadge(c),

        // Branch badge (if branch name is available)
        if (widget.workspaceBranch != null) ...[
          const SizedBox(width: 10),
          _buildBranchBadge(c, widget.workspaceBranch!),
        ],
      ],
    );
  }

  /// Pulsing green dot with "LIVE" text.
  Widget _buildLiveBadge(AppColorScheme c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Pulsing green dot with glow
        AnimatedBuilder(
          animation: _pulseAnim,
          builder: (context, child) {
            return Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: c.connectedColor.withAlpha(
                  (_pulseAnim.value * 255).round(),
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: c.connectedColor.withAlpha(
                      (_pulseAnim.value * 80).round(),
                    ),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(width: 5),
        Text(
          'LIVE',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: c.connectedColor,
          ),
        ),
      ],
    );
  }

  /// Rounded branch name badge using IBM Plex Mono.
  Widget _buildBranchBadge(AppColorScheme c, String branch) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.accentGlow,
        borderRadius: BorderRadius.circular(AppColors.radiusXs),
      ),
      child: Text(
        branch,
        style: AppTheme.monoSmall(c).copyWith(
          fontSize: 10.5,
          color: c.accentText,
        ),
      ),
    );
  }
}

/// Paints a subtle dot grid pattern across the entire overlay background.
///
/// Each dot is 1px diameter (0.5 radius), placed on a regular grid.
/// The background color fills the entire canvas first so the dot grid
/// sits on top of a semi-transparent overlay.
class _DotGridPainter extends CustomPainter {
  final Color dotColor;
  final Color backgroundColor;
  final double spacing;

  _DotGridPainter({
    required this.dotColor,
    required this.backgroundColor,
    this.spacing = 20,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Fill background first
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = backgroundColor,
    );

    // Draw dot grid
    final dotPaint = Paint()
      ..color = dotColor
      ..style = PaintingStyle.fill;

    for (double x = 0; x < size.width; x += spacing) {
      for (double y = 0; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 0.5, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter old) =>
      dotColor != old.dotColor || backgroundColor != old.backgroundColor;
}
