import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/account_dialog.dart';
import '../../widgets/money_text.dart';
import '../../widgets/ui.dart';
import '../transactions/editor_outcome.dart';
import '../transactions/import_dialog.dart';
import '../transactions/solve_sheet.dart';
import '../transactions/transaction_editor.dart';
import '../transactions/transactions_panel.dart';
import 'balance_chart.dart';
import 'chart_geometry.dart';
import 'fit_ranges.dart';
import 'occurrence_info.dart';
import 'zoom_level.dart';

class TimelinePage extends ConsumerStatefulWidget {
  const TimelinePage({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends ConsumerState<TimelinePage>
    with SingleTickerProviderStateMixin {
  late DateTime _dataFrom;
  late DateTime _dataTo;
  late DateTime _viewStart;
  double _visibleDays = ZoomLevel.week.visibleDays.toDouble();
  String? _windowAccountId;
  BalanceSeries? _seriesCache;

  /// Window [_seriesCache] was fetched for; shown while a wider one loads.
  BalanceQuery? _seriesCacheQuery;

  /// Bumped by "Fit" to refit the chart's balance range to the data in view.
  int _fitToken = 0;

  /// Balance fits also stretch to the loss-threshold line.
  bool _fitThreshold = false;

  @override
  void initState() {
    super.initState();
    final today = dateOnly(DateTime.now());
    _viewStart = addCalendarDays(today, -7);
    _dataFrom = addCalendarDays(_viewStart, -30);
    _dataTo = addCalendarDays(today, 120);
  }

  void _ensureWindow(Account account) {
    if (_windowAccountId == account.id) return;
    _windowAccountId = account.id;
    _seriesCache = null;
    _seriesCacheQuery = null;
    final today = dateOnly(DateTime.now());
    final seed = dateOnly(account.seedDate);
    _viewStart = addCalendarDays(seed, -7);
    _dataFrom = addCalendarDays(_viewStart, -30);
    final horizon = math.max(120, _visibleDays.ceil());
    _dataTo = addCalendarDays(today.isAfter(seed) ? today : seed, horizon);
  }

  BalanceQuery get _query =>
      BalanceQuery(accountId: widget.accountId, from: _dataFrom, to: _dataTo);

  Future<void> _openImport(BuildContext context, Account account) async {
    final result = await showImportDialog(
      context,
      accountId: account.id,
      currency: account.currency,
    );
    if (result == null || !context.mounted) return;
    ref.invalidate(transactionsProvider(widget.accountId));
    ref.invalidate(accountProvider(widget.accountId));
    _invalidateBalance();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
  }

  void _invalidateBalance() {
    ref.invalidate(balanceProvider(_query));
    ref.invalidate(todayBalanceProvider(widget.accountId));
  }

  /// Puts [day] a third of the way in and refits the balance to the view
  /// (the balance scale is otherwise fixed while panning).
  void _centerOn(DateTime day) {
    _onViewport(addDays(dateOnly(day), -_visibleDays / 3), _visibleDays);
    setState(() => _fitToken++);
  }

  /// One smooth zoom step about the centre of the view: [direction] -1
  /// zooms in by [zoomStep], +1 zooms out. Animated over a few frames.
  void _zoomStep(int direction) {
    final factor = direction < 0 ? 1 / zoomStep : zoomStep;
    final target = zoomAboutCenter(_viewStart, _visibleDays, factor);
    _zoomAnim?.stop();
    final fromDays = _visibleDays;
    final center = dayCoord(_viewStart) + _visibleDays / 2;
    final controller = _zoomAnim ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
    );
    controller.removeListener(_zoomTick ?? () {});
    _zoomTick = () {
      final t = Curves.easeOut.transform(controller.value);
      // Interpolate the span geometrically so in/out feel symmetric.
      final days = fromDays * math.pow(target.days / fromDays, t);
      _onViewport(dateFromDayCoord(center - days / 2), days.toDouble());
    };
    controller
      ..addListener(_zoomTick!)
      ..forward(from: 0);
  }

  AnimationController? _zoomAnim;
  VoidCallback? _zoomTick;

  @override
  void dispose() {
    _zoomAnim?.dispose();
    super.dispose();
  }

  /// The visible time span in words (what the zoom buttons change).
  String get _spanLabel => describeSpan(_visibleDays);

  /// Applies a Fit menu choice. Time fits go through [_onViewport], which
  /// widens the fetched window to cover the new view; the chart then refits
  /// the balance range once that data has loaded.
  void _fit(FitMode mode, Account account) {
    TimeSpan? span;
    final center = addDays(_viewStart, _visibleDays / 2);
    switch (mode) {
      case FitMode.vertical:
        break;
      case FitMode.all:
      case FitMode.horizontal:
        final transactions =
            ref.read(transactionsProvider(widget.accountId)).valueOrNull ??
            const <Transaction>[];
        final range = accountDataRange(
          seedDate: account.seedDate,
          transactions: transactions,
          today: DateTime.now(),
        );
        span = paddedTimeSpan(range.first, range.last);
      case FitMode.week:
        span = weekContaining(center);
      case FitMode.month:
        span = monthContaining(center);
    }
    if (span != null) _onViewport(span.start, span.days);
    if (mode.fitsBalance) setState(() => _fitToken++);
  }

  /// Centres [day] and refits the balance to what is then in view.
  void _jumpTo(DateTime day) {
    _onViewport(addDays(dateOnly(day), 0.5 - _visibleDays / 2), _visibleDays);
    setState(() => _fitToken++);
  }

  void _onViewport(DateTime start, double visibleDays) {
    final days = visibleDays.clamp(minVisibleDays, maxVisibleDays).toDouble();
    final viewEnd = addDays(start, days);
    var from = _dataFrom;
    var to = _dataTo;
    final bufferDays = math.min(365, math.max(14, days.ceil()));
    if (!dateOnly(start).isAfter(addCalendarDays(from, bufferDays))) {
      from = addCalendarDays(start, -bufferDays * 2);
    }
    if (!dateOnly(viewEnd).isBefore(addCalendarDays(to, -bufferDays))) {
      to = addCalendarDays(viewEnd, bufferDays * 2);
    }
    setState(() {
      _viewStart = start;
      _visibleDays = days;
      _dataFrom = from;
      _dataTo = to;
    });
  }

  @override
  Widget build(BuildContext context) {
    final accountAsync = ref.watch(accountProvider(widget.accountId));

    return accountAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _goBack(context, null),
          ),
          title: const Text('Timeline'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(friendlyError(error), textAlign: TextAlign.center),
          ),
        ),
      ),
      data: (account) {
        _ensureWindow(account);
        final balanceAsync = ref.watch(balanceProvider(_query));
        final liveSeries = balanceAsync.asData?.value;
        if (liveSeries != null) {
          _seriesCache = liveSeries;
          _seriesCacheQuery = _query;
        }
        final series = _seriesCache;
        // Transaction names label the occurrence dots on the chart.
        final transactionNames = {
          for (final transaction
              in ref
                      .watch(transactionsProvider(widget.accountId))
                      .asData
                      ?.value ??
                  const <Transaction>[])
            transaction.id: transaction.name,
        };

        final transactions =
            ref.watch(transactionsProvider(widget.accountId)).valueOrNull ??
            const <Transaction>[];
        final todayPoint = series == null
            ? null
            : _closingNear(series.points, DateTime.now());

        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 68,
            leading: IconButton(
              tooltip: 'Back to accounts',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => _goBack(context, account.projectId),
            ),
            titleSpacing: 4,
            title: _AccountHeader(account: account, todayPoint: todayPoint),
            actions: [
              IconButton(
                tooltip: 'Import transactions (JSON)',
                onPressed: () => _openImport(context, account),
                icon: const Icon(Icons.file_upload_outlined),
              ),
              IconButton(
                key: const ValueKey('account-settings'),
                tooltip: 'Account settings: seed balance, date, threshold',
                onPressed: () => _editAccount(context, account),
                icon: const Icon(Icons.tune_rounded),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                key: const ValueKey('open-transactions'),
                onPressed: () => _openTransactionsPanel(context, account),
                icon: const Icon(Icons.list_alt_rounded, size: 18),
                label: Text('Transactions · ${transactions.length}'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('new-transaction'),
                onPressed: () => _openEditor(context, account),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('New transaction'),
              ),
              const SizedBox(width: 16),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _toolbar(context, account),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: series == null
                          ? balanceAsync.when(
                              loading: () => const Center(
                                child: CircularProgressIndicator(),
                              ),
                              error: (error, _) => _BalanceError(
                                message: friendlyError(error),
                                onRetry: _invalidateBalance,
                              ),
                              data: (_) => const SizedBox.shrink(),
                            )
                          : Stack(
                              children: [
                                BalanceChart(
                                  key: ValueKey(account.id),
                                  fitToken: _fitToken,
                                  onFitRequested: (mode) => _fit(mode, account),
                                  onZoomStep: _zoomStep,
                                  series: series,
                                  currency: account.currency,
                                  seedDate: account.seedDate,
                                  lossThreshold: account.lossThreshold
                                      .toDouble(),
                                  fitIncludesThreshold: _fitThreshold,
                                  viewStart: _viewStart,
                                  visibleDays: _visibleDays,
                                  onViewportChanged: _onViewport,
                                  onOccurrenceTap: (hits) =>
                                      _onOccurrencesTapped(
                                        context,
                                        account,
                                        hits,
                                      ),
                                  onDayTap: (day, onDay) {
                                    if (onDay.isNotEmpty) {
                                      _openDayPicker(
                                        context,
                                        account,
                                        day,
                                        onDay,
                                      );
                                    } else {
                                      _createOnceOnDay(context, day);
                                    }
                                  },
                                  onCreateOnDay: (day) =>
                                      _createOnceOnDay(context, day),
                                  transactionNames: transactionNames,
                                  transactions: {
                                    for (final t in transactions) t.id: t,
                                  },
                                  dataFrom: _seriesCacheQuery?.from,
                                  dataThrough: _seriesCacheQuery?.to,
                                  onRangeSelected: (start, end) =>
                                      _solveRange(context, start, end),
                                ),
                                if (balanceAsync.isLoading)
                                  const Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: LinearProgressIndicator(
                                      minHeight: 2,
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
              const _TipsBar(),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- toolbar

  Widget _toolbar(BuildContext context, Account account) {
    final theme = Theme.of(context);
    final end = dateOnly(addDays(_viewStart, _visibleDays));
    return Row(
      children: [
        // Zoom group: − [span] +
        Container(
          decoration: AppTheme.panel(color: AppTheme.raised, r: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('zoom-in'),
                tooltip: 'Zoom in (+)',
                onPressed: canZoomIn(_visibleDays) ? () => _zoomStep(-1) : null,
                icon: const Icon(Icons.zoom_in_rounded),
              ),
              Container(width: 1, height: 22, color: AppTheme.border),
              SizedBox(
                width: 84,
                child: Text(
                  _spanLabel,
                  key: const ValueKey('span-label'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              Container(width: 1, height: 22, color: AppTheme.border),
              IconButton(
                key: const ValueKey('zoom-out'),
                tooltip: 'Zoom out (−)',
                onPressed: canZoomOut(_visibleDays) ? () => _zoomStep(1) : null,
                icon: const Icon(Icons.zoom_out_rounded),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Jump to a date',
          child: OutlinedButton.icon(
            key: const ValueKey('jump-to-date'),
            onPressed: () => _jumpToDate(context),
            icon: const Icon(Icons.calendar_month_rounded, size: 18),
            label: Text(
              '${_shortDate(dateOnly(_viewStart))}  →  ${_shortDate(end)}',
            ),
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<Object>(
          key: const ValueKey('fit-menu'),
          tooltip: 'Fit the view',
          onSelected: (choice) {
            if (choice is FitMode) {
              _fit(choice, account);
            } else {
              setState(() {
                _fitThreshold = !_fitThreshold;
                _fitToken++;
              });
            }
          },
          position: PopupMenuPosition.under,
          itemBuilder: (context) => [
            for (final mode in FitMode.values)
              PopupMenuItem(
                value: mode,
                child: Row(
                  children: [
                    Icon(_fitIcon(mode), size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(mode.label)),
                    const SizedBox(width: 24),
                    KeyCap(mode.shortcut),
                  ],
                ),
              ),
            const PopupMenuDivider(),
            PopupMenuItem<Object>(
              key: const ValueKey('fit-threshold'),
              value: 'threshold',
              child: Row(
                children: [
                  Icon(
                    _fitThreshold
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 18,
                    color: _fitThreshold ? AppTheme.accent : null,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Keep alert line (${formatMoneyAmount(account.lossThreshold.toDouble(), account.currency)}) in fits',
                  ),
                ],
              ),
            ),
          ],
          child: IgnorePointer(
            child: OutlinedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.fit_screen_rounded, size: 18),
              label: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Fit'),
                  SizedBox(width: 2),
                  Icon(Icons.expand_more_rounded, size: 18),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => _centerOn(DateTime.now()),
          icon: const Icon(Icons.today_rounded, size: 18),
          label: const Text('Today'),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Go to the seed date (start of the balance)',
          child: OutlinedButton.icon(
            onPressed: () => _centerOn(account.seedDate),
            icon: const Icon(
              Icons.flag_rounded,
              size: 18,
              color: AppTheme.violet,
            ),
            label: const Text('Seed'),
          ),
        ),
        const Spacer(),
        Tooltip(
          message: 'Plan a transaction from a target total',
          child: TextButton.icon(
            onPressed: () => _solve(context),
            icon: const Icon(Icons.calculate_outlined, size: 18),
            label: const Text('Plan'),
          ),
        ),
        IconButton(
          key: const ValueKey('shortcuts-help'),
          tooltip: 'Keyboard and mouse shortcuts',
          onPressed: () => _showShortcuts(context),
          icon: const Icon(Icons.keyboard_rounded),
        ),
      ],
    );
  }

  IconData _fitIcon(FitMode mode) => switch (mode) {
    FitMode.all => Icons.fit_screen_rounded,
    FitMode.vertical => Icons.height_rounded,
    FitMode.horizontal => Icons.width_full_rounded,
    FitMode.week => Icons.view_week_rounded,
    FitMode.month => Icons.calendar_view_month_rounded,
  };

  String _shortDate(DateTime d) => DateFormat('d MMM y').format(d);

  Future<void> _jumpToDate(BuildContext context) async {
    final center = dateOnly(addDays(_viewStart, _visibleDays / 2));
    final picked = await showDatePicker(
      context: context,
      initialDate: center,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
      helpText: 'Jump to date',
    );
    if (picked == null) return;
    _jumpTo(picked);
  }

  Future<void> _showShortcuts(BuildContext context) {
    Widget row(List<String> keys, String what) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 170,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [for (final k in keys) KeyCap(k)],
            ),
          ),
          Expanded(child: Text(what)),
        ],
      ),
    );
    Widget head(String t) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        t.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 1,
          fontWeight: FontWeight.w700,
          color: AppTheme.textFaint,
        ),
      ),
    );
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Timeline shortcuts'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                head('Navigate'),
                row(['Drag'], 'Pan time and balance'),
                row(['←', '→'], 'Pan time'),
                row(['↑', '↓'], 'Pan balance'),
                row(['Scroll'], 'Zoom time at the cursor'),
                row(['+', '−'], 'Zoom time around the centre'),
                row(['Shift', 'Scroll'], 'Pan balance'),
                row(['Alt', 'Scroll'], 'Zoom balance'),
                head('Fit'),
                row(['F'], 'Fit balance to what is in view'),
                row(['A'], 'Fit all data'),
                row(['H'], 'Fit all data horizontally'),
                row(['W'], 'Fit the week at the centre'),
                row(['M'], 'Fit the month at the centre'),
                head('Transactions'),
                row(['Click dot'], 'Edit that transaction series'),
                row(['Hover day', '+'], 'Add a one-off on that day'),
                row(['Shift', 'Drag'], 'Select a range to plan a series'),
                row(['Ctrl', 'Enter'], 'Save in the editor'),
                row(['Esc'], 'Close the editor'),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------- transactions

  Set<DateTime> _skipsFor(String transactionId) => {
    for (final o in _seriesCache?.occurrences ?? const <Occurrence>[])
      if (o.transactionId == transactionId && o.skipped) dateOnly(o.date),
  };

  /// One place every create / edit path goes through, so the timeline
  /// always refreshes afterwards (skips can change even on cancel).
  Future<void> _openEditor(
    BuildContext context,
    Account account, {
    Transaction? existing,
    DateTime? initialDate,
    DateTime? focusDate,
    bool onceOnly = false,
  }) async {
    final result = await showTransactionEditor(
      context,
      accountId: widget.accountId,
      existing: existing,
      initialDate: initialDate,
      focusDate: focusDate,
      onceOnly: onceOnly,
      currency: account.currency,
      skippedDates: existing == null ? const {} : _skipsFor(existing.id),
    );
    _invalidateBalance();
    if (!context.mounted) return;
    _report(context, result);
  }

  void _report(BuildContext context, EditorOutcome? outcome) {
    reportEditorOutcome(
      context,
      ref,
      accountId: widget.accountId,
      outcome: outcome,
      onChanged: _invalidateBalance,
    );
  }

  Transaction? _transaction(String id) {
    for (final t
        in ref.read(transactionsProvider(widget.accountId)).valueOrNull ??
            const <Transaction>[]) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _onOccurrencesTapped(
    BuildContext context,
    Account account,
    List<Occurrence> hits,
  ) {
    final ids = hits.map((o) => o.transactionId).toSet();
    if (ids.length == 1) {
      final t = _transaction(ids.first);
      if (t != null) {
        _openEditor(
          context,
          account,
          existing: t,
          focusDate: dateOnly(hits.first.date),
        );
        return;
      }
    }
    _openDayPicker(context, account, dateOnly(hits.first.date), hits);
  }

  /// Several occurrences on one day: pick which series to open.
  Future<void> _openDayPicker(
    BuildContext context,
    Account account,
    DateTime day,
    List<Occurrence> onDay,
  ) async {
    final picked = await showModalBottomSheet<Object>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  formatOccurrenceDate(day),
                  style: theme.textTheme.titleLarge,
                ),
                Text(
                  '${onDay.length} occurrence${onDay.length == 1 ? '' : 's'} · pick one to edit its series',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                for (final occ in onDay) ...[
                  Builder(
                    builder: (context) {
                      final t = _transaction(occ.transactionId);
                      final amount = occ.signedDelta.toDouble();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: AppTheme.raised,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(color: AppTheme.border),
                          ),
                          child: ListTile(
                            leading: DirectionBadge(
                              credit: amount >= 0,
                              muted: occ.skipped,
                            ),
                            title: Text(
                              t == null || t.name.isEmpty
                                  ? 'Transaction'
                                  : t.name,
                            ),
                            subtitle: Text(
                              [
                                if (t != null) describeRecurrence(t),
                                if (occ.skipped) 'Skipped',
                              ].join(' · '),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  formatSignedAmount(amount, account.currency),
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: occ.skipped
                                        ? AppTheme.textFaint
                                        : amount < 0
                                        ? AppTheme.debitColor
                                        : AppTheme.creditColor,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Icon(Icons.chevron_right_rounded),
                              ],
                            ),
                            onTap: () => Navigator.pop(context, occ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, 'add'),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add a one-off on this day'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!context.mounted || picked == null) return;
    if (picked == 'add') {
      await _createOnceOnDay(context, day);
    } else if (picked is Occurrence) {
      final t = _transaction(picked.transactionId);
      if (t != null) {
        await _openEditor(context, account, existing: t, focusDate: day);
      }
    }
  }

  Future<void> _solve(BuildContext context) async {
    final result = await showSolveSheet(context, accountId: widget.accountId);
    if (result != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message ??
                'Created ${result.transaction?.name.isNotEmpty == true ? result.transaction!.name : 'transaction'}',
          ),
        ),
      );
      _invalidateBalance();
    }
  }

  Future<void> _solveRange(
    BuildContext context,
    DateTime start,
    DateTime end,
  ) async {
    final result = await showSolveSheet(
      context,
      accountId: widget.accountId,
      startDate: start,
      endDate: end,
    );
    if (result != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message ??
                'Created ${result.transaction?.name.isNotEmpty == true ? result.transaction!.name : 'transaction'}',
          ),
        ),
      );
      _invalidateBalance();
    }
  }

  Future<void> _editAccount(BuildContext context, Account account) async {
    final edited = await showAccountDialog(
      context,
      projectId: account.projectId,
      existing: account,
    );
    if (edited == null) return;
    try {
      await ref
          .read(accountsProvider(account.projectId).notifier)
          .updateAccount(edited);
      ref.invalidate(accountProvider(widget.accountId));
      _invalidateBalance();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Account updated')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }

  void _goBack(BuildContext context, String? projectId) {
    if (projectId != null) {
      context.go('/projects/$projectId');
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  Future<void> _createOnceOnDay(BuildContext context, DateTime day) async {
    final account = ref.read(accountProvider(widget.accountId)).valueOrNull;
    if (account == null) return;
    await _openEditor(context, account, initialDate: day, onceOnly: true);
  }

  Future<void> _openTransactionsPanel(
    BuildContext context,
    Account account,
  ) async {
    await showSidePanel<void>(
      context,
      width: 520,
      label: 'Transactions',
      builder: (panelContext) => TransactionsPanel(
        account: account,
        skipsFor: _skipsFor,
        onPanelClosed: (outcome) {
          if (context.mounted) _report(context, outcome);
        },
        onLocate: (date) {
          Navigator.of(panelContext).pop();
          _jumpTo(date);
        },
        onChanged: _invalidateBalance,
      ),
    );
  }

  BalancePoint? _closingNear(List<BalancePoint> points, DateTime day) {
    final key = dateOnly(day);
    for (final point in points) {
      if (dateOnly(point.date) == key) return point;
    }
    if (points.isEmpty) return null;
    BalancePoint? best;
    for (final point in points) {
      if (!dateOnly(point.date).isAfter(key)) {
        if (best == null || point.date.isAfter(best.date)) best = point;
      }
    }
    return best ?? points.last;
  }
}

class _AccountHeader extends StatelessWidget {
  const _AccountHeader({required this.account, required this.todayPoint});

  final Account account;
  final BalancePoint? todayPoint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = todayPoint?.closingBalance;
    final loss = today != null && today <= account.lossThreshold;
    return Row(
      children: [
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: account.name,
                waitDuration: const Duration(milliseconds: 500),
                child: Text(
                  account.name,
                  style: theme.textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                'Seed ${formatMoneyAmount(account.seedBalance.toDouble(), account.currency, decimalDigits: 2)} on ${DateFormat('d MMM y').format(account.seedDate)} · ${account.currency}',
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (today != null) ...[
          const SizedBox(width: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: AppTheme.panel(
              color: loss ? AppTheme.debitSoft : AppTheme.raised,
              r: 10,
              edge: loss
                  ? AppTheme.debitColor.withValues(alpha: 0.4)
                  : AppTheme.border,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'TODAY',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1,
                    color: AppTheme.textFaint,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  formatMoneyAmount(
                    today.toDouble(),
                    account.currency,
                    decimalDigits: 2,
                  ),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: loss ? AppTheme.debitColor : AppTheme.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _BalanceError extends StatelessWidget {
  const _BalanceError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
    error: true,
    icon: Icons.cloud_off_rounded,
    title: 'Could not load the balance',
    message: message,
    action: OutlinedButton.icon(
      onPressed: onRetry,
      icon: const Icon(Icons.refresh_rounded, size: 18),
      label: const Text('Retry'),
    ),
  );
}

/// One-line, low-key reminder of the main interactions.
class _TipsBar extends StatelessWidget {
  const _TipsBar();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    Widget tip(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(right: 18),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppTheme.textFaint),
          const SizedBox(width: 5),
          Text(text, style: style),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            tip(Icons.ads_click_rounded, 'Click a dot to edit its series'),
            tip(
              Icons.add_circle_outline_rounded,
              'Hover a day, click + to add',
            ),
            tip(Icons.pan_tool_alt_outlined, 'Drag to pan'),
            tip(Icons.mouse_outlined, 'Scroll to zoom'),
            tip(Icons.keyboard_rounded, 'Keyboard icon for all shortcuts'),
          ],
        ),
      ),
    );
  }
}
