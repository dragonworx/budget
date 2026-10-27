import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../widgets/eye_icons.dart';
import '../../boot/page_stub.dart'
    if (dart.library.js_interop) '../../boot/page_web.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/money_text.dart';
import '../../widgets/ui.dart';
import '../timeline/occurrence_dates.dart';
import '../timeline/occurrence_info.dart';
import '../timeline/stack_lanes.dart';
import '../timeline/zoom_level.dart';
import 'editor_outcome.dart';
import 'event_editor.dart';

enum TxFilter { all, credit, debit, disabled }

/// Filters [items] by a free-text [query] (name, amount) and [filter].
List<BudgetEvent> filterEvents(
  List<BudgetEvent> items,
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
            TxFilter.credit => t.direction == EventDirection.credit,
            TxFilter.debit => t.direction == EventDirection.debit,
            TxFilter.disabled => !t.enabled,
          })
        t,
  ];
}

/// The next occurrence on or after [today] (or the last one if all past).
DateTime? nextOccurrence(BudgetEvent t, DateTime today) {
  final dates = estimateOccurrenceDates(t, maxCount: 4000);
  if (dates.isEmpty) return null;
  final d = dateOnly(today);
  for (final x in dates) {
    if (!x.isBefore(d)) return x;
  }
  return dates.last;
}

/// "next Fri 16 Oct 2026", "on Wed 31 Dec 2025" (one-off) or "ended …".
String? scheduleHint(BudgetEvent t, DateTime today) {
  final d = nextOccurrence(t, today);
  if (d == null) return null;
  final when = formatOccurrenceDate(d);
  if (t.recurrenceMode == RecurrenceMode.once) return 'on $when';
  return d.isBefore(dateOnly(today)) ? 'ended $when' : 'next $when';
}

/// A series' first (seed) date: "Starts Mon 26 Oct 2026" / "Started …"
/// (from [today]); [compact] (phones) drops the weekday: "Started 26 Oct
/// 2026".
String startPhrase(BudgetEvent t, DateTime today, {bool compact = false}) {
  final d = dateOnly(t.startDate);
  final when = compact
      ? DateFormat('d MMM y').format(d)
      : formatOccurrenceDate(d);
  return d.isAfter(dateOnly(today)) ? 'Starts $when' : 'Started $when';
}

/// The list's frequency word: "Once", "Daily", "Weekly", "Monthly",
/// "Yearly", or "Every 2 weeks".
String frequencyLabel(BudgetEvent t) {
  if (t.recurrenceMode == RecurrenceMode.once) return 'Once';
  final n = t.interval ?? 1;
  final unit = t.unit ?? RecurrenceUnit.months;
  if (n == 1) {
    return switch (unit) {
      RecurrenceUnit.days => 'Daily',
      RecurrenceUnit.weeks => 'Weekly',
      RecurrenceUnit.months => 'Monthly',
      RecurrenceUnit.years => 'Yearly',
    };
  }
  return 'Every $n ${unit.name}';
}

/// The parts of an Events list row: the other stream of a transfer (line
/// 1, after the name), then line 2's frequency, start ("from 5 Nov 2026";
/// a one-off's date) and how it ends ("until 30 Jun 2027" / "12 times",
/// last, so it's what ellipsises).
({String frequency, String start, String? transfer, String? end}) rowDetail(
  BudgetEvent t,
) {
  final date = DateFormat('d MMM y').format(dateOnly(t.startDate));
  final once = t.recurrenceMode == RecurrenceMode.once;
  return (
    frequency: frequencyLabel(t),
    start: once ? date : 'from $date',
    transfer: t.isTransfer ? transferPhrase(t) : null,
    end: once
        ? null
        : switch (t.endMode) {
            EndMode.untilDate when t.endDate != null =>
              'until ${DateFormat('d MMM y').format(t.endDate!)}',
            EndMode.count when t.occurrenceCount != null =>
              '${t.occurrenceCount} times',
            _ => null,
          },
  );
}

/// Side panel listing a stream's events: search, filter, toggle,
/// delete; a row opens in the editor.
class EventsPanel extends ConsumerStatefulWidget {
  const EventsPanel({
    super.key,
    required this.stream,
    required this.skipsFor,
    required this.onPanelClosed,
    required this.onChanged,
    this.onPlan,
    this.onClose,
  });

  final BudgetStream stream;

  /// Docked beside the timeline (wide screens): Close calls this instead of
  /// popping a route, and closing the editor returns to the list.
  final VoidCallback? onClose;
  bool get docked => onClose != null;

  /// Currently skipped occurrence dates of a series.
  final Set<DateTime> Function(String eventId) skipsFor;

  /// The panel was closed from inside the editor with this outcome.
  final ValueChanged<EditorOutcome?> onPanelClosed;
  final VoidCallback onChanged;

  /// "Plan" in the New split button: opens the payment / goal planner.
  final VoidCallback? onPlan;

  @override
  ConsumerState<EventsPanel> createState() => _EventsPanelState();
}

class _EventsPanelState extends ConsumerState<EventsPanel> {
  bool get _readOnly => !widget.stream.role.canEdit;

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
          key: const ValueKey('panel-new-event'),
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

  void _open(BudgetEvent? t, {bool primed = false}) {
    // New: still inside the tap, so phones raise the keyboard for Name.
    if (t == null && !primed) primeSoftKeyboard();
    // Keep the list's scroll position for when the editor returns.
    final offset = _listScroll.hasClients ? _listScroll.offset : 0.0;
    final old = _listScroll;
    _orderAtOpen = _ordered(
      ref.read(eventsProvider(widget.stream.id)).valueOrNull ?? const [],
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
  Future<void> _deleteFromList(BuildContext context, BudgetEvent t) async {
    final notifier = ref.read(eventsProvider(widget.stream.id).notifier);
    final order = _ordered(
      ref.read(eventsProvider(widget.stream.id)).valueOrNull ?? const [],
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
      streamId: widget.stream.id,
      outcome: EditorOutcome(
        action: EditorAction.deleted,
        event: t,
        skippedBefore: skips,
      ),
      onChanged: widget.onChanged,
      orderBefore: order,
    );
  }

  void _editorDone(BuildContext context, EditorOutcome? outcome) {
    final edited = outcome != null && outcome.action != EditorAction.deleted
        ? outcome.event.id
        : _editing?.event?.id;
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
      streamId: widget.stream.id,
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
    _autoScroll?.cancel();
    final pointer = _paintPointer;
    if (pointer != null) {
      GestureBinding.instance.pointerRouter.removeRoute(pointer, _paintEvent);
    }
    super.dispose();
  }

  // ---- Eye toggles (shown + counted / hidden + excluded): click / tap,
  // or press and paint across rows.

  /// Include values shown ahead of the server (a paint in progress, or
  /// saves in flight); dropped when they land (or roll back on failure).
  final Map<String, bool> _included = {};

  /// The paint in progress: the value being set, the rows it touched (and
  /// their values before), the pointer's last position.
  bool? _paintValue;
  final Map<String, bool> _paintBefore = {};
  Offset? _paintAt;
  Timer? _autoScroll;

  /// Rows as built (for hit-testing a paint), and the list's box.
  final Map<String, GlobalKey> _rowKeys = {};
  final _listKey = GlobalKey();
  List<BudgetEvent> _shown = const [];

  bool _isIncluded(BudgetEvent t) => _included[t.id] ?? t.enabled;

  int? _paintPointer;

  void _paintStart(BudgetEvent t, PointerDownEvent down) {
    if (_readOnly || _paintValue != null) return;
    _paintValue = !_isIncluded(t);
    _paintBefore.clear();
    _paintAt = down.position;
    // Follow the pointer from the binding, not the row: the row that took
    // the press may scroll away (and be disposed) mid-paint.
    _paintPointer = down.pointer;
    GestureBinding.instance.pointerRouter.addRoute(down.pointer, _paintEvent);
    _paintRow(t);
    _autoScroll = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _tickAutoScroll(),
    );
  }

  void _paintEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _paintMove(event.position);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _paintEnd();
    }
  }

  void _paintRow(BudgetEvent t) {
    final v = _paintValue;
    if (v == null || _paintBefore.containsKey(t.id)) return;
    _paintBefore[t.id] = t.enabled;
    if (_isIncluded(t) != v) setState(() => _included[t.id] = v);
  }

  /// The list's on-screen rect (paints and auto-scroll stay inside it).
  Rect? _listRect() {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// The row (by its vertical band, so a loose drag still counts) under
  /// global y, clamped into the list.
  BudgetEvent? _rowAtY(double y, Rect list) {
    final cy = y.clamp(list.top + 1, list.bottom - 1);
    for (final t in _shown) {
      final box =
          _rowKeys[t.id]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (cy >= top && cy < top + box.size.height) return t;
    }
    return null;
  }

  void _paintMove(Offset at) {
    final from = _paintAt;
    final list = _listRect();
    _paintAt = at;
    if (_paintValue == null || from == null || list == null) return;
    // Sample every few px between pointer events so a fast flick still
    // touches every row it crosses.
    final dy = at.dy - from.dy;
    final n = math.max(1, (dy.abs() / 6).ceil());
    for (var i = 1; i <= n; i++) {
      final t = _rowAtY(from.dy + dy * i / n, list);
      if (t != null) _paintRow(t);
    }
  }

  /// Near the list's top / bottom edge, scroll the list (only the list),
  /// painting rows as they pass under the pointer.
  void _tickAutoScroll() {
    final at = _paintAt, list = _listRect();
    if (_paintValue == null || at == null || list == null) return;
    if (!_listScroll.hasClients) return;
    const zone = 28.0;
    final pos = _listScroll.position;
    double step = 0;
    if (at.dy < list.top + zone) {
      step = -math.min(16.0, (list.top + zone - at.dy) / 2);
    } else if (at.dy > list.bottom - zone) {
      step = math.min(16.0, (at.dy - (list.bottom - zone)) / 2);
    }
    if (step == 0) return;
    final to = (pos.pixels + step).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (to == pos.pixels) return;
    pos.jumpTo(to);
    final t = _rowAtY(at.dy, list);
    if (t != null) _paintRow(t);
  }

  void _paintEnd() {
    final v = _paintValue;
    final pointer = _paintPointer;
    if (pointer != null) {
      GestureBinding.instance.pointerRouter.removeRoute(pointer, _paintEvent);
    }
    _paintPointer = null;
    _autoScroll?.cancel();
    _autoScroll = null;
    _paintValue = null;
    _paintAt = null;
    if (v == null) return;
    final changes = {
      for (final e in _paintBefore.entries)
        if (e.value != v) e.key: v,
    };
    // Rows painted back to their saved value need no request.
    setState(() {
      for (final id in _paintBefore.keys) {
        if (!changes.containsKey(id) && _included[id] == _paintBefore[id]) {
          _included.remove(id);
        }
      }
    });
    _paintBefore.clear();
    _saveIncluded(changes);
  }

  /// Keyboard (Space) / semantics toggle of one row.
  void _toggleOne(BudgetEvent t, bool v) {
    if (_readOnly || _paintValue != null) return;
    setState(() => _included[t.id] = v);
    _saveIncluded({if (v != t.enabled) t.id: v});
  }

  /// Saves the include changes in one batch; the timeline refreshes once.
  Future<void> _saveIncluded(Map<String, bool> changes) async {
    if (changes.isEmpty) return;
    final r = await ref
        .read(eventsProvider(widget.stream.id).notifier)
        .setEnabledMany(changes);
    if (!mounted) return;
    setState(() {
      // Landed (now in the list) or failed (rolled back): drop the shown
      // value, unless a newer paint has since changed it.
      for (final e in changes.entries) {
        if (_included[e.key] == e.value && !_paintBefore.containsKey(e.key)) {
          _included.remove(e.key);
        }
      }
    });
    if (r.failed.length < changes.length) widget.onChanged();
    if (r.error != null) _error(r.error!);
  }

  List<BudgetEvent> _ordered(List<BudgetEvent> items, {bool watch = true}) {
    final stream = watch
        ? ref.watch(streamProvider(widget.stream.id))
        : ref.read(streamProvider(widget.stream.id));
    final order = stream.valueOrNull?.eventOrder ?? widget.stream.eventOrder;
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
                : EventEditor(
                    key: ValueKey('editor-${_editing!.event?.id}'),
                    streamId: widget.stream.id,
                    readOnly: _readOnly,
                    existing: _editing!.event,
                    skippedDates: _editing!.event == null
                        ? const {}
                        : widget.skipsFor(_editing!.event!.id),
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
    final async = ref.watch(eventsProvider(widget.stream.id));
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
                    child: Text('Events', style: theme.textTheme.headlineSmall),
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
                    tooltip: widget.docked ? 'Hide events' : 'Close (Esc)',
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
                key: const ValueKey('events-search'),
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
                        TxFilter.disabled => 'Hidden',
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
            // Below the list (not beside the filters) so hiding the first
            // event never shifts the rows under the pointer mid-drag.
            if (_showHiddenChip(async.valueOrNull) case final chip?) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                child: Align(alignment: Alignment.centerLeft, child: chip),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// "Show N hidden": shows (and counts) every hidden event again in one
  /// batch (null: none hidden, or view only).
  Widget? _showHiddenChip(List<BudgetEvent>? items) {
    if (_readOnly) return null;
    final ids = [
      for (final t in items ?? const <BudgetEvent>[])
        if (!_isIncluded(t) && !_hidden.contains(t.id)) t.id,
    ];
    if (ids.isEmpty) return null;
    return ActionChip(
      key: const ValueKey('show-all-hidden'),
      avatar: const Icon(eventShownIcon, size: 16),
      label: Text('Show ${ids.length} hidden'),
      tooltip: 'Show every hidden event and count it in the balance again',
      onPressed: _paintValue != null
          ? null
          : () {
              setState(() {
                for (final id in ids) {
                  _included[id] = true;
                }
              });
              _saveIncluded({for (final id in ids) id: true});
            },
    );
  }

  Widget _list(BuildContext context, List<BudgetEvent> items) {
    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.receipt_long_rounded,
        title: 'No events yet',
        message: _readOnly ? 'Nothing has been added to this stream yet.' : 'Add income, bills and one-offs here, or hover a day on the timeline and click +.',
        action: _readOnly
            ? null
            : FilledButton.icon(
                onPressed: () => _open(null),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('New event'),
              ),
      );
    }
    final ordered = _ordered(items);
    final shown = filterEvents(ordered, _search.text, _filter);
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
    _shown = shown;
    _rowKeys.removeWhere((id, _) => !shown.any((t) => t.id == id));
    // Each row's colour bar wears its graph line's colour (an excluded
    // event has no lane: its own colour, else faint).
    final lanes = buildLaneSet(
      order: [for (final t in ordered) t.id],
      events: {for (final t in ordered) t.id: t.copyWith(enabled: true)},
    );
    Color colorOf(BudgetEvent t) {
      final i = lanes.indexOf(t.id);
      return colorFromHex(t.color) ??
          (i == null ? AppTheme.textFaint : lanes.lanes[i].color);
    }

    Widget row(int index, BudgetEvent t) => _TxRow(
      key: ValueKey(t.id),
      color: colorOf(t),
      rowKey: _rowKeys[t.id] ??= GlobalKey(),
      highlightKey: t.id == _highlightId ? _highlightKey : null,
      highlighted: t.id == _highlightId,
      event: _included.containsKey(t.id)
          ? t.copyWith(enabled: _included[t.id])
          : t,
      index: canReorder ? index : null,
      readOnly: _readOnly,
      onTap: () => _open(t),
      onDelete: () => _deleteFromList(context, t),
      onToggle: (v) => _toggleOne(t, v),
      onPaintStart: (down) => _paintStart(t, down),
    );
    if (!canReorder) {
      return KeyedSubtree(
        key: _listKey,
        child: ListView.builder(
          controller: _listScroll,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: shown.length,
          itemBuilder: (context, i) => row(i, shown[i]),
        ),
      );
    }
    return KeyedSubtree(
      key: _listKey,
      child: ReorderableListView.builder(
        scrollController: _listScroll,
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: shown.length,
        onReorderItem: (oldIndex, newIndex) async {
          final ids = shown.map((s) => s.id).toList();
          ids.insert(newIndex, ids.removeAt(oldIndex));
          try {
            await ref
                .read(eventsProvider(widget.stream.id).notifier)
                .reorder(ids);
            widget.onChanged();
          } catch (e) {
            _error(e);
          }
        },
        itemBuilder: (context, i) => row(i, shown[i]),
      ),
    );
  }
}

/// Wins a pointer the moment it lands (on a row's eye toggle), so the
/// list doesn't scroll, the row doesn't swipe or open, and the drag paints
/// (the panel follows the pointer from there).
class _PaintDragRecognizer extends OneSequenceGestureRecognizer {
  ValueChanged<PointerDownEvent>? onStart;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
    onStart?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'include paint drag';
}

class _TxRow extends StatelessWidget {
  const _TxRow({
    super.key,
    required this.event,
    required this.index,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
    required this.onPaintStart,
    this.color = AppTheme.textFaint,
    this.rowKey,
    this.highlighted = false,
    this.highlightKey,
    this.readOnly = false,
  });

  final bool readOnly;

  /// The event's graph line colour (the row's colour bar).
  final Color color;

  final bool highlighted;
  final Key? highlightKey;
  final BudgetEvent event;
  final int? index;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  final ValueChanged<PointerDownEvent> onPaintStart;

  /// On the row's box, so a paint-drag can find the row under the pointer.
  final Key? rowKey;

  @override
  Widget build(BuildContext context) {
    final t = event;
    final credit = t.direction == EventDirection.credit;
    final amount = t.amount.toDouble() * (credit ? 1 : -1);
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
      child: KeyedSubtree(
        key: rowKey,
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
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: Row(
                  children: [
                    if (index != null)
                      ReorderableDragStartListener(
                        index: index!,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 2),
                          child: Icon(
                            Icons.drag_indicator_rounded,
                            size: 18,
                            color: AppTheme.textFaint,
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 6),
                    // The graph line's colour.
                    Container(
                      key: ValueKey('row-colour-${t.id}'),
                      width: 4,
                      height: 30,
                      decoration: BoxDecoration(
                        color: t.enabled
                            ? color
                            : color.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: t.isTransfer
                          ? 'Transfer · ${transferPhrase(t)}'
                          : credit
                          ? 'Money in'
                          : 'Money out',
                      waitDuration: const Duration(milliseconds: 600),
                      excludeFromSemantics: true,
                      child: t.isTransfer
                          ? _TransferBadge(muted: !t.enabled)
                          : DirectionBadge(
                              credit: credit,
                              size: 28,
                              muted: !t.enabled,
                            ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: _lines(context, t, name, amount, credit)),
                    // Delete (editors only): a ⋮ menu on touch, an icon with
                    // a mouse. Tapping the row opens it in the editor.
                    if (readOnly)
                      const SizedBox(width: 4)
                    else if (touch)
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: PopupMenuButton<String>(
                          key: ValueKey('row-menu-${t.id}'),
                          tooltip: 'More for $name',
                          icon: const Icon(Icons.more_vert_rounded, size: 20),
                          color: AppTheme.overlay,
                          onSelected: (_) => onDelete(),
                          itemBuilder: (_) => [
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
                    else
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
                    _eyeToggle(t, name, touch),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Exactly two lines of text: name (· a transfer's other stream) +
  /// amount, then frequency · start (· how it ends, while it fits).
  /// One semantics label says it all, including what got ellipsised.
  Widget _lines(
    BuildContext context,
    BudgetEvent t,
    String name,
    double amount,
    bool credit,
  ) {
    final theme = Theme.of(context);
    final d = rowDetail(t);
    final muted = !t.enabled;
    final detail = theme.textTheme.bodySmall?.copyWith(
      color: muted ? AppTheme.textFaint : AppTheme.textMuted,
      height: 1.25,
    );
    final money = formatSignedAmount(amount);
    final next = scheduleHint(t, DateTime.now());
    final label = [
      name,
      if (t.isTransfer) 'transfer, ${d.transfer}',
      money,
      d.frequency,
      t.recurrenceMode == RecurrenceMode.once ? 'on ${d.start}' : d.start,
      ?d.end,
      if (t.recurrenceMode != RecurrenceMode.once) ?next,
      if (muted) 'hidden and excluded from balance',
    ].join(', ');
    final full = [
      d.frequency,
      d.start,
      ?d.end,
      if (t.recurrenceMode != RecurrenceMode.once) ?next,
    ].join(' · ');
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The amount keeps up to 40% of the line (140px).
            LayoutBuilder(
              builder: (context, line) => Row(
                key: ValueKey('row-line1-${t.id}'),
                children: [
                  // A transfer's other stream right after the name: the name
                  // ellipsises first, down to a few letters (48px, or 30% of
                  // a cramped line); only then does the stream ellipsise.
                  Expanded(
                    child: d.transfer == null
                        ? Text(
                            name,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: muted ? AppTheme.textFaint : null,
                              height: 1.25,
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, c) => Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Flexible(
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      color: muted ? AppTheme.textFaint : null,
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: math.max(
                                      0,
                                      c.maxWidth -
                                          6 -
                                          math.min(48, (c.maxWidth - 6) * 0.3),
                                    ),
                                  ),
                                  child: Text(
                                    d.transfer!,
                                    key: ValueKey('row-transfer-${t.id}'),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          height: 1.25,
                                          color: muted
                                              ? AppTheme.textFaint
                                              : AppTheme.transferColor,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  // Never squeezed by the name; a huge amount shrinks to fit.
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.min(140, line.maxWidth * 0.4),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        money,
                        key: ValueKey('row-amount-${t.id}'),
                        maxLines: 1,
                        style: theme.textTheme.labelLarge?.copyWith(
                          height: 1.25,
                          color: muted
                              ? AppTheme.textFaint
                              : credit
                              ? AppTheme.creditColor
                              : AppTheme.debitColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Tooltip(
              message: full,
              waitDuration: const Duration(milliseconds: 600),
              excludeFromSemantics: true,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${d.frequency} · ${d.start}'),
                    if (d.end != null) TextSpan(text: ' · ${d.end}'),
                  ],
                ),
                key: ValueKey('row-line2-${t.id}'),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: detail,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Show / hide: one compact eye toggle per row (eye: shown on the
  /// timeline and counted in the balance; eye-off: hidden from the timeline
  /// and excluded from the balance: the event's `enabled` flag). Pressing
  /// it flips it; dragging on across rows sets each to the same value.
  /// Enter / Space (and screen readers) toggle it too.
  Widget _eyeToggle(BudgetEvent t, String name, bool touch) {
    final size = touch ? 44.0 : 36.0;
    final shown = t.enabled;
    final label = shown
        ? 'Shown and counted in balance'
        : 'Hidden and excluded from balance';
    // The press itself is the paint recognizer's (it wins the pointer at
    // once); onPressed serves the keyboard and screen readers.
    // One node: a toggle named for the event, on = shown and counted.
    final button = MergeSemantics(
      child: Semantics(
        toggled: shown,
        label: 'Show $name (on the timeline and in the balance)',
        child: IconButton(
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: BoxConstraints.tightFor(width: size, height: size),
          onPressed: readOnly ? null : () => onToggle(!shown),
          icon: Icon(
            shown ? eventShownIcon : eventHiddenIcon,
            size: 20,
            color: shown ? AppTheme.accent : AppTheme.textFaint,
          ),
        ),
      ),
    );
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 600),
      excludeFromSemantics: true,
      child: SizedBox(
        key: ValueKey('row-eye-${t.id}'),
        width: size,
        height: size,
        child: readOnly
            ? Center(child: button)
            : RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: {
                  _PaintDragRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        _PaintDragRecognizer
                      >(_PaintDragRecognizer.new, (r) {
                        r.onStart = onPaintStart;
                      }),
                },
                child: Center(child: button),
              ),
      ),
    );
  }
}

class _Editing {
  const _Editing(this.event);
  final BudgetEvent? event;
}

/// List badge for one side of a transfer (⇄ instead of in/out arrow).
class _TransferBadge extends StatelessWidget {
  const _TransferBadge({this.muted = false});

  final bool muted;

  @override
  Widget build(BuildContext context) {
    final color = muted ? AppTheme.textFaint : AppTheme.transferColor;
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: muted ? AppTheme.overlay : AppTheme.transferSoft,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(Icons.swap_horiz_rounded, size: 16, color: color),
    );
  }
}
