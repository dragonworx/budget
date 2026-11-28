import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';

/// Body copy for the Reset Stream confirm. [transferCount] of the
/// [transactionCount] transactions are transfers whose other side will
/// be deleted too.
String resetStreamMessage({
  required String streamName,
  required int transactionCount,
  int transferCount = 0,
}) {
  final n = transactionCount;
  final noun = n == 1 ? 'transaction' : 'transactions';
  final buf = StringBuffer(
    'This will permanently delete all $n $noun in “$streamName” '
    "and can't be undone.",
  );
  if (transferCount > 0) {
    final t = transferCount;
    buf.write(
      t == 1
          ? ' 1 of these is a transfer; its matching transaction in the '
                'other stream will also be permanently deleted.'
          : ' $t of these are transfers; their matching transactions in '
                'other streams will also be permanently deleted.',
    );
  }
  return buf.toString();
}

/// Confirms a permanent delete of every transaction in [streamName].
Future<bool> showResetStreamDialog(
  BuildContext context, {
  required String streamName,
  required int transactionCount,
  int transferCount = 0,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        key: const ValueKey('reset-stream-dialog'),
        title: const Text('Reset Stream?'),
        content: Text(
          resetStreamMessage(
            streamName: streamName,
            transactionCount: transactionCount,
            transferCount: transferCount,
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('reset-stream-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('reset-stream-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Tells the user this stream has nothing to reset.
Future<void> showNoTransactionsToDelete(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('reset-stream-empty-dialog'),
      title: const Text('Reset Stream'),
      content: const Text('No transactions to delete'),
      actions: [
        TextButton(
          key: const ValueKey('reset-stream-empty-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// The destructive menu row used on the Home card and in the timeline
/// More menu. [enabled] is false when the stream has no transactions.
MenuItemButton resetStreamMenuItem({
  Key? key,
  required BuildContext context,
  required bool enabled,
  required VoidCallback onPressed,
}) {
  final error = Theme.of(context).colorScheme.error;
  return MenuItemButton(
    key: key,
    leadingIcon: Icon(
      Icons.delete_outline_rounded,
      color: enabled ? error : null,
    ),
    style: MenuItemButton.styleFrom(foregroundColor: error),
    onPressed: enabled ? onPressed : null,
    child: Text(enabled ? 'Reset Stream' : 'No transactions to delete'),
  );
}

/// Loads the stream's transactions if needed, confirms, then resets.
/// Returns whether the reset ran.
Future<bool> confirmAndResetStream(
  BuildContext context,
  WidgetRef ref, {
  required BudgetStream stream,
  List<BudgetEvent>? events,
}) async {
  List<BudgetEvent> list;
  try {
    list = events ?? await ref.read(eventsProvider(stream.id).future);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(error))));
    }
    return false;
  }
  if (!context.mounted) return false;
  if (list.isEmpty) {
    await showNoTransactionsToDelete(context);
    return false;
  }
  final transfers = [
    for (final t in list)
      if (t.isTransfer) t,
  ].length;
  final ok = await showResetStreamDialog(
    context,
    streamName: stream.name,
    transactionCount: list.length,
    transferCount: transfers,
  );
  if (!ok || !context.mounted) return false;
  try {
    await ref.read(streamsProvider.notifier).resetEvents(stream.id);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(error))));
    }
    return false;
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          list.length == 1
              ? 'Deleted 1 transaction in “${stream.name}”.'
              : 'Deleted ${list.length} transactions in “${stream.name}”.',
        ),
      ),
    );
  }
  return true;
}
