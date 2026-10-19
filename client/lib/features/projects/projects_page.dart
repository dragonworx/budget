import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/user_menu.dart';

import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../../data/api_client.dart';
import '../../state/providers.dart';
import '../../data/models.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/conflict_dialog.dart';
import '../../widgets/sharing_ui.dart';
import '../../data/sharing.dart';
import '../sharing/share_dialog.dart';
import '../../state/realtime_providers.dart';
import '../../widgets/ui.dart';

class ProjectsPage extends ConsumerWidget {
  const ProjectsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider);

    final count = projects.valueOrNull?.length;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.timeline_rounded, color: AppTheme.accent),
            SizedBox(width: 10),
            Text('Budget'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.read(projectsProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const UserMenu(),
          const SizedBox(width: 12),
        ],
      ),
      body: PageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeading(
              title: 'Projects',
              subtitle: count == null || count == 0
                  ? 'Group accounts and plan their balances over time'
                  : '$count project${count == 1 ? '' : 's'}',
              actions: [
                if (count != 0)
                  FilledButton.icon(
                    key: const ValueKey('new-project'),
                    onPressed: () => _createProject(context, ref),
                    icon: const Icon(Icons.add_rounded, size: 20),
                    label: const Text('New project'),
                  ),
              ],
            ),
            Expanded(
              child: projects.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => EmptyState(
                  error: true,
                  icon: Icons.cloud_off_rounded,
                  title: 'Could not reach the server',
                  message: _errorMessage(error),
                  action: OutlinedButton.icon(
                    onPressed: () =>
                        ref.read(projectsProvider.notifier).refresh(),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry'),
                  ),
                ),
                data: (items) {
                  if (items.isEmpty) {
                    return EmptyState(
                      icon: Icons.folder_open_rounded,
                      title: 'No projects yet',
                      message: 'Create a project to organise accounts and plan balances over time.',
                      action: FilledButton.icon(
                        onPressed: () => _createProject(context, ref),
                        icon: const Icon(Icons.add_rounded, size: 20),
                        label: const Text('Create project'),
                      ),
                    );
                  }
                  final invites =
                      ref.watch(myInvitesProvider).valueOrNull ?? const <Invite>[];
                  final mine = [for (final p in items) if (!p.shared) p];
                  final shared = [for (final p in items) if (p.shared) p];
                  Widget card(Project project) => _ProjectCard(
                        project: project,
                        onOpen: () => context.go('/projects/${project.id}'),
                        onRename: () => _renameProject(
                          context,
                          ref,
                          project.id,
                          project.name,
                        ),
                        onDelete: () => _deleteProject(
                          context,
                          ref,
                          project.id,
                          project.name,
                        ),
                        onShare: () => showShareDialog(
                          context,
                          ShareTarget.project(project.id, project.name),
                        ),
                      );
                  Widget heading(String t, String key) => Padding(
                    key: ValueKey(key),
                    padding: const EdgeInsets.fromLTRB(2, 14, 0, 8),
                    child: Text(
                      t,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: AppTheme.textMuted,
                      ),
                    ),
                  );
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                    children: [
                      if (invites.isNotEmpty) ...[
                        heading('Invitations for you', 'invites-heading'),
                        for (final i in invites) _PendingInviteTile(invite: i),
                      ],
                      if (shared.isNotEmpty && mine.isNotEmpty)
                        heading('My projects', 'mine-heading'),
                      for (final p in mine) ...[card(p), const SizedBox(height: 10)],
                      if (shared.isNotEmpty) ...[
                        heading('Shared with me', 'shared-heading'),
                        for (final p in shared) ...[card(p), const SizedBox(height: 10)],
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createProject(BuildContext context, WidgetRef ref) async {
    final name = await _promptName(context, title: 'New project');
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(projectsProvider.notifier).create(name);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorMessage(error))));
      }
    }
  }

  Future<void> _renameProject(
    BuildContext context,
    WidgetRef ref,
    String id,
    String current,
  ) async {
    final name = await _promptName(
      context,
      title: 'Rename project',
      initial: current,
    );
    if (name == null || name.isEmpty || name == current) return;
    if (!context.mounted) return;
    try {
      final n = ref.read(projectsProvider.notifier);
      await saveWithConflictCheck(
        context,
        save: (force) => n.rename(id, name, force: force),
        reload: n.refresh,
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorMessage(error))));
      }
    }
  }

  Future<void> _deleteProject(
    BuildContext context,
    WidgetRef ref,
    String id,
    String name,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete project?',
      message:
          '“$name” and all of its accounts and transactions will be removed.',
    );
    if (!confirmed) return;
    try {
      await ref.read(projectsProvider.notifier).delete(id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorMessage(error))));
      }
    }
  }
}

enum _ProjectAction { share, rename, delete }

Future<String?> _promptName(
  BuildContext context, {
  required String title,
  String? initial,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _NameDialog(title: title, initial: initial),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, this.initial});
  final String title;
  final String? initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: TextField(
          key: const ValueKey('project-name'),
          controller: _controller,
          autofocus: true,
          maxLength: 80,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Project name',
            hintText: 'e.g. Household',
            errorText: _error,
            counterText: '',
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.initial == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}

class _ProjectCard extends ConsumerWidget {
  const _ProjectCard({
    required this.project,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    required this.onShare,
  });
  final Project project;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(accountsProvider(project.id)).valueOrNull;
    final meta = [
      if (project.limited)
        '${project.sharedAccountIds.length} shared account${project.sharedAccountIds.length == 1 ? '' : 's'} only'
      else if (accounts != null)
        accounts.isEmpty
            ? 'No accounts'
            : '${accounts.length} account${accounts.length == 1 ? '' : 's'}',
      if (project.shared && project.owner != null)
        'Owner ${project.owner!.displayName}'
      else if (project.createdAt != null)
        'Created ${_formatDay(project.createdAt!)}',
    ].join(' · ');
    return Material(
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  IconTile(
                    project.limited
                        ? Icons.folder_special_outlined
                        : project.shared
                        ? Icons.folder_shared_rounded
                        : Icons.folder_rounded,
                  ),
                  if (project.shared && project.owner != null)
                    Positioned(
                      right: -6,
                      bottom: -6,
                      child: RefAvatar(
                        project.owner!,
                        key: const ValueKey('owner-avatar'),
                        radius: 10,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (project.shared)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: RoleChip(project.role),
                )
              else if (ownedProjectShared(ref, project))
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Tooltip(
                    message: 'Shared with others',
                    child: Icon(
                      Icons.people_alt_outlined,
                      key: ValueKey('owned-shared-badge'),
                      size: 18,
                      color: AppTheme.accent,
                    ),
                  ),
                ),
              if (accounts != null && accounts.isNotEmpty && !project.shared)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      for (final c in {for (final a in accounts) a.currency})
                        Pill(c),
                    ],
                  ),
                ),
              PopupMenuButton<_ProjectAction>(
                tooltip: 'Project actions',
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (a) => switch (a) {
                  _ProjectAction.share => onShare(),
                  _ProjectAction.rename => onRename(),
                  _ProjectAction.delete => onDelete(),
                },
                itemBuilder: (context) => [
                  if (!project.limited)
                    PopupMenuItem(
                      value: _ProjectAction.share,
                      child: ListTile(
                        leading: const Icon(Icons.person_add_alt_1_outlined),
                        title: Text(project.role.isOwner ? 'Share…' : 'People…'),
                      ),
                    ),
                  if (project.role.isOwner) ...const [
                  PopupMenuItem(
                    value: _ProjectAction.rename,
                    child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Rename'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _ProjectAction.delete,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline_rounded),
                      title: Text('Delete project'),
                    ),
                  ),
                  ],
                ],
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppTheme.textFaint,
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

String _errorMessage(Object error) => friendlyError(error);

/// An invite addressed to me that hasn't been accepted yet.
class _PendingInviteTile extends StatelessWidget {
  const _PendingInviteTile({required this.invite});
  final Invite invite;

  @override
  Widget build(BuildContext context) {
    final by = invite.invitedBy;
    return Card(
      key: ValueKey('my-invite-${invite.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: by == null
            ? const Icon(Icons.mail_outline_rounded)
            : RefAvatar(by, radius: 16),
        title: Text(invite.targetLabel),
        subtitle: Text(
          '${by?.displayName ?? 'Someone'} invited you as ${invite.role.label.toLowerCase()}. '
          'Open the link they sent you, or sign out and back in to accept.',
        ),
        trailing: RoleChip(invite.role),
      ),
    );
  }
}

String _formatDay(DateTime value) =>
    DateFormat('d MMM y').format(value.toLocal());
