import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../../state/providers.dart';
import '../timeline/occurrence_info.dart';
import 'transaction_editor.dart';

/// Snackbar text describing [o] exactly (null when nothing changed).
String? describeOutcome(EditorOutcome? o) {
  if (o == null) return null;
  final name = o.transaction.name.isEmpty
      ? 'Untitled'
      : '“${o.transaction.name}”';
  String skips() {
    final parts = <String>[];
    if (o.skipped.length == 1 && o.restored.isEmpty) {
      return 'Skipped ${formatOccurrenceDate(o.skipped.first)}';
    }
    if (o.restored.length == 1 && o.skipped.isEmpty) {
      return 'Restored ${formatOccurrenceDate(o.restored.first)}';
    }
    if (o.skipped.isNotEmpty) {
      parts.add(
        'skipped ${o.skipped.length} occurrence${o.skipped.length == 1 ? '' : 's'}',
      );
    }
    if (o.restored.isNotEmpty) {
      parts.add(
        'restored ${o.restored.length} occurrence${o.restored.length == 1 ? '' : 's'}',
      );
    }
    final t = parts.join(' and ');
    return t.isEmpty ? '' : t[0].toUpperCase() + t.substring(1);
  }

  final hasSkips = o.skipped.isNotEmpty || o.restored.isNotEmpty;
  return switch (o.action) {
    EditorAction.created => 'Created $name',
    EditorAction.deleted => 'Deleted $name',
    EditorAction.saved =>
      hasSkips ? 'Saved $name · ${skips().toLowerCase()}' : 'Saved $name',
    EditorAction.skipsChanged => '${skips()} · $name',
  };
}

/// Shows the outcome snackbar with an Undo that reverses it.
void reportEditorOutcome(
  BuildContext context,
  WidgetRef ref, {
  required String accountId,
  required EditorOutcome? outcome,
  required VoidCallback onChanged,
  List<String>? orderBefore,
}) {
  final text = describeOutcome(outcome);
  if (text == null || outcome == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final notifier = ref.read(transactionsProvider(accountId).notifier);
  final o = outcome;

  Future<void> undo() async {
    try {
      final id = o.transaction.id;
      switch (o.action) {
        case EditorAction.created:
          await notifier.delete(id);
        case EditorAction.deleted:
          final again = await notifier.create(
            o.transaction.copyWith(id: const Uuid().v4()),
          );
          for (final d in o.skippedBefore) {
            await notifier.setSkip(again.id, d, skipped: true);
          }
          // Put it back where it was in the list.
          if (orderBefore != null && orderBefore.contains(id)) {
            await notifier.reorder([
              for (final x in orderBefore) x == id ? again.id : x,
            ]);
          }
        case EditorAction.saved:
          if (o.previous != null) await notifier.updateTransaction(o.previous!, force: true);
          continue skips;
        skips:
        case EditorAction.skipsChanged:
          for (final d in o.skipped) {
            await notifier.setSkip(id, d, skipped: false);
          }
          for (final d in o.restored) {
            await notifier.setSkip(id, d, skipped: true);
          }
      }
      onChanged();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(content: Text('Undone')));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Undo failed: ${friendlyError(error)}')),
      );
    }
  }

  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(label: 'Undo', onPressed: undo),
    ),
  );
}
