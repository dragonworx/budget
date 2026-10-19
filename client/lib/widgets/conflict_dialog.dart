import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api_client.dart';

/// A `409 version conflict`: someone else saved this row since we loaded it.
bool isVersionConflict(Object error) =>
    error is ApiException &&
    error.statusCode == 409 &&
    (error.message.contains('version') ||
        (error.body ?? '').contains('version conflict'));

enum ConflictChoice { reload, overwrite }

Future<ConflictChoice?> showConflictDialog(BuildContext context) {
  return showDialog<ConflictChoice>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('conflict-dialog'),
      icon: const Icon(Icons.sync_problem_rounded),
      title: const Text('Changed by someone else'),
      content: const SizedBox(
        width: 360,
        child: Text(
          'This was changed since you opened it. Reload to see the latest '
          'version (your edit is discarded), or overwrite it with yours.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          key: const ValueKey('conflict-reload'),
          onPressed: () => Navigator.of(context).pop(ConflictChoice.reload),
          child: const Text('Reload'),
        ),
        FilledButton(
          key: const ValueKey('conflict-overwrite'),
          onPressed: () => Navigator.of(context).pop(ConflictChoice.overwrite),
          child: const Text('Overwrite'),
        ),
      ],
    ),
  );
}

/// Outcome of [saveWithConflictCheck].
enum SaveResult { saved, reloaded, cancelled }

/// Runs `save(false)` (with the row version). On a version conflict asks
/// "Reload / Overwrite": overwrite runs `save(true)` (no version, last write
/// wins); reload runs [reload]. Other errors are rethrown.
Future<SaveResult> saveWithConflictCheck(
  BuildContext context, {
  required Future<void> Function(bool force) save,
  required FutureOr<void> Function() reload,
}) async {
  try {
    await save(false);
    return SaveResult.saved;
  } catch (error) {
    if (!isVersionConflict(error) || !context.mounted) rethrow;
    final choice = await showConflictDialog(context);
    switch (choice) {
      case ConflictChoice.overwrite:
        await save(true);
        return SaveResult.saved;
      case ConflictChoice.reload:
        await reload();
        return SaveResult.reloaded;
      case null:
        return SaveResult.cancelled;
    }
  }
}
