import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
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
  String on() => o.date == null ? '' : formatOccurrenceDate(o.date!);
  return switch (o.action) {
    EditorAction.created => 'Created $name',
    EditorAction.deleted => 'Deleted $name',
    EditorAction.saved =>
      hasSkips ? 'Saved $name · ${skips().toLowerCase()}' : 'Saved $name',
    EditorAction.skipsChanged => '${skips()} · $name',
    EditorAction.overridden => 'Changed $name on ${on()} only',
    EditorAction.overrideCleared => 'Reset $name on ${on()} to the series',
    EditorAction.overridesCleared =>
      'Cleared ${o.previous?.overrides.length ?? 0} once-off '
          'override${o.previous?.overrides.length == 1 ? '' : 's'} · $name',
    EditorAction.split => 'Changed $name from ${on()} on',
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
        case EditorAction.overridden:
        case EditorAction.overrideCleared:
          // Put the date back as it was (overridden or natural).
          final before = o.previous?.overrideOn(o.date!);
          if (before == null) {
            await notifier.clearOverrides(id, date: o.date);
          } else {
            await notifier.setOverride(
              id,
              o.date!,
              direction: before.direction,
              amount: before.amount,
            );
          }
        case EditorAction.overridesCleared:
          for (final e in o.previous?.overrides.entries ?? const <
              MapEntry<DateTime, OccurrenceOverride>>[]) {
            await notifier.setOverride(
              id,
              e.key,
              direction: e.value.direction,
              amount: e.value.amount,
            );
          }
        case EditorAction.split:
          // Drop the new series, restore the original whole, then put back
          // the skips / overrides that moved with the split.
          final previous = o.previous!;
          if (o.original != null && o.transaction.id != previous.id) {
            await notifier.delete(o.transaction.id);
          }
          await notifier.updateTransaction(previous, force: true);
          final from = o.date!;
          for (final d in o.skippedBefore) {
            if (!d.isBefore(from)) {
              await notifier.setSkip(previous.id, d, skipped: true);
            }
          }
          for (final e in previous.overrides.entries) {
            if (!e.key.isBefore(from)) {
              await notifier.setOverride(
                previous.id,
                e.key,
                direction: e.value.direction,
                amount: e.value.amount,
              );
            }
          }
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
