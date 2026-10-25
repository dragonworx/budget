import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/money_text.dart';
import '../timeline/zoom_level.dart';
import '../events/editor_outcome.dart';
import '../events/event_editor.dart';
import 'reminders_model.dart';

/// Opens the full-screen Reminders view for [stream].
Future<void> showReminders(BuildContext context, BudgetStream stream) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => RemindersPage(stream: stream),
    ),
  );
}

class RemindersPage extends ConsumerStatefulWidget {
  const RemindersPage({super.key, required this.stream, this.today});

  final BudgetStream stream;

  /// Override for tests.
  final DateTime? today;

  @override
  ConsumerState<RemindersPage> createState() => _RemindersPageState();
}

class _RemindersPageState extends ConsumerState<RemindersPage> {
  late final DateTime _today = dateOnly(widget.today ?? DateTime.now());
  late DateTime _month = DateTime(_today.year, _today.month);
  ReminderRange _range = ReminderRange.week;
  bool _allStreams = false;
  DateTime? _selected;
  final _dayKeys = <DateTime, GlobalKey>{};
  final _listScroll = ScrollController();

  @override
  void dispose() {
    _listScroll.dispose();
    super.dispose();
  }

  List<BudgetStream> _scope() {
    if (!_allStreams) return [widget.stream];
    final list = ref.watch(streamsProvider).valueOrNull;
    return (list == null || list.isEmpty) ? [widget.stream] : list;
  }

  @override
  Widget build(BuildContext context) {
    final streams = _scope();
    final byId = {for (final a in streams) a.id: a};
    final grid = monthGrid(_month);
    final rangeEnd = _range.endFrom(_today);
    final from = grid.first.isBefore(_today) ? grid.first : _today;
    var to = grid.last.isAfter(rangeEnd) ? grid.last : rangeEnd;
    if (_selected != null && _selected!.isAfter(to)) to = _selected!;

    final txs = <BudgetEvent>[];
    final skipped = <String>{};
    var loading = false;
    for (final a in streams) {
      final t = ref.watch(eventsProvider(a.id));
      if (t.valueOrNull == null) loading = true;
      txs.addAll(t.valueOrNull ?? const []);
      // Server occurrences carry skips; applied when they arrive.
      final series = ref
          .watch(
            balanceProvider(BalanceQuery(streamId: a.id, from: from, to: to)),
          )
          .valueOrNull;
      for (final o in series?.occurrences ?? const <Occurrence>[]) {
        if (o.skipped) skipped.add(skipKey(o.eventId, o.date));
      }
    }
    final items = expandOccurrences(txs, from: from, to: to, skipped: skipped);
    final byDay = groupByDay(items);
    final calendar = _Calendar(
      month: _month,
      grid: grid,
      today: _today,
      selected: _selected,
      byDay: byDay,
      onMonth: (m) => setState(() => _month = m),
      onToday: () => setState(() {
        _month = DateTime(_today.year, _today.month);
        _selectDay(_today);
      }),
      onDayTap: (d) => setState(() => _selectDay(d)),
    );
    final list = _ReminderList(
      today: _today,
      rangeEnd: rangeEnd,
      range: _range,
      byDay: byDay,
      selected: _selected,
      dayKeys: _dayKeys,
      controller: _listScroll,
      streams: byId,
      showStream: _allStreams && streams.length > 1,
      loading: loading && items.isEmpty,
      onRange: (r) => setState(() => _range = r),
      onOpen: _open,
    );

    return Scaffold(
      key: const ValueKey('reminders-page'),
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('reminders-close'),
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Reminders'),
            Text(
              _allStreams ? 'All streams' : widget.stream.name,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: AppTheme.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          FilterChip(
            key: const ValueKey('reminders-all-streams'),
            label: const Text('All streams'),
            selected: _allStreams,
            onSelected: (v) => setState(() => _allStreams = v),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, c) {
            final side = remindersSideBySide(c.maxWidth, c.maxHeight);
            const divider = VerticalDivider(width: 1, color: AppTheme.border);
            return Flex(
              key: ValueKey(side ? 'reminders-row' : 'reminders-column'),
              direction: side ? Axis.horizontal : Axis.vertical,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: calendar),
                side
                    ? divider
                    : const Divider(height: 1, color: AppTheme.border),
                Expanded(child: list),
              ],
            );
          },
        ),
      ),
    );
  }

  void _selectDay(DateTime d) {
    _selected = dateOnly(d);
    if (d.month != _month.month || d.year != _month.year) {
      _month = DateTime(d.year, d.month);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _dayKeys[_selected]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      } else if (_listScroll.hasClients) {
        _listScroll.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _open(ReminderItem item, BudgetStream? stream) async {
    final a = stream ?? widget.stream;
    final t = item.event;
    final series = ref
        .read(
          balanceProvider(
            BalanceQuery(streamId: t.streamId, from: item.date, to: item.date),
          ),
        )
        .valueOrNull;
    final result = await showEventEditor(
      context,
      streamId: t.streamId,
      existing: t,
      focusDate: item.date,
      readOnly: !a.role.canEdit,
      skippedDates: {
        for (final o in series?.occurrences ?? const <Occurrence>[])
          if (o.eventId == t.id && o.skipped) dateOnly(o.date),
      },
    );
    ref.invalidate(balanceProvider);
    if (!mounted) return;
    reportEditorOutcome(
      context,
      ref,
      streamId: t.streamId,
      outcome: result,
      onChanged: () => ref.invalidate(balanceProvider),
    );
  }
}

Color toneColor(DayTone tone) => switch (tone) {
  DayTone.gain => AppTheme.creditColor,
  DayTone.loss => AppTheme.debitColor,
  DayTone.mixed => AppTheme.warning,
  DayTone.none => AppTheme.textFaint,
};

// ---------------------------------------------------------------- calendar

class _Calendar extends StatefulWidget {
  const _Calendar({
    required this.month,
    required this.grid,
    required this.today,
    required this.selected,
    required this.byDay,
    required this.onMonth,
    required this.onToday,
    required this.onDayTap,
  });

  final DateTime month;
  final List<DateTime> grid;
  final DateTime today;
  final DateTime? selected;
  final Map<DateTime, List<ReminderItem>> byDay;
  final ValueChanged<DateTime> onMonth;
  final VoidCallback onToday;
  final ValueChanged<DateTime> onDayTap;

  @override
  State<_Calendar> createState() => _CalendarState();
}

class _CalendarState extends State<_Calendar> {
  DateTime? _tip;
  Offset? _down;
  bool _dragged = false;

  DateTime? _dayAt(Offset p, Size size) {
    final rows = widget.grid.length ~/ 7;
    if (p.dx < 0 || p.dy < 0 || p.dx >= size.width || p.dy >= size.height) {
      return null;
    }
    final col = (p.dx / (size.width / 7)).floor().clamp(0, 6);
    final row = (p.dy / (size.height / rows)).floor().clamp(0, rows - 1);
    return widget.grid[row * 7 + col];
  }

  void _setTip(DateTime? d) {
    if (d != _tip) setState(() => _tip = d);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = widget.month;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('reminders-prev'),
                tooltip: 'Previous month',
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: () => widget.onMonth(DateTime(m.year, m.month - 1)),
              ),
              Expanded(
                child: Text(
                  DateFormat('MMMM y').format(m),
                  key: const ValueKey('reminders-month'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                key: const ValueKey('reminders-next'),
                tooltip: 'Next month',
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: () => widget.onMonth(DateTime(m.year, m.month + 1)),
              ),
              TextButton(
                key: const ValueKey('reminders-today'),
                onPressed: widget.onToday,
                child: const Text('Today'),
              ),
            ],
          ),
          Row(
            children: [
              for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                Expanded(
                  child: Text(
                    d,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppTheme.textFaint,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final size = Size(c.maxWidth, c.maxHeight);
                final rows = widget.grid.length ~/ 7;
                final cellW = size.width / 7, cellH = size.height / rows;
                return TapRegion(
                  onTapOutside: (_) => _setTip(null),
                  child: MouseRegion(
                    onHover: (e) {
                      if (e.kind == PointerDeviceKind.mouse) {
                        _setTip(_dayAt(e.localPosition, size));
                      }
                    },
                    onExit: (_) => _setTip(null),
                    child: Listener(
                      key: const ValueKey('reminders-grid'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (e) {
                        _down = e.localPosition;
                        _dragged = false;
                        _setTip(_dayAt(e.localPosition, size));
                      },
                      onPointerMove: (e) {
                        if (_down != null &&
                            (e.localPosition - _down!).distance > 8) {
                          _dragged = true;
                        }
                        final d = _dayAt(e.localPosition, size);
                        if (d != null) _setTip(d);
                      },
                      onPointerUp: (e) {
                        final d = _dayAt(e.localPosition, size);
                        if (!_dragged && d != null) widget.onDayTap(d);
                        _down = null;
                      },
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (var i = 0; i < widget.grid.length; i++)
                            Positioned(
                              left: (i % 7) * cellW,
                              top: (i ~/ 7) * cellH,
                              width: cellW,
                              height: cellH,
                              child: _DayCell(
                                date: widget.grid[i],
                                inMonth: widget.grid[i].month == m.month,
                                isToday: widget.grid[i] == widget.today,
                                isSelected: widget.grid[i] == widget.selected,
                                isTipped: widget.grid[i] == _tip,
                                totals: DayTotals.of(
                                  widget.byDay[widget.grid[i]] ?? const [],
                                ),
                              ),
                            ),
                          if (_tip != null && widget.grid.contains(_tip))
                            _tooltip(context, size, cellW, cellH),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _tooltip(BuildContext context, Size size, double cellW, double cellH) {
    final i = widget.grid.indexOf(_tip!);
    final col = i % 7, row = i ~/ 7;
    final totals = DayTotals.of(widget.byDay[_tip!] ?? const []);
    const w = 190.0;
    var left = col * cellW + cellW / 2 - w / 2;
    left = left.clamp(0.0, (size.width - w).clamp(0.0, double.infinity));
    // Above the cell when there's room (fingers cover what's below).
    final above = row >= 2;
    return Positioned(
      left: left,
      top: above ? null : (row + 1) * cellH + 4,
      bottom: above ? size.height - row * cellH + 4 : null,
      width: w,
      child: IgnorePointer(
        child: DayTooltipCard(date: _tip!, totals: totals),
      ),
    );
  }
}

class DayTooltipCard extends StatelessWidget {
  const DayTooltipCard({super.key, required this.date, required this.totals});

  final DateTime date;
  final DayTotals totals;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget row(String label, Decimal v, {Color? color, bool signed = false}) =>
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              Text(
                label,
                style: t.bodySmall?.copyWith(color: AppTheme.textMuted),
              ),
              const Spacer(),
              Text(
                signed
                    ? formatSignedAmount(v.toDouble())
                    : formatMoneyAmount(v.toDouble()),
                style: t.bodySmall?.copyWith(
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
    final net = totals.net;
    return Material(
      key: const ValueKey('reminders-tooltip'),
      color: AppTheme.overlay,
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(DateFormat('EEE d MMM y').format(date), style: t.labelLarge),
            if (totals.count == 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'No events',
                  style: t.bodySmall?.copyWith(color: AppTheme.textFaint),
                ),
              )
            else ...[
              row('Gains', totals.gains, color: AppTheme.creditColor),
              row('Losses', totals.losses, color: AppTheme.debitColor),
              row(
                'Net',
                net,
                signed: true,
                color: net > Decimal.zero
                    ? AppTheme.creditColor
                    : net < Decimal.zero
                    ? AppTheme.debitColor
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${totals.count} event${totals.count == 1 ? '' : 's'}',
                  style: t.bodySmall?.copyWith(color: AppTheme.textFaint),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.isTipped,
    required this.totals,
  });

  final DateTime date;
  final bool inMonth, isToday, isSelected, isTipped;
  final DayTotals totals;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = toneColor(totals.tone);
    return Padding(
      padding: const EdgeInsets.all(2),
      child: AnimatedContainer(
        key: ValueKey('reminders-day-${date.year}-${date.month}-${date.day}'),
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: isTipped
              ? AppTheme.overlay
              : isToday
              ? AppTheme.accentSoft
              : inMonth
              ? AppTheme.surface
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? AppTheme.accent
                : isToday
                ? AppTheme.accent.withValues(alpha: 0.6)
                : AppTheme.border.withValues(alpha: inMonth ? 1 : 0.4),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: 6,
              top: 4,
              child: Text(
                '${date.day}',
                style: t.labelMedium?.copyWith(
                  color: isToday
                      ? AppTheme.accent
                      : inMonth
                      ? AppTheme.text
                      : AppTheme.textFaint,
                  fontWeight: isToday ? FontWeight.w700 : null,
                ),
              ),
            ),
            if (totals.count > 0)
              Align(
                alignment: const Alignment(0, 0.45),
                child: Container(
                  key: ValueKey(
                    'reminders-badge-${date.year}-${date.month}-${date.day}',
                  ),
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: inMonth ? 0.9 : 0.45),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${totals.count}',
                    textAlign: TextAlign.center,
                    style: t.labelSmall?.copyWith(
                      color: AppTheme.bg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------- list

class _ReminderList extends StatelessWidget {
  const _ReminderList({
    required this.today,
    required this.rangeEnd,
    required this.range,
    required this.byDay,
    required this.selected,
    required this.dayKeys,
    required this.controller,
    required this.streams,
    required this.showStream,
    required this.loading,
    required this.onRange,
    required this.onOpen,
  });

  final DateTime today, rangeEnd;
  final ReminderRange range;
  final Map<DateTime, List<ReminderItem>> byDay;
  final DateTime? selected;
  final Map<DateTime, GlobalKey> dayKeys;
  final ScrollController controller;
  final Map<String, BudgetStream> streams;
  final bool showStream;
  final bool loading;
  final ValueChanged<ReminderRange> onRange;
  final void Function(ReminderItem, BudgetStream?) onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final days = [
      for (final e in byDay.entries)
        if (!e.key.isBefore(today) && !e.key.isAfter(rangeEnd)) e,
    ];
    final sel = selected;
    final selOutside =
        sel != null && (sel.isBefore(today) || sel.isAfter(rangeEnd));
    final all = days.expand((e) => e.value);
    final totals = DayTotals.of(all);

    final children = <Widget>[
      if (selOutside) ...[
        _dayBlock(context, sel, byDay[sel] ?? const [], highlight: true),
        const Divider(height: 24, color: AppTheme.border),
      ],
      if (loading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (days.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Nothing scheduled ${range == ReminderRange.today ? 'today' : 'in this period'}.',
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(color: AppTheme.textMuted),
          ),
        ),
      for (final e in days)
        _dayBlock(context, e.key, e.value, highlight: e.key == sel),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Upcoming', style: t.titleMedium),
                    Text(
                      '${totals.count} · +${formatMoneyAmount(totals.gains.toDouble())}'
                      ' / −${formatMoneyAmount(totals.losses.toDouble())}',
                      key: const ValueKey('reminders-range-totals'),
                      style: t.bodySmall?.copyWith(color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
              DropdownButton<ReminderRange>(
                key: const ValueKey('reminders-range'),
                value: range,
                underline: const SizedBox.shrink(),
                borderRadius: BorderRadius.circular(10),
                items: [
                  for (final r in ReminderRange.values)
                    DropdownMenuItem(value: r, child: Text(r.label)),
                ],
                onChanged: (r) {
                  if (r != null) onRange(r);
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            key: const ValueKey('reminders-list'),
            controller: controller,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    );
  }

  Widget _dayBlock(
    BuildContext context,
    DateTime day,
    List<ReminderItem> items, {
    required bool highlight,
  }) {
    final t = Theme.of(context).textTheme;
    final totals = DayTotals.of(items);
    final key = dayKeys.putIfAbsent(day, GlobalKey.new);
    final label = day == today
        ? 'Today · ${DateFormat('EEE d MMM').format(day)}'
        : day == today.add(const Duration(days: 1))
        ? 'Tomorrow · ${DateFormat('EEE d MMM').format(day)}'
        : DateFormat('EEE d MMM y').format(day);
    return AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: highlight ? AppTheme.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: highlight ? AppTheme.accent : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            key: ValueKey(
              'reminders-dayhead-${day.year}-${day.month}-${day.day}',
            ),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: t.labelLarge?.copyWith(
                      color: day == today ? AppTheme.accent : null,
                    ),
                  ),
                ),
                if (totals.gains > Decimal.zero)
                  Text(
                    '+${formatMoneyAmount(totals.gains.toDouble())}',
                    style: t.labelMedium?.copyWith(color: AppTheme.creditColor),
                  ),
                if (totals.gains > Decimal.zero && totals.losses > Decimal.zero)
                  const SizedBox(width: 8),
                if (totals.losses > Decimal.zero)
                  Text(
                    '−${formatMoneyAmount(totals.losses.toDouble())}',
                    style: t.labelMedium?.copyWith(color: AppTheme.debitColor),
                  ),
              ],
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
              child: Text(
                'No events',
                style: t.bodySmall?.copyWith(color: AppTheme.textFaint),
              ),
            ),
          for (final i in items) _row(context, i),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, ReminderItem i) {
    final t = Theme.of(context).textTheme;
    final tx = i.event;
    final acc = streams[tx.streamId];
    final subtitle = <String>[
      if (showStream && acc != null) acc.name,
      if (tx.transfer != null)
        '${i.isGain ? 'from' : 'to'} ${tx.transfer!.peerReadable ? (tx.transfer!.peerStreamName ?? 'another stream') : 'another stream'}',
      if (tx.recurrenceMode == RecurrenceMode.every)
        i.override != null ? 'Recurring · once-off amount' : 'Recurring',
    ].join(' · ');
    return InkWell(
      key: ValueKey('reminders-row-${tx.id}-${i.date.toIso8601String()}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => onOpen(i, acc),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Icon(
              tx.transfer != null
                  ? Icons.swap_horiz_rounded
                  : i.isGain
                  ? Icons.south_west_rounded
                  : Icons.north_east_rounded,
              size: 18,
              color: tx.transfer != null
                  ? AppTheme.transferColor
                  : i.isGain
                  ? AppTheme.creditColor
                  : AppTheme.debitColor,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx.name.isEmpty ? 'Untitled' : tx.name,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyMedium,
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: AppTheme.textFaint),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatSignedAmount(i.signed.toDouble()),
              style: t.bodyMedium?.copyWith(
                color: i.isGain ? AppTheme.creditColor : AppTheme.debitColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
