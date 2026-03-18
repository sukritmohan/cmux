/// Pane type dropdown anchored to the right side of the top bar.
///
/// Shows available pane types (Terminal, Browser, Files, Overview) with
/// the active type highlighted. Dropdown: 200px wide, 14px radius,
/// colored icon + label + checkmark per item.
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';

/// Available pane types and their visual properties.
enum PaneType {
  terminal(icon: Icons.terminal, label: 'Terminal'),
  browser(icon: Icons.language, label: 'Browser'),
  files(icon: Icons.folder_outlined, label: 'Files'),
  overview(icon: Icons.grid_view_rounded, label: 'Overview');

  final IconData icon;
  final String label;

  const PaneType({required this.icon, required this.label});

  /// Returns the type-specific color from the current theme's color scheme.
  Color color(AppColorScheme c) => switch (this) {
        PaneType.terminal => c.terminalColor,
        PaneType.browser => c.browserColor,
        PaneType.files => c.filesColor,
        PaneType.overview => c.overviewColor,
      };

  /// Returns the type-specific tinted background from the color scheme.
  Color bgColor(AppColorScheme c) => switch (this) {
        PaneType.terminal => c.terminalBg,
        PaneType.browser => c.browserBg,
        PaneType.files => c.filesBg,
        PaneType.overview => c.overviewBg,
      };
}

class PaneTypeDropdown extends StatefulWidget {
  final PaneType activeType;
  final ValueChanged<PaneType>? onTypeSelected;

  const PaneTypeDropdown({
    super.key,
    this.activeType = PaneType.terminal,
    this.onTypeSelected,
  });

  @override
  State<PaneTypeDropdown> createState() => _PaneTypeDropdownState();
}

class _PaneTypeDropdownState extends State<PaneTypeDropdown>
    with SingleTickerProviderStateMixin {
  final _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  late final AnimationController _animController;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scaleAnim = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _removeOverlay();
    _animController.dispose();
    super.dispose();
  }

  void _toggleDropdown() {
    if (_overlayEntry != null) {
      _removeOverlay();
    } else {
      _showDropdown();
    }
  }

  void _showDropdown() {
    _overlayEntry = _createOverlay();
    Overlay.of(context).insert(_overlayEntry!);
    _animController.forward(from: 0);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _selectType(PaneType type) {
    _removeOverlay();
    widget.onTypeSelected?.call(type);
  }

  OverlayEntry _createOverlay() {
    return OverlayEntry(
      builder: (context) {
        final c = AppColors.of(context);

        return Stack(
          children: [
            // Scrim — tap to dismiss
            GestureDetector(
              onTap: _removeOverlay,
              child: Container(
                color: c.drawerScrim,
              ),
            ),

            // Dropdown menu
            CompositedTransformFollower(
              link: _layerLink,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 4),
              child: ScaleTransition(
                scale: _scaleAnim,
                alignment: Alignment.topRight,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: 200,
                    decoration: BoxDecoration(
                      color: c.bgElevated,
                      borderRadius: BorderRadius.circular(AppColors.radiusLg),
                      border: Border.all(color: c.borderStrong),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(80),
                          blurRadius: 48,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: PaneType.values.map((type) {
                        final isActive = type == widget.activeType;

                        return GestureDetector(
                          onTap: () => _selectType(type),
                          child: Container(
                            height: 44,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? c.bgSurface
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(
                                AppColors.radiusMd,
                              ),
                            ),
                            child: Row(
                              children: [
                                // Active indicator bar
                                if (isActive)
                                  Container(
                                    width: 3,
                                    height: 18,
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                      color: c.accent,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),

                                // Type icon with colored background
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: type.bgColor(c),
                                    borderRadius: BorderRadius.circular(
                                      AppColors.radiusSm,
                                    ),
                                  ),
                                  child: Icon(
                                    type.icon,
                                    size: 14,
                                    color: type.color(c),
                                  ),
                                ),
                                const SizedBox(width: 10),

                                // Label
                                Expanded(
                                  child: Text(
                                    type.label,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isActive
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: isActive
                                          ? c.textPrimary
                                          : c.textSecondary,
                                    ),
                                  ),
                                ),

                                // Checkmark for active item
                                if (isActive)
                                  Icon(
                                    Icons.check,
                                    size: 16,
                                    color: c.accentText,
                                  ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final typeColor = widget.activeType.color(c);

    return CompositedTransformTarget(
      link: _layerLink,
      child: GestureDetector(
        onTap: _toggleDropdown,
        child: Container(
          width: 36,
          height: 36,
          margin: const EdgeInsets.only(right: 10),
          decoration: BoxDecoration(
            color: widget.activeType.bgColor(c),
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
          ),
          child: Icon(widget.activeType.icon, size: 16, color: typeColor),
        ),
      ),
    );
  }
}
