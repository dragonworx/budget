import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/confirm_dialog.dart';

class ProjectsPage extends ConsumerWidget {
  const ProjectsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Budget Tool'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.read(projectsProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createProject(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: projects.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorPane(
          message: _errorMessage(error),
          onRetry: () => ref.read(projectsProvider.notifier).refresh(),
        ),
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'No projects yet',
                        style: Theme.of(context).textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Create a project to organize accounts and plan balances over time.',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: () => _createProject(context, ref),
                        icon: const Icon(Icons.add),
                        label: const Text('Create project'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final project = items[index];
              return ListTile(
                tileColor: Colors.white.withValues(alpha: 0.55),
                title: Text(project.name),
                subtitle: project.createdAt == null
                    ? null
                    : Text('Created ${_formatDay(project.createdAt!)}'),
                trailing: PopupMenuButton<_ProjectAction>(
                  onSelected: (action) async {
                    switch (action) {
                      case _ProjectAction.rename:
                        await _renameProject(context, ref, project.id, project.name);
                      case _ProjectAction.delete:
                        await _deleteProject(context, ref, project.id, project.name);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _ProjectAction.rename,
                      child: Text('Rename'),
                    ),
                    PopupMenuItem(
                      value: _ProjectAction.delete,
                      child: Text('Delete'),
                    ),
                  ],
                ),
                onTap: () => context.go('/projects/${project.id}'),
              );
            },
          );
        },
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(error))),
        );
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
    try {
      await ref.read(projectsProvider.notifier).rename(id, name);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(error))),
        );
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
      message: '“$name” and all of its accounts and transactions will be removed.',
    );
    if (!confirmed) return;
    try {
      await ref.read(projectsProvider.notifier).delete(id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(error))),
        );
      }
    }
  }
}

enum _ProjectAction { rename, delete }

Future<String?> _promptName(
  BuildContext context, {
  required String title,
  String? initial,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

String _errorMessage(Object error) {
  if (error is ApiException) return error.message;
  return error.toString();
}

String _formatDay(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}
