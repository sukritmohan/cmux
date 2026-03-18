/// Pane type dropdown anchored to the right side of the top bar.
///
/// Shows available pane types (Terminal, Browser, Files, Shell) with
/// the active type highlighted. Non-terminal types show "Coming soon".
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';

/// Available pane types and their visual properties.
enum PaneType {
  terminal(icon: Icons.terminal, label: 'Terminal', color: AppColors.accentGreen),
  browser(icon: Icons.language, label: 'Browser', color: AppColors.accentBlue),
  files(icon: Icons.folder_outlined, label: 'Files', color: AppColors.accentOrange),
  shell(icon: Icons.code, label: 'Shell', color: AppColors.accentPurple);

  final IconData icon;
  final String label;
  final Color color;

  const PaneType({required this.icon, required this.label, required this.color});
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
        return Stack(
          children: [
            // Scrim — tap to dismiss
            GestureDetector(
              onTap: _removeOverlay,
              child: Container(color: Colors.transparent),
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
                      color: AppColors.bgSecondary,
                      borderRadius: BorderRadius.circular(AppColors.radiusMd),
                      border: Border.all(color: AppColors.borderSubtle),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(80),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: PaneType.values.map((type) {
                        final isActive = type == widget.activeType;
                        final isAvailable = type == PaneType.terminal;

                        return GestureDetector(
                          onTap: isAvailable ? () => _selectType(type) : null,
                          child: Container(
                            height: 44,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? AppColors.chipBg
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(
                                AppColors.radiusSm,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  type.icon,
                                  size: 16,
                                  color: isAvailable
                                      ? type.color
                                      : AppColors.textMuted,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    type.label,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isActive
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: isAvailable
                                          ? AppColors.textPrimary
                                          : AppColors.textMuted,
                                    ),
                                  ),
                                ),
                                if (isActive)
                                  const Icon(
                                    Icons.check,
                                    size: 16,
                                    color: AppColors.accentBlue,
                                  )
                                else if (!isAvailable)
                                  const Text(
                                    'Soon',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: AppColors.textMuted,
                                    ),
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
    return CompositedTransformTarget(
      link: _layerLink,
      child: GestureDetector(
        onTap: _toggleDropdown,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          height: 40,
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.activeType.icon, size: 14, color: widget.activeType.color),
              const SizedBox(width: 4),
              Text(
                widget.activeType.label,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.expand_more, size: 14, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
