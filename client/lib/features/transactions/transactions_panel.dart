import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../boot/page_stub.dart'
    if (dart.library.js_interop) '../../boot/page_web.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../widgets/conflict_dialog.dart';
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

/// Side panel listing a pool's transactions: search, filter, toggle,
/// edit and locate on the timeline.
class TransactionsPanel extends ConsumerStatefulWidget {
  const TransactionsPanel({
    super.key,
    required this.pool,
    required this.skipsFor,
    required this.onPanelClosed,
    required this.onLocate,
    required this.onChanged,
    this.onPlan,
    this.onClose,
  });

  final Pool pool;

  /// Docked beside the timeline (wide screens): Close calls this instead of
  /// popping a route, and closing the editor returns to the list.
  final VoidCallback? onClose;
  bool get docked => onClose != null;

  /// Currently skipped occurrence dates of a series.
  final Set<DateTime> Function(String transactionId) skipsFor;

  /// The panel was closed from inside the editor with this outcome.
  final ValueChanged<EditorOutcome?> onPanelClosed;
  final ValueChanged<DateTime> onLocate;
  final VoidCallback onChanged;

  /// "Plan" in the New split button: opens the payment / goal planner.
  final VoidCallback? onPlan;

  @override
  ConsumerState<TransactionsPanel> createState() => _TransactionsPanelState();
}

class _TransactionsPanelState extends ConsumerState<TransactionsPanel> {
  bool get _readOnly => !widget.pool.role.canEdit;

  /// New ▾ split button (like the editor's Save ▾): New is the main action;
  /// the menu offers New and Plan (the planner).
  Widget _newSplitButton() {
    const radius = Radius.circular(20);
    Widget item(String key, IconData icon, String title, VoidCallback? f) =>
        MenuItemButton(
          key: ValueKey(key),
          leadingIcon: Icon(icon, size: 20),
          onPressed: f,
          child: Text(title),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.tonalIcon(
          key: const ValueKey('panel-new-transaction'),
          style: FilledButton.styleFrom(
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.horizontal(left: radius),
            ),
          ),
          onPressed: () => _open(null),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('New'),
        ),
        const SizedBox(width: 2),
        MenuAnchor(
          alignmentOffset: const Offset(-120, 4),
          menuChildren: [
            // MenuItemButton runs onPressed a frame later (after the menu
            // closes), outside the tap: prime the keyboard on the release.
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerUp: (_) => primeSoftKeyboard(),
              child: item(
                'new-option-new',
                Icons.add_rounded,
                'New',
                () => _open(null, primed: true),
              ),
            ),
            item(
              'new-option-plan',
              Icons.calculate_outlined,
              'Plan',
              widget.onPlan,
            ),
          ],
          builder: (context, controller, _) => Tooltip(
            message: 'More new options',
            excludeFromSemantics: true,
            child: Semantics(
              label: 'More new options',
              button: true,
              expanded: controller.isOpen,
              child: FilledButton.tonal(
                key: const ValueKey('panel-new-menu'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(40, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.horizontal(right: radius),
                  ),
                ),
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                child: const Icon(Icons.arrow_drop_down_rounded, size: 22),
              ),
            ),
          ),
        ),
      ],
    );
  }

  final _search = TextEditingController();
  TxFilter _filter = TxFilter.all;

  /// Editor shown in place of the list (one panel, back to return).
  _Editing? _editing;
  var _listScroll = ScrollController();

  /// List order when the editor opened, so undoing a delete restores the
  /// series at the same position.
  List<String> _orderAtOpen = const [];

  /// Rows deleted from the list, hidden while the server call runs.
  final Set<String> _hidden = {};

  /// Series just edited / created: briefly highlighted and scrolled to.
  String? _highlightId;
  final _highlightKey = GlobalKey();
  Timer? _highlightTimer;

  void _open(Transaction? t, {bool primed = false}) {
    // New: still inside the tap, so phones raise the keyboard for Name.
    if (t == null && !primed) primeSoftKeyboard();
    // Keep the list's scroll position for when the editor returns.
    final offset = _listScroll.hasClients ? _listScroll.offset : 0.0;
    final old = _listScroll;
    _orderAtOpen = _ordered(
      ref.read(transactionsProvider(widget.pool.id)).valueOrNull ?? const [],
      watch: false,
    ).map((x) => x.id).toList();
    setState(() {
      _editing = _Editing(t);
      _listScroll = ScrollController(initialScrollOffset: offset);
    });
    Future.delayed(const Duration(seconds: 1), old.dispose);
  }

  /// Deletes [t] straight from the list (swipe or row menu); the snackbar's
  /// Undo recreates it at the same position with its skips.
  Future<void> _deleteFromList(BuildContext context, Transaction t) async {
    final notifier = ref.read(transactionsProvider(widget.pool.id).notifier);
    final order = _ordered(
      ref.read(transactionsProvider(widget.pool.id)).valueOrNull ?? const [],
      watch: false,
    ).map((x) => x.id).toList();
    final skips = widget.skipsFor(t.id);
    // Hide at once (a swiped row must leave the tree immediately).
    setState(() => _hidden.add(t.id));
    try {
      await notifier.delete(t.id);
    } catch (e) {
      if (mounted) setState(() => _hidden.remove(t.id));
      _error(e);
      return;
    }
    widget.onChanged();
    if (!context.mounted) return;
    reportEditorOutcome(
      context,
      ref,
      poolId: widget.pool.id,
      outcome: EditorOutcome(
        action: EditorAction.deleted,
        transaction: t,
        skippedBefore: skips,
      ),
      onChanged: widget.onChanged,
      orderBefore: order,
    );
  }

  void _editorDone(BuildContext context, EditorOutcome? outcome) {
    final edited = outcome != null && outcome.action != EditorAction.deleted
        ? outcome.transaction.id
        : _editing?.transaction?.id;
    _highlightTimer?.cancel();
    setState(() {
      _editing = null;
      _highlightId = outcome?.action == EditorAction.deleted ? null : edited;
    });
    if (_highlightId != null) {
      // Bring the row into view once the list is back, then fade the mark.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _highlightKey.currentContext;
        if (ctx != null && ctx.mounted) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.3,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          );
        }
      });
      _highlightTimer = Timer(const Duration(milliseconds: 2200), () {
        if (mounted) setState(() => _highlightId = null);
      });
    }
    widget.onChanged();
    reportEditorOutcome(
      context,
      ref,
      poolId: widget.pool.id,
      outcome: outcome,
      onChanged: widget.onChanged,
      orderBefore: _orderAtOpen,
    );
  }

  @override
  void dispose() {
    _search.dispose();
    _listScroll.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  List<Transaction> _ordered(List<Transaction> items, {bool watch = true}) {
    final pool = watch
        ? ref.watch(poolProvider(widget.pool.id))
        : ref.read(poolProvider(widget.pool.id));
    final order =
        pool.valueOrNull?.transactionOrder ?? widget.pool.transactionOrder;
    final byId = {
      for (final t in items)
        if (!watch || !_hidden.contains(t.id)) t.id: t,
    };
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
                    poolId: widget.pool.id,
                    readOnly: _readOnly,
                    existing: _editing!.transaction,
                    skippedDates: _editing!.transaction == null
                        ? const {}
                        : widget.skipsFor(_editing!.transaction!.id),
                    onDone: (o) => _editorDone(context, o),
                    onClosePanel: (o) {
                      widget.onChanged();
                      if (widget.docked) {
                        setState(() => _editing = null);
                      } else {
                        Navigator.of(context).pop();
                      }
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
    final async = ref.watch(transactionsProvider(widget.pool.id));
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
                  if (_readOnly) ...[
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Chip(
                        key: ValueKey('panel-view-only'),
                        avatar: Icon(Icons.visibility_outlined, size: 16),
                        label: Text('View only'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    // Viewers can't add, but can still plan (no New ▾).
                    if (widget.onPlan != null)
                      FilledButton.tonalIcon(
                        key: const ValueKey('panel-plan'),
                        onPressed: widget.onPlan,
                        icon: const Icon(Icons.calculate_outlined, size: 18),
                        label: const Text('Plan'),
                      ),
                  ] else
                    _newSplitButton(),
                  IconButton(
                    key: const ValueKey('panel-close'),
                    tooltip: widget.docked
                        ? 'Hide transactions'
                        : 'Close (Esc)',
                    onPressed:
                        widget.onClose ?? () => Navigator.of(context).pop(),
                    icon: Icon(
                      widget.docked
                          ? Icons.keyboard_double_arrow_right_rounded
                          : Icons.close_rounded,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                key: const ValueKey('transactions-search'),
                controller: _search,
                autofocus: MediaQuery.sizeOf(context).width >= 600,
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
        message: _readOnly ? 'Nothing has been added to this pool yet.' : 'Add income, bills and one-offs here, or hover a day on the timeline and click +.',
        action: _readOnly
            ? null
            : FilledButton.icon(
                onPressed: () => _open(null),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('New transaction'),
              ),
      );
    }
    final ordered = _ordered(items);
    final shown = filterTransactions(ordered, _search.text, _filter);
    final canReorder =
        !_readOnly && _search.text.trim().isEmpty && _filter == TxFilter.all;
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
      highlightKey: t.id == _highlightId ? _highlightKey : null,
      highlighted: t.id == _highlightId,
      transaction: t,
      index: canReorder ? index : null,
      readOnly: _readOnly,
      onTap: () => _open(t),
      onDelete: () => _deleteFromList(context, t),
      onLocate: () {
        final d = nextOccurrence(t, DateTime.now());
        if (d != null) widget.onLocate(d);
      },
      onToggle: (v) async {
        try {
          final n = ref.read(transactionsProvider(widget.pool.id).notifier);
          final r = await saveWithConflictCheck(
            context,
            save: (force) =>
                n.updateTransaction(t.copyWith(enabled: v), force: force),
            reload: n.refresh,
          );
          if (r != SaveResult.cancelled) widget.onChanged();
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
              .read(transactionsProvider(widget.pool.id).notifier)
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
    required this.index,
    required this.onTap,
    required this.onLocate,
    required this.onToggle,
    required this.onDelete,
    this.highlighted = false,
    this.highlightKey,
    this.readOnly = false,
  });

  final bool readOnly;

  final bool highlighted;
  final Key? highlightKey;
  final Transaction transaction;
  final int? index;
  final VoidCallback onTap;
  final VoidCallback onLocate;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = transaction;
    final credit = t.direction == TransactionDirection.credit;
    final amount = t.amount.toDouble() * (credit ? 1 : -1);
    final next = nextOccurrence(t, DateTime.now());
    final touch = MediaQuery.sizeOf(context).width < 600;
    final name = t.name.isEmpty ? 'Untitled' : t.name;
    // Swipe left to delete (undo in the snackbar, so no confirm). Needs a
    // long, deliberate swipe so a scroll or tap never deletes.
    return Dismissible(
      key: ValueKey('dismiss-${t.id}'),
      direction: readOnly ? DismissDirection.none : DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: 0.5},
      background: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppTheme.debitColor.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.only(right: 20),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Delete', style: TextStyle(fontWeight: FontWeight.w700)),
                  SizedBox(width: 8),
                  Icon(Icons.delete_outline_rounded),
                ],
              ),
            ),
          ),
        ),
      ),
      onDismissed: (_) => onDelete(),
      child: Padding(
        key: highlightKey,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Material(
          color: highlighted
              ? Color.alphaBlend(
                  AppTheme.accent.withValues(alpha: 0.12),
                  AppTheme.raised,
                )
              : AppTheme.raised,
          animationDuration: const Duration(milliseconds: 400),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: highlighted ? AppTheme.accent : AppTheme.border,
              width: highlighted ? 1.5 : 1,
            ),
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
                  t.isTransfer
                      ? _TransferBadge(muted: !t.enabled)
                      : DirectionBadge(credit: credit, muted: !t.enabled),
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
                        if (t.isTransfer)
                          Text(
                            transferPhrase(t),
                            key: ValueKey('row-transfer-${t.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppTheme.transferColor,
                              fontWeight: FontWeight.w600,
                            ),
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
                    formatSignedAmount(amount),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: !t.enabled
                          ? AppTheme.textFaint
                          : credit
                          ? AppTheme.creditColor
                          : AppTheme.debitColor,
                    ),
                  ),
                  if (touch)
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: PopupMenuButton<String>(
                        key: ValueKey('row-menu-${t.id}'),
                        tooltip: 'More for $name',
                        icon: const Icon(Icons.more_vert_rounded, size: 20),
                        color: AppTheme.overlay,
                        onSelected: (v) =>
                            v == 'delete' ? onDelete() : onLocate(),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'locate',
                            enabled: next != null,
                            child: const ListTile(
                              leading: Icon(Icons.my_location_rounded),
                              title: Text('Show on timeline'),
                            ),
                          ),
                          if (!readOnly)
                            PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                leading: Icon(
                                  Icons.delete_outline_rounded,
                                  color: AppTheme.debitColor,
                                ),
                                title: const Text('Delete'),
                              ),
                            ),
                        ],
                      ),
                    )
                  else ...[
                    IconButton(
                      tooltip: 'Show on timeline',
                      visualDensity: VisualDensity.compact,
                      onPressed: next == null ? null : onLocate,
                      icon: const Icon(Icons.my_location_rounded, size: 18),
                    ),
                    if (!readOnly)
                      IconButton(
                        key: ValueKey('row-delete-${t.id}'),
                        tooltip: 'Delete $name',
                        visualDensity: VisualDensity.compact,
                        onPressed: onDelete,
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                      ),
                  ],
                  Tooltip(
                    message: t.enabled
                        ? 'Included in balance'
                        : 'Excluded from balance',
                    // Tap toggles; horizontal drags fall through to the
                    // row's Dismissible instead of flipping the switch.
                    child: GestureDetector(
                      key: ValueKey('row-switch-${t.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: readOnly ? null : () => onToggle(!t.enabled),
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: readOnly ? 0.4 : 1,
                          child: Transform.scale(
                            scale: touch ? 0.9 : 0.8,
                            child: Switch(
                              value: t.enabled,
                              onChanged: readOnly ? null : onToggle,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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

/// List badge for one side of a transfer (⇄ instead of in/out arrow).
class _TransferBadge extends StatelessWidget {
  const _TransferBadge({this.muted = false});

  final bool muted;

  @override
  Widget build(BuildContext context) {
    final color = muted ? AppTheme.textFaint : AppTheme.transferColor;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: muted ? AppTheme.overlay : AppTheme.transferSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(Icons.swap_horiz_rounded, size: 18, color: color),
    );
  }
}
