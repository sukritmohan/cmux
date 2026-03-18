/// Browser view with URL bar and mock web content area.
///
/// Displays a static URL bar at the top and shimmer-style placeholder blocks
/// that mimic a web page layout (nav bar, content blocks, text lines).
import 'package:flutter/material.dart';

import '../app/colors.dart';
import 'url_bar.dart';

class BrowserView extends StatelessWidget {
  const BrowserView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Column(
      children: [
        // URL bar with mock navigation state
        const UrlBar(
          canGoBack: true,
          canGoForward: false,
          url: MockUrl(
            scheme: 'https://',
            host: 'localhost',
            path: ':3000/dashboard',
          ),
        ),

        // Mock web content area
        Expanded(
          child: Container(
            color: c.bgDeep,
            padding: const EdgeInsets.all(16),
            child: _MockWebContent(),
          ),
        ),
      ],
    );
  }
}

/// Shimmer-style placeholder blocks that mimic a web page layout.
///
/// Renders: a narrow top bar, a few content blocks, and several text lines
/// at varying widths to suggest real page content.
class _MockWebContent extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top nav bar mock
          _ShimmerBlock(
            height: 8,
            widthFraction: 0.70,
            borderRadius: 4,
            color: c.bgSurface,
            marginBottom: 12,
          ),

          // Content blocks (like cards/images)
          _ShimmerBlock(
            height: 40,
            widthFraction: 1.0,
            borderRadius: AppColors.radiusSm,
            color: c.bgElevated,
            marginBottom: 10,
          ),
          _ShimmerBlock(
            height: 40,
            widthFraction: 1.0,
            borderRadius: AppColors.radiusSm,
            color: c.bgElevated,
            marginBottom: 10,
          ),
          _ShimmerBlock(
            height: 40,
            widthFraction: 1.0,
            borderRadius: AppColors.radiusSm,
            color: c.bgElevated,
            marginBottom: 10,
          ),

          const SizedBox(height: 4),

          // Text line mocks (varying widths)
          _ShimmerBlock(
            height: 6,
            widthFraction: 1.0,
            borderRadius: 3,
            color: c.bgSurface,
            marginBottom: 8,
          ),
          _ShimmerBlock(
            height: 6,
            widthFraction: 0.85,
            borderRadius: 3,
            color: c.bgSurface,
            marginBottom: 8,
          ),
          _ShimmerBlock(
            height: 6,
            widthFraction: 0.92,
            borderRadius: 3,
            color: c.bgSurface,
            marginBottom: 8,
          ),
          _ShimmerBlock(
            height: 6,
            widthFraction: 0.78,
            borderRadius: 3,
            color: c.bgSurface,
            marginBottom: 8,
          ),
          _ShimmerBlock(
            height: 6,
            widthFraction: 1.0,
            borderRadius: 3,
            color: c.bgSurface,
            marginBottom: 8,
          ),
          _ShimmerBlock(
            height: 6,
            widthFraction: 0.60,
            borderRadius: 3,
            color: c.bgSurface,
            marginBottom: 8,
          ),
        ],
      ),
    );
  }
}

/// A single rectangular shimmer placeholder block.
class _ShimmerBlock extends StatelessWidget {
  final double height;
  final double widthFraction;
  final double borderRadius;
  final Color color;
  final double marginBottom;

  const _ShimmerBlock({
    required this.height,
    required this.widthFraction,
    required this.borderRadius,
    required this.color,
    required this.marginBottom,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: marginBottom),
      child: FractionallySizedBox(
        widthFactor: widthFraction,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(borderRadius),
          ),
        ),
      ),
    );
  }
}
