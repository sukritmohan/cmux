/// Horizontal scrollable tab bar strip showing surfaces in the current workspace.
///
/// Spec design (section 7):
/// - Font: IBM Plex Mono 11.5px/500, 0.2px letter spacing
/// - Active tab: textPrimary, bgSurface, amber underline (2px, 8px inset)
/// - Inactive: textMuted
/// - Connection dot: 5px green circle before active tab title
/// - Pane-group dot separators (3px textMuted dots)
/// - Right-edge fade gradient (32px)
/// - (+) button: 28x28, rounded 8px
///
/// When [paneType] is [PaneType.browser], static browser tabs are shown.
///
/// During a horizontal swipe gesture, [swipeProgress] and [swipeTargetIndex]
/// drive a crossfade of the underline indicators: the current tab's underline
/// fades out as the target tab's underline fades in, giving the user clear
/// visual feedback about which tab they are swiping toward.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/colors.dart';
import '../shared/pane_type_dropdown.dart';
import '../state/surface_provider.dart';

/// Static browser tab descriptors for the browser pane.
class _BrowserTab {
  final String title;
  final bool isActive;

  const _BrowserTab({required this.title, required this.isActive});
}

const _staticBrowserTabs = [
  _BrowserTab(title: 'localhost', isActive: true),
  _BrowserTab(title: 'GitHub', isActive: false),
];

/// Minimum swipe progress magnitude before auto-scrolling the tab strip to
/// reveal the target tab. Below this threshold the strip stays put to avoid
/// jitter on light touches.
const _autoScrollThreshold = 0.2;

class TabBarStrip extends StatefulWidget {
  final List<Surface> surfaces;
  final String? focusedSurfaceId;
  final ValueChanged<String> onSurfaceSelected;
  final PaneType? paneType;

  /// Normalised swipe progress in the range [-1.0, 1.0].
  ///
  /// - `0`   → no active swipe (strip renders normally).
  /// - `< 0` → swiping toward the next (right) tab.
  /// - `> 0` → swiping toward the previous (left) tab.
  final double? swipeProgress;

  /// Index of the surface the user is currently swiping toward, or `null` when
  /// there is no active swipe or no valid target in that direction.
  final int? swipeTargetIndex;

  const TabBarStrip({
    super.key,
    required this.surfaces,
    this.focusedSurfaceId,
    required this.onSurfaceSelected,
    this.paneType,
    this.swipeProgress,
    this.swipeTargetIndex,
  });

  @override
  State<TabBarStrip> createState() => _TabBarStripState();
}

class _TabBarStripState extends State<TabBarStrip> {
  /// Controls the horizontal scroll position of the tab list so that when
  /// the target tab is off-screen we can programmatically scroll to reveal it.
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TabBarStrip oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Auto-scroll to reveal the target tab once the swipe exceeds the threshold.
    final progress = widget.swipeProgress;
    final targetIndex = widget.swipeTargetIndex;

    if (progress != null &&
        targetIndex != null &&
        progress.abs() > _autoScrollThreshold &&
        _scrollController.hasClients) {
      _scrollToRevealIndex(targetIndex);
    }
  }

  /// Smoothly scrolls the tab strip so that the tab at [index] is visible.
  ///
  /// Each tab chip has a fixed estimated width used only for the scroll offset
  /// calculation. Actual rendering is not affected by this estimate.
  void _scrollToRevealIndex(int index) {
    // Approximate chip width based on spec padding + typical title width.
    // This only needs to be close enough to land near the target tab; the
    // `ensureVisible` approach via GlobalKeys would be more precise but also
    // much more complex with a ListView.builder.
    const estimatedChipWidth = 90.0;
    const listPaddingLeft = 4.0;

    final targetScrollOffset = listPaddingLeft + index * estimatedChipWidth;
    final viewportWidth = _scrollController.position.viewportDimension;

    // Center the target tab in the viewport when possible.
    final centeredOffset = targetScrollOffset - (viewportWidth / 2) + (estimatedChipWidth / 2);
    final clampedOffset = centeredOffset.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );

    _scrollController.animateTo(
      clampedOffset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.paneType == PaneType.browser) {
      return _buildBrowserTabs(context);
    }
    return _buildSurfaceTabs(context);
  }

  Widget _buildBrowserTabs(BuildContext context) {
    final c = AppColors.of(context);

    return Expanded(
      child: _TabStripWrap(
        child: ListView.builder(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(left: 4),
          itemCount: _staticBrowserTabs.length,
          itemBuilder: (context, index) {
            final tab = _staticBrowserTabs[index];
            return _TabChip(
              title: tab.title,
              icon: Icons.language,
              isActive: tab.isActive,
              accentColor: c.browserColor,
              showConnectionDot: tab.isActive,
              // Browser tabs don't participate in swipe-tab switching.
              underlineOpacity: 1.0,
            );
          },
        ),
      ),
    );
  }

  Widget _buildSurfaceTabs(BuildContext context) {
    final c = AppColors.of(context);

    if (widget.surfaces.isEmpty) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'No tabs',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: c.textMuted,
              ),
            ),
          ),
        ),
      );
    }

    // Determine the index of the currently focused surface so we can modulate
    // its underline opacity during a swipe.
    final focusedIndex = widget.surfaces
        .indexWhere((s) => s.id == widget.focusedSurfaceId);

    final progress = widget.swipeProgress;
    final targetIndex = widget.swipeTargetIndex;

    // Whether a swipe is actively in progress with a valid target.
    final isSwipeActive = progress != null && targetIndex != null;

    return Expanded(
      child: _TabStripWrap(
        child: ListView.builder(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(left: 4),
          itemCount: widget.surfaces.length,
          itemBuilder: (context, index) {
            final surface = widget.surfaces[index];
            final isActive = surface.id == widget.focusedSurfaceId;

            // Compute the underline opacity for this tab:
            // - No active swipe → standard behaviour (active = 1.0, inactive = 0.0).
            // - Active swipe    → crossfade between current and target tabs.
            final double underlineOpacity;
            if (!isSwipeActive || !isActive && index != targetIndex) {
              // Non-participant tab: show its underline only if it is the active tab
              // and there is no swipe, otherwise keep it hidden.
              underlineOpacity = (isActive && !isSwipeActive) ? 1.0 : 0.0;
            } else if (index == focusedIndex) {
              // Current tab: underline fades out as swipe progresses.
              underlineOpacity = 1.0 - progress!.abs();
            } else {
              // Target tab: underline fades in as swipe progresses.
              underlineOpacity = progress!.abs();
            }

            return GestureDetector(
              onTap: () => widget.onSurfaceSelected(surface.id),
              child: _TabChip(
                title: surface.title,
                icon: Icons.terminal,
                isActive: isActive,
                accentColor: c.accent,
                showConnectionDot: isActive && surface.hasRunningProcess,
                underlineOpacity: underlineOpacity,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Wraps the tab strip with a right-edge fade gradient (32px).
class _TabStripWrap extends StatelessWidget {
  final Widget child;

  const _TabStripWrap({required this.child});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Stack(
      children: [
        child,
        // Right-edge fade gradient hinting at scrollability
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 32,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    c.bgPrimary.withAlpha(0),
                    c.bgPrimary,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A single tab chip matching the spec design.
///
/// [underlineOpacity] controls the visibility of the amber underline bar.
/// Pass `1.0` for fully visible (active), `0.0` for hidden (inactive), or
/// an intermediate value during a crossfade swipe animation.
class _TabChip extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isActive;
  final Color accentColor;
  final bool showConnectionDot;

  /// Opacity of the amber underline indicator (0.0–1.0). Interpolated during
  /// swipe gestures to create a crossfade between the current and target tabs.
  final double underlineOpacity;

  const _TabChip({
    required this.title,
    required this.icon,
    required this.isActive,
    required this.accentColor,
    this.showConnectionDot = false,
    this.underlineOpacity = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11),
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: isActive ? c.bgSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Connection dot (5px green circle before active tab title)
              if (showConnectionDot)
                Container(
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: c.connectedColor,
                    shape: BoxShape.circle,
                  ),
                ),

              // Tab title (IBM Plex Mono 11.5px/500)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  title,
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                    color: isActive ? c.textPrimary : c.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          // Amber underline (2px). Visible when underlineOpacity > 0,
          // allowing a crossfade between current and target tabs during swipe.
          if (underlineOpacity > 0.0)
            Opacity(
              opacity: underlineOpacity,
              child: Container(
                height: 2,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(1),
                ),
                // Width set by parent constraints
              ),
            ),
        ],
      ),
    );
  }
}
