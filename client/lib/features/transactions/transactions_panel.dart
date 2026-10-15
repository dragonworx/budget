import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/money_text.dart';
import '../../widgets/ui.dart';
import '../timeline/occurrence_dates.dart';
import '../timeline/occurrence_info.dart';
import '../timeline/zoom_level.dart';
import 'editor_outcome.dart';
import 'transaction_editor.dart';

enum TxFilter { all, credit, debit, disabled }

/// Filters [items] by a free-text [query] (name, amount) and [filter].
List<Transaction> filterTransactions(
  List<Transaction> items,
  String query,
  TxFilter filter,
) {
  final q = query.trim().toLowerCase();
  return [
    for (final t in items)
      if ((q.isEmpty ||
              t.name.toLowerCase().contains(q) ||
              t.amount.toString().contains(q)) &&
          switch (filter) {
            TxFilter.all => true,
            TxFilter.credit => t.direction == TransactionDirection.credit,
            TxFilter.debit => t.direction == TransactionDirection.debit,
            TxFilter.disabled => !t.enabled,
          })
        t,
  ];
}

/// The next occurrence on or after [today] (or the last one if all past).
DateTime? nextOccurrence(Transaction t, DateTime today) {
  final dates = estimateOccurrenceDates(t, maxCount: 4000);
  if (dates.isEmpty) return null;
  final d = dateOnly(today);
  for (final x in dates) {
    if (!x.isBefore(d)) return x;
  }
  return dates.last;
}

/// "next Fri 16 Oct 2026", "on Wed 31 Dec 2025" (one-off) or "ended …".
String? scheduleHint(Transaction t, DateTime today) {
  final d = nextOccurrence(t, today);
  if (d == null) return null;
  final when = formatOccurrenceDate(d);
  if (t.recurrenceMode == RecurrenceMode.once) return 'on $when';
  return d.isBefore(dateOnly(today)) ? 'ended $when' : 'next $when';
}

/// Side panel listing an account's transactions: search, filter, toggle,
/// edit and locate on the timeline.
class TransactionsPanel extends ConsumerStatefulWidget {
  const TransactionsPanel({
    super.key,
    required this.account,
    required this.skipsFor,
    required this.onPanelClosed,
    required this.onLocate,
    required this.onChanged,
  });

  final Account account;

  /// Currently skipped occurrence dates of a series.
  final Set<DateTime> Function(String transactionId) skipsFor;

  /// The panel was closed from inside the editor with this outcome.
  final ValueChanged<EditorOutcome?> onPanelClosed;
  final ValueChanged<DateTime> onLocate;
  final VoidCallback onChanged;

  @override
  ConsumerState<TransactionsPanel> createState() => _TransactionsPanelState();
}

class _TransactionsPanelState extends ConsumerState<TransactionsPanel> {
  final _search = TextEditingController();
  TxFilter _filter = TxFilter.all;

  /// Editor shown in place of the list (one panel, back to return).
  _Editing? _editing;
  var _listScroll = ScrollController();

  void _open(Transaction? t) {
    // Keep the list's scroll position for when the editor returns.
    final offset = _listScroll.hasClients ? _listScroll.offset : 0.0;
    final old = _listScroll;
    setState(() {
      _editing = _Editing(t);
      _listScroll = ScrollController(initialScrollOffset: offset);
    });
    Future.delayed(const Duration(seconds: 1), old.dispose);
  }

  void _editorDone(BuildContext context, EditorOutcome? outcome) {
    setState(() => _editing = null);
    widget.onChanged();
    reportEditorOutcome(
      context,
      ref,
      accountId: widget.account.id,
      outcome: outcome,
      onChanged: widget.onChanged,
    );
  }

  @override
  void dispose() {
    _search.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  List<Transaction> _ordered(List<Transaction> items) {
    final order =
        ref
            .watch(accountProvider(widget.account.id))
            .valueOrNull
            ?.transactionOrder ??
        widget.account.transactionOrder;
    final byId = {for (final t in items) t.id: t};
    return [for (final id in order) ?byId.remove(id), ...byId.values];
  }

  void _error(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(friendlyError(error))));
  }

  @override
  Widget build(BuildContext context) {
    // Own messenger: snackbars show inside the panel, above the scrim.
    return ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: AppTheme.surface,
        body: Builder(
          builder: (context) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0.04, 0),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: _editing == null
                ? KeyedSubtree(
                    key: const ValueKey('list'),
                    child: _listView(context),
                  )
                : TransactionEditor(
                    key: ValueKey('editor-${_editing!.transaction?.id}'),
                    accountId: widget.account.id,
                    existing: _editing!.transaction,
                    currency: widget.account.currency,
                    skippedDates: _editing!.transaction == null
                        ? const {}
                        : widget.skipsFor(_editing!.transaction!.id),
                    onDone: (o) => _editorDone(context, o),
                    onClosePanel: (o) {
                      widget.onChanged();
                      Navigator.of(context).pop();
                      widget.onPanelClosed(o);
                    },
                  ),
          ),
        ),
      ),
    );
  }

  Widget _listView(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(transactionsProvider(widget.account.id));
    return Material(
      color: AppTheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Transactions',
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('panel-new-transaction'),
                    onPressed: () => _open(null),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('New'),
                  ),
                  IconButton(
                    tooltip: 'Close (Esc)',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                key: const ValueKey('transactions-search'),
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search by name or amount',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () => setState(_search.clear),
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
              child: Wrap(
                spacing: 6,
                children: [
                  for (final f in TxFilter.values)
                    ChoiceChip(
                      key: ValueKey('filter-${f.name}'),
                      label: Text(switch (f) {
                        TxFilter.all => 'All',
                        TxFilter.credit => 'Money in',
                        TxFilter.debit => 'Money out',
                        TxFilter.disabled => 'Excluded',
                      }),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text(friendlyError(e))),
                data: (items) => _list(context, items),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context, List<Transaction> items) {
    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.receipt_long_rounded,
        title: 'No transactions yet',
        message: 'Add income, bills and one-offs here, or hover a day on the timeline and click +.',
        action: FilledButton.icon(
          onPressed: () => _open(null),
          icon: const Icon(Icons.add_rounded, size: 20),
          label: const Text('New transaction'),
        ),
      );
    }
    final ordered = _ordered(items);
    final shown = filterTransactions(ordered, _search.text, _filter);
    final canReorder = _search.text.trim().isEmpty && _filter == TxFilter.all;
    if (shown.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: 'No matches',
        message: 'Nothing matches the search and filter.',
        action: TextButton(
          onPressed: () => setState(() {
            _search.clear();
            _filter = TxFilter.all;
          }),
          child: const Text('Clear search and filter'),
        ),
      );
    }
    Widget row(int index, Transaction t) => _TxRow(
      key: ValueKey(t.id),
      transaction: t,
      currency: widget.account.currency,
      index: canReorder ? index : null,
      onTap: () => _open(t),
      onLocate: () {
        final d = nextOccurrence(t, DateTime.now());
        if (d != null) widget.onLocate(d);
      },
      onToggle: (v) async {
        try {
          await ref
              .read(transactionsProvider(widget.account.id).notifier)
              .updateTransaction(t.copyWith(enabled: v));
          widget.onChanged();
        } catch (e) {
          _error(e);
        }
      },
    );
    if (!canReorder) {
      return ListView.builder(
        controller: _listScroll,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: shown.length,
        itemBuilder: (context, i) => row(i, shown[i]),
      );
    }
    return ReorderableListView.builder(
      scrollController: _listScroll,
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: shown.length,
      onReorderItem: (oldIndex, newIndex) async {
        final ids = shown.map((s) => s.id).toList();
        ids.insert(newIndex, ids.removeAt(oldIndex));
        try {
          await ref
              .read(transactionsProvider(widget.account.id).notifier)
              .reorder(ids);
          widget.onChanged();
        } catch (e) {
          _error(e);
        }
      },
      itemBuilder: (context, i) => row(i, shown[i]),
    );
  }
}

class _TxRow extends StatelessWidget {
  const _TxRow({
    super.key,
    required this.transaction,
    required this.currency,
    required this.index,
    required this.onTap,
    required this.onLocate,
    required this.onToggle,
  });

  final Transaction transaction;
  final String currency;
  final int? index;
  final VoidCallback onTap;
  final VoidCallback onLocate;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = transaction;
    final credit = t.direction == TransactionDirection.credit;
    final amount = t.amount.toDouble() * (credit ? 1 : -1);
    final next = nextOccurrence(t, DateTime.now());
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: AppTheme.raised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppTheme.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
            child: Row(
              children: [
                if (index != null)
                  ReorderableDragStartListener(
                    index: index!,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        Icons.drag_indicator_rounded,
                        size: 18,
                        color: AppTheme.textFaint,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 8),
                DirectionBadge(credit: credit, muted: !t.enabled),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.name.isEmpty ? 'Untitled' : t.name,
                        maxLines: 1,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: t.enabled ? null : AppTheme.textFaint,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        [
                          describeRecurrence(t),
                          ?scheduleHint(t, DateTime.now()),
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatSignedAmount(amount, currency),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: !t.enabled
                        ? AppTheme.textFaint
                        : credit
                        ? AppTheme.creditColor
                        : AppTheme.debitColor,
                  ),
                ),
                IconButton(
                  tooltip: 'Show on timeline',
                  visualDensity: VisualDensity.compact,
                  onPressed: next == null ? null : onLocate,
                  icon: const Icon(Icons.my_location_rounded, size: 18),
                ),
                Tooltip(
                  message: t.enabled
                      ? 'Included in balance'
                      : 'Excluded from balance',
                  child: Transform.scale(
                    scale: 0.8,
                    child: Switch(value: t.enabled, onChanged: onToggle),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Editing {
  const _Editing(this.transaction);
  final Transaction? transaction;
}
