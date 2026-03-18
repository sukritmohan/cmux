/// Full-screen minimap overlay showing the workspace pane layout.
///
/// Triggered by pinch-out gesture on the terminal area. Shows a
/// proportional representation of all panes from `workspace.layout`.
/// Tapping a pane dismisses the minimap and focuses that pane's surface.
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';
import '../state/pane_provider.dart';
import 'minimap_pane.dart';

class MinimapView extends StatefulWidget {
  final List<Pane> panes;
  final String? focusedPaneId;
  final ValueChanged<String> onPaneTapped;
  final VoidCallback onDismiss;

  const MinimapView({
    super.key,
    required this.panes,
    this.focusedPaneId,
    required this.onPaneTapped,
    required this.onDismiss,
  });

  @override
  State<MinimapView> createState() => _MinimapViewState();
}

class _MinimapViewState extends State<MinimapView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    _animController.dispose();
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
    return FadeTransition(
      opacity: _fadeAnim,
      child: GestureDetector(
        onTap: _dismiss,
        child: Container(
          color: AppColors.bgPrimary.withAlpha(230),
          child: Center(
            child: ScaleTransition(
              scale: _scaleAnim,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Title
                    const Text(
                      'Workspace Layout',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Pane layout area
                    AspectRatio(
                      aspectRatio: 16 / 10,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.bgSecondary,
                          borderRadius: BorderRadius.circular(
                            AppColors.radiusMd,
                          ),
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final size = Size(
                              constraints.maxWidth,
                              constraints.maxHeight,
                            );

                            if (widget.panes.isEmpty) {
                              return const Center(
                                child: Text(
                                  'No panes',
                                  style: TextStyle(
                                    color: AppColors.textMuted,
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

                    const SizedBox(height: 12),

                    // Hint text
                    const Text(
                      'Tap a pane to focus it',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
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
}
