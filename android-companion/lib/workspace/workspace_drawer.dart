/// Workspace drawer shown from the left edge.
///
/// Lists all workspaces with active state highlighting. 300px width
/// (via theme), bgPrimary background, spring animation on open/close.
library;

import 'package:flutter/material.dart';

import '../app/colors.dart';
import '../app/theme.dart';
import '../state/workspace_provider.dart';
import 'workspace_tile.dart';

class WorkspaceDrawer extends StatelessWidget {
  final List<Workspace> workspaces;
  final String? activeWorkspaceId;
  final ValueChanged<String> onWorkspaceSelected;

  const WorkspaceDrawer({
    super.key,
    required this.workspaces,
    this.activeWorkspaceId,
    required this.onWorkspaceSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: AppColors.bgPrimary,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Text('WORKSPACES', style: AppTheme.sectionHeaderStyle),
            ),
            const Divider(),

            // Workspace list
            Expanded(
              child: workspaces.isEmpty
                  ? const Center(
                      child: Text(
                        'No workspaces',
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: workspaces.length,
                      itemBuilder: (context, index) {
                        final ws = workspaces[index];
                        return WorkspaceTile(
                          workspace: ws,
                          isActive: ws.id == activeWorkspaceId,
                          onTap: () => onWorkspaceSelected(ws.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
