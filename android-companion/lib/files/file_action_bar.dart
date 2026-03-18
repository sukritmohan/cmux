/// Bottom action bar for the file explorer.
///
/// Contains "New File" and "New Folder" buttons on the left, and a "Sort"
/// button on the right. All buttons use the shared surface/border styling.
import 'package:flutter/material.dart';

import '../app/colors.dart';

class FileActionBar extends StatelessWidget {
  const FileActionBar({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.bgPrimary,
        border: Border(
          top: BorderSide(color: c.border),
        ),
      ),
      child: Row(
        children: [
          _ActionButton(label: '+ New File'),
          const SizedBox(width: 8),
          _ActionButton(label: '+ New Folder'),
          const Spacer(),
          _ActionButton(label: 'Sort'),
        ],
      ),
    );
  }
}

/// Small pill-shaped action button used in the file action bar.
class _ActionButton extends StatelessWidget {
  final String label;

  const _ActionButton({required this.label});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: c.bgSurface,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border: Border.all(color: c.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: c.textSecondary,
        ),
      ),
    );
  }
}
