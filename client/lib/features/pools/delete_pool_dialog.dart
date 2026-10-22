import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/repositories.dart' show PoolDeleteTransfers;
import '../../widgets/money_text.dart';
import '../timeline/occurrence_info.dart' show describeRecurrence;

/// Confirms deleting [pool]. With no [transactions] it is a plain confirm;
/// otherwise it lists them (scrollable): its own, which go with it, and its
/// transfers with other pools, whose far side the user keeps there as plain
/// debits / credits (default; those balances don't change) or deletes.
///
/// [pools] are the pools I can open (names, and whether I can edit them).
/// Returns the choice, or null when cancelled.
Future<PoolDeleteTransfers?> showDeletePoolDialog(
  BuildContext context, {
  required Pool pool,
  required List<Transaction> transactions,
  required List<Pool> pools,
}) {
  return showDialog<PoolDeleteTransfers>(
    context: context,
    builder: (_) =>
        DeletePoolDialog(pool: pool, transactions: transactions, pools: pools),
  );
}

class DeletePoolDialog extends StatefulWidget {
  const DeletePoolDialog({
    super.key,
    required this.pool,
    required this.transactions,
    required this.pools,
  });

  final Pool pool;
  final List<Transaction> transactions;
  final List<Pool> pools;

  @override
  State<DeletePoolDialog> createState() => _DeletePoolDialogState();
}

class _DeletePoolDialogState extends State<DeletePoolDialog> {
  var _mode = PoolDeleteTransfers.keep;

  List<Transaction> get _own => [
    for (final t in widget.transactions)
      if (!t.isTransfer) t,
  ];
  List<Transaction> get _transfers => [
    for (final t in widget.transactions)
      if (t.isTransfer) t,
  ];

  Pool? _poolById(String id) {
    for (final p in widget.pools) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The other pool's name as I may see it.
  String _peerName(TransferLink link) {
    if (!link.peerReadable) return "a pool you can't see";
    return _poolById(link.peerPoolId)?.name ??
        link.peerPoolName ??
        'another pool';
  }

  /// "Groceries" / "Groceries and Bills" / "Groceries, Bills and 2 more".
  String _peerList() {
    final names = <String>[];
    for (final t in _transfers) {
      final n = _peerName(t.transfer!);
      if (!names.contains(n)) names.add(n);
    }
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]} and ${names[1]}';
    if (names.length == 3) return '${names[0]}, ${names[1]} and ${names[2]}';
    return '${names[0]}, ${names[1]} and ${names.length - 2} more';
  }

  /// Other pools whose transfers I could not delete (no edit access).
  List<String> get _blocked {
    final out = <String>[];
    for (final t in _transfers) {
      final link = t.transfer!;
      final p = _poolById(link.peerPoolId);
      if (p == null || !p.role.canEdit) {
        final n = _peerName(link);
        if (!out.contains(n)) out.add(n);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final own = _own;
    final transfers = _transfers;
    final blocked = _blocked;
    final canDeleteTransfers = blocked.isEmpty;
    final mode = canDeleteTransfers ? _mode : PoolDeleteTransfers.keep;
    final count = widget.transactions.length;
    final size = MediaQuery.sizeOf(context);

    Widget header(String text, String key) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
      child: Text(
        text,
        key: ValueKey(key),
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );

    Widget row(Transaction t) {
      final link = t.transfer;
      final freq = describeRecurrence(t);
      final where = link == null
          ? freq
          : '${t.direction == TransactionDirection.debit ? 'To' : 'From'} '
                '${_peerName(link)} · $freq';
      return ListTile(
        key: ValueKey('pool-delete-row-${t.id}'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          link == null
              ? Icons.receipt_long_outlined
              : t.direction == TransactionDirection.debit
              ? Icons.north_east
              : Icons.south_west,
          size: 20,
        ),
        title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(where, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Text(
          formatSignedAmount(t.signedAmount.toDouble()),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );
    }

    final peers = transfers.isEmpty ? '' : _peerList();
    return AlertDialog(
      key: const ValueKey('pool-delete-dialog'),
      title: const Text('Delete pool?'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '“${widget.pool.name}” and its $count '
              '${count == 1 ? 'transaction' : 'transactions'} will be removed.',
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: size.height * 0.4),
                child: Scrollbar(
                  thumbVisibility: true,
                  child: ListView(
                    key: const ValueKey('pool-delete-list'),
                    shrinkWrap: true,
                    primary: true,
                    padding: const EdgeInsets.only(right: 12),
                    children: [
                      if (own.isNotEmpty) ...[
                        header(
                          'In this pool (deleted with it)',
                          'pool-delete-own',
                        ),
                        for (final t in own) row(t),
                      ],
                      if (transfers.isNotEmpty) ...[
                        header(
                          'Transfers with other pools',
                          'pool-delete-transfers',
                        ),
                        for (final t in transfers) row(t),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (transfers.isNotEmpty) ...[
              const SizedBox(height: 8),
              RadioGroup<PoolDeleteTransfers>(
                groupValue: mode,
                onChanged: (v) {
                  if (v != null) setState(() => _mode = v);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<PoolDeleteTransfers>(
                      key: const ValueKey('pool-delete-keep'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: PoolDeleteTransfers.keep,
                      title: Text('Keep in $peers as plain transactions'),
                      subtitle: const Text("Their balances don't change."),
                    ),
                    RadioListTile<PoolDeleteTransfers>(
                      key: const ValueKey('pool-delete-remove'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: PoolDeleteTransfers.delete,
                      enabled: canDeleteTransfers,
                      title: Text('Delete them from $peers'),
                      subtitle: Text(
                        canDeleteTransfers
                            ? 'Their balances change.'
                            : "You can't edit ${blocked.join(', ')}.",
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('pool-delete-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('pool-delete-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(mode),
          child: const Text('Delete pool'),
        ),
      ],
    );
  }
}
