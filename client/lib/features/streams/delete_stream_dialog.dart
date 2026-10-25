import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/repositories.dart' show StreamDeleteTransfers;
import '../../widgets/money_text.dart';
import '../timeline/occurrence_info.dart' show describeRecurrence;

/// Confirms deleting [stream]. With no [events] it is a plain confirm;
/// otherwise it lists them (scrollable): its own, which go with it, and its
/// transfers with other streams, whose far side the user keeps there as plain
/// debits / credits (default; those balances don't change) or deletes.
///
/// [streams] are the streams I can open (names, and whether I can edit them).
/// Returns the choice, or null when cancelled.
Future<StreamDeleteTransfers?> showDeleteStreamDialog(
  BuildContext context, {
  required BudgetStream stream,
  required List<BudgetEvent> events,
  required List<BudgetStream> streams,
}) {
  return showDialog<StreamDeleteTransfers>(
    context: context,
    builder: (_) =>
        DeleteStreamDialog(stream: stream, events: events, streams: streams),
  );
}

class DeleteStreamDialog extends StatefulWidget {
  const DeleteStreamDialog({
    super.key,
    required this.stream,
    required this.events,
    required this.streams,
  });

  final BudgetStream stream;
  final List<BudgetEvent> events;
  final List<BudgetStream> streams;

  @override
  State<DeleteStreamDialog> createState() => _DeleteStreamDialogState();
}

class _DeleteStreamDialogState extends State<DeleteStreamDialog> {
  var _mode = StreamDeleteTransfers.keep;

  List<BudgetEvent> get _own => [
    for (final t in widget.events)
      if (!t.isTransfer) t,
  ];
  List<BudgetEvent> get _transfers => [
    for (final t in widget.events)
      if (t.isTransfer) t,
  ];

  BudgetStream? _streamById(String id) {
    for (final p in widget.streams) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The other stream's name as I may see it.
  String _peerName(TransferLink link) {
    if (!link.peerReadable) return "a stream you can't see";
    return _streamById(link.peerStreamId)?.name ??
        link.peerStreamName ??
        'another stream';
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

  /// Other streams whose transfers I could not delete (no edit access).
  List<String> get _blocked {
    final out = <String>[];
    for (final t in _transfers) {
      final link = t.transfer!;
      final p = _streamById(link.peerStreamId);
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
    final mode = canDeleteTransfers ? _mode : StreamDeleteTransfers.keep;
    final count = widget.events.length;
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

    Widget row(BudgetEvent t) {
      final link = t.transfer;
      final freq = describeRecurrence(t);
      final where = link == null
          ? freq
          : '${t.direction == EventDirection.debit ? 'To' : 'From'} '
                '${_peerName(link)} · $freq';
      return ListTile(
        key: ValueKey('stream-delete-row-${t.id}'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          link == null
              ? Icons.receipt_long_outlined
              : t.direction == EventDirection.debit
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
      key: const ValueKey('stream-delete-dialog'),
      title: const Text('Delete stream?'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '“${widget.stream.name}” and its $count '
              '${count == 1 ? 'event' : 'events'} will be removed.',
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: size.height * 0.4),
                child: Scrollbar(
                  thumbVisibility: true,
                  child: ListView(
                    key: const ValueKey('stream-delete-list'),
                    shrinkWrap: true,
                    primary: true,
                    padding: const EdgeInsets.only(right: 12),
                    children: [
                      if (own.isNotEmpty) ...[
                        header(
                          'In this stream (deleted with it)',
                          'stream-delete-own',
                        ),
                        for (final t in own) row(t),
                      ],
                      if (transfers.isNotEmpty) ...[
                        header(
                          'Transfers with other streams',
                          'stream-delete-transfers',
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
              RadioGroup<StreamDeleteTransfers>(
                groupValue: mode,
                onChanged: (v) {
                  if (v != null) setState(() => _mode = v);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<StreamDeleteTransfers>(
                      key: const ValueKey('stream-delete-keep'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: StreamDeleteTransfers.keep,
                      title: Text('Keep in $peers as plain events'),
                      subtitle: const Text("Their balances don't change."),
                    ),
                    RadioListTile<StreamDeleteTransfers>(
                      key: const ValueKey('stream-delete-remove'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: StreamDeleteTransfers.delete,
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
          key: const ValueKey('stream-delete-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('stream-delete-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(mode),
          child: const Text('Delete stream'),
        ),
      ],
    );
  }
}
