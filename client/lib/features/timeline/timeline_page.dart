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
import '../../widgets/account_picker.dart';
import '../../widgets/money_text.dart';
import '../../widgets/ui.dart';
import '../transactions/editor_outcome.dart';
import '../transactions/import_dialog.dart';
import '../planning/plan_panel.dart';
import '../transactions/transaction_editor.dart';
import '../transactions/transactions_panel.dart';
import 'balance_chart.dart';
import 'chart_geometry.dart';
import 'fit_ranges.dart';
import 'ghost_line.dart';
import 'view_units.dart';
import 'zoom_level.dart';

class TimelinePage extends ConsumerStatefulWidget {
  const TimelinePage({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends ConsumerState<TimelinePage>
    with SingleTickerProviderStateMixin {
  /// Eases the time-scale buttons; pans, pinches, ◀ ▶ and fits are instant.
  late final AnimationController _viewAnim = AnimationController(
    vsync: this,
    duration: zoomEaseDuration,
  )..addListener(_tickView);
  DateTime _animFromCenter = DateTime(2000);
  DateTime _animToCenter = DateTime(2000);
  double _animFromDays = 1;
  double _animToDays = 1;

  @override
  void dispose() {
    _viewAnim.dispose();
    super.dispose();
  }

  void _tickView() {
    final t = Curves.easeOutCubic.transform(_viewAnim.value);
    final days = lerpVisibleDays(_animFromDays, _animToDays, t);
    final shift = (dayCoord(_animToCenter) - dayCoord(_animFromCenter)) * t;
    final center = addDays(_animFromCenter, shift);
    _applyViewport(addDays(center, -days / 2), days);
  }

  /// Eases the view to [days] wide about [center], starting from the current
  /// (possibly mid-animation) view so rapid taps chain smoothly.
  void _animateViewport(DateTime center, double days) {
    final to = days.clamp(minVisibleDays, maxVisibleDays).toDouble();
    _animFromCenter = addDays(_viewStart, _visibleDays / 2);
    _animFromDays = _visibleDays;
    _animToCenter = center;
    _animToDays = to;
    // Fetch the target window once up front (it covers every frame).
    _extendData(addDays(center, -to / 2), to);
    _viewAnim.forward(from: 0);
  }

  /// Selected view unit per account (kept while the app is open).
  static final Map<String, ViewUnit> _unitByAccount = {};

  /// Always one selected; − / + step through [ViewUnit.values].
  ViewUnit _unit = ViewUnit.month;

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
  int _zeroToken = 0;

  /// Balance fits also stretch to the loss-threshold line.
  bool _fitThreshold = false;

  /// Docked planner (non-blocking) and its live preview line.
  bool _planOpen = false;
  GhostLine? _planGhost;
  int _previewSeq = 0;

  void _openPlan() => setState(() => _planOpen = true);

  void _closePlan() => setState(() {
    _planOpen = false;
    _planGhost = null;
    _previewSeq++;
  });

  /// Projects the balance with the would-be [t] and shows it dashed.
  Future<void> _onPlanPreview(Transaction? t) async {
    final seq = ++_previewSeq;
    if (t == null) {
      if (_planGhost != null) setState(() => _planGhost = null);
      return;
    }
    final start = dateOnly(t.startDate);
    final horizon = addCalendarDays(start, 730);
    final to = _dataTo.isAfter(horizon) ? _dataTo : horizon;
    try {
      final series = await ref
          .read(accountRepositoryProvider)
          .project(
            widget.accountId,
            [t],
            from: addCalendarDays(start, -1),
            to: to,
          );
      if (!mounted || seq != _previewSeq) return;
      setState(
        () => _planGhost = GhostLine(
          points: series.points,
          color: AppTheme.planGhost,
          from: start,
          label: 'Plan preview',
        ),
      );
    } catch (_) {
      if (mounted && seq == _previewSeq) setState(() => _planGhost = null);
    }
  }

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
    _viewAnim.stop();
    _seriesCache = null;
    _seriesCacheQuery = null;
    final today = dateOnly(DateTime.now());
    final seed = dateOnly(account.seedDate);
    _unit = _unitByAccount[account.id] ?? ViewUnit.month;
    final first = _unit.spanContaining(seed);
    _viewStart = first.start;
    _visibleDays = first.days;
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
    ref.invalidate(insightsProvider(widget.accountId));
  }

  /// Puts [day] a third of the way in and refits the balance to the view
  /// (the balance scale is otherwise fixed while panning).
  void _centerOn(DateTime day) {
    _onViewport(addDays(dateOnly(day), -_visibleDays / 3), _visibleDays);
    setState(() => _fitToken++);
  }

  /// − / +: the previous / next view unit (smaller / larger), about the
  /// centre of the view. [direction] -1 zooms in, +1 zooms out. Instant.
  void _zoomStep(int direction) {
    final i = (_unit.index + direction).clamp(0, ViewUnit.values.length - 1);
    _selectUnit(ViewUnit.values[i]);
  }

  /// Selects [unit] and eases the view to one unit wide about the same
  /// centre date. The balance range is left as it is (no refit), so nothing
  /// jumps; Fit is there to refit.
  void _selectUnit(ViewUnit unit) {
    // Mid-animation, keep the original centre so chained taps never drift.
    final center = _viewAnim.isAnimating
        ? _animToCenter
        : addDays(_viewStart, _visibleDays / 2);
    final days = unit.spanContaining(center).days;
    setState(() => _setUnit(unit));
    _animateViewport(center, days);
  }

  /// ◀ (-1) / ▶ (1): one unit back / forward, snapped to unit starts.
  void _shift(int n) {
    final span = _unit.step(_viewStart, n);
    _onViewport(span.start, span.days);
    setState(() => _fitToken++);
  }

  void _setUnit(ViewUnit unit) {
    _unit = unit;
    _unitByAccount[widget.accountId] = unit;
  }

  /// Pans / wheel / pinch from the chart. A changed span (zoom) reselects the
  /// unit that best matches it, so the dropdown is never empty.
  void _onChartViewport(DateTime start, double days) {
    if ((days - _visibleDays).abs() > 1e-6) _setUnit(ViewUnit.nearest(days));
    _onViewport(start, days);
  }

  /// Applies a Fit menu choice. Time fits go through [_onViewport], which
  /// widens the fetched window to cover the new view; the chart then refits
  /// the balance range once that data has loaded.
  void _fit(FitMode mode, Account account) {
    TimeSpan? span;
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
        span = dataTimeSpan(range.first, range.last);
    }
    if (span != null) {
      _setUnit(ViewUnit.nearest(span.days));
      _onViewport(span.start, span.days);
    }
    if (mode.fitsBalance) {
      setState(() => _fitToken++);
    } else {
      setState(() => _zeroToken++); // keep the zero line in view
    }
  }

  /// Centres [day] and refits the balance to what is then in view.
  void _jumpTo(DateTime day) {
    _onViewport(addDays(dateOnly(day), 0.5 - _visibleDays / 2), _visibleDays);
    setState(() => _fitToken++);
  }

  /// Instant view change (pan, pinch, ◀ ▶, fits); cancels any easing.
  void _onViewport(DateTime start, double visibleDays) {
    _viewAnim.stop();
    _applyViewport(start, visibleDays);
  }

  void _extendData(DateTime start, double visibleDays) {
    final days = visibleDays.clamp(minVisibleDays, maxVisibleDays).toDouble();
    final r = _dataWindowFor(start, days);
    if (r.$1 != _dataFrom || r.$2 != _dataTo) {
      setState(() {
        _dataFrom = r.$1;
        _dataTo = r.$2;
      });
    }
  }

  (DateTime, DateTime) _dataWindowFor(DateTime start, double days) {
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
    return (from, to);
  }

  void _applyViewport(DateTime start, double visibleDays) {
    final days = visibleDays.clamp(minVisibleDays, maxVisibleDays).toDouble();
    final (from, to) = _dataWindowFor(start, days);
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
            transaction.id: transactionLabel(transaction),
        };

        final transactions =
            ref.watch(transactionsProvider(widget.accountId)).valueOrNull ??
            const <Transaction>[];
        final todayPoint = series == null
            ? null
            : _closingNear(series.points, DateTime.now());

        final compact = MediaQuery.sizeOf(context).width < 600;
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: compact ? 60 : 68,
            leading: IconButton(
              key: const ValueKey('timeline-back'),
              tooltip: 'Back to project',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => _goBack(context, account.projectId),
            ),
            titleSpacing: compact ? 0 : 4,
            title: _AccountHeader(
              account: account,
              todayPoint: todayPoint,
              insights: ref
                  .watch(insightsProvider(widget.accountId))
                  .valueOrNull,
              compact: compact,
            ),
            actions: compact
                ? [
                    IconButton(
                      key: const ValueKey('open-transactions'),
                      tooltip: 'Transactions (${transactions.length})',
                      onPressed: () => _openTransactionsPanel(context, account),
                      icon: Badge.count(
                        count: transactions.length,
                        backgroundColor: AppTheme.accent,
                        textColor: AppTheme.onAccent,
                        child: const Icon(Icons.list_alt_rounded),
                      ),
                    ),
                    PopupMenuButton<String>(
                      key: const ValueKey('timeline-more'),
                      tooltip: 'More',
                      icon: const Icon(Icons.more_vert_rounded),
                      onSelected: (v) {
                        switch (v) {
                          case 'import':
                            _openImport(context, account);
                          case 'settings':
                            _editAccount(context, account);
                          case 'plan':
                            _openPlan();
                          case 'shortcuts':
                            _showShortcuts(context);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'settings',
                          child: ListTile(
                            leading: Icon(Icons.tune_rounded),
                            title: Text('Account settings'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'import',
                          child: ListTile(
                            leading: Icon(Icons.file_upload_outlined),
                            title: Text('Import transactions'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'plan',
                          child: ListTile(
                            leading: Icon(Icons.calculate_outlined),
                            title: Text('Plan a payment'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'shortcuts',
                          child: ListTile(
                            leading: Icon(Icons.help_outline_rounded),
                            title: Text('Gestures & shortcuts'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 4),
                  ]
                : [
                    IconButton(
                      tooltip: 'Import transactions (JSON)',
                      onPressed: () => _openImport(context, account),
                      icon: const Icon(Icons.file_upload_outlined),
                    ),
                    IconButton(
                      key: const ValueKey('account-settings'),
                      tooltip:
                          'Account settings: seed balance, date, threshold',
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
                    const SizedBox(width: 16),
                  ],
          ),
          body: _withPlanPanel(
            context,
            compact: compact,
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 8 : 16,
                    compact ? 6 : 12,
                    compact ? 8 : 16,
                    0,
                  ),
                  child: compact
                      ? _compactToolbar(context, account)
                      : _toolbar(context, account),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 8 : 16,
                      compact ? 6 : 10,
                      compact ? 8 : 16,
                      6,
                    ),
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
                                    zeroToken: _zeroToken,
                                    onFitRequested: (mode) =>
                                        _fit(mode, account),
                                    onZoomStep: _zoomStep,
                                    unitLabel: _unit.label,
                                    canZoomIn: _unit.index > 0,
                                    canZoomOut:
                                        _unit.index <
                                        ViewUnit.values.length - 1,
                                    onShift: _shift,
                                    series: series,
                                    currency: account.currency,
                                    seedDate: account.seedDate,
                                    seedBalance: account.seedBalance.toDouble(),
                                    lossThreshold: account.lossThreshold
                                        .toDouble(),
                                    currencyScale: account.currencyScale
                                        .toDouble(),
                                    fitIncludesThreshold: _fitThreshold,
                                    viewStart: _viewStart,
                                    visibleDays: _visibleDays,
                                    onViewportChanged: _onChartViewport,
                                    onCreateOnDay: (day) =>
                                        _createOnceOnDay(context, day),
                                    transactionNames: transactionNames,
                                    transactions: {
                                      for (final t in transactions) t.id: t,
                                    },
                                    dataFrom: _seriesCacheQuery?.from,
                                    dataThrough: _seriesCacheQuery?.to,
                                    ghosts: [?_planGhost],
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
                if (!_planOpen || !compact) _TipsBar(compact: compact),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Docks the planner beside (desktop) or under (phone) the chart.
  Widget _withPlanPanel(
    BuildContext context, {
    required bool compact,
    required Widget child,
  }) {
    if (!_planOpen) return child;
    final panel = PlanPanel(
      accountId: widget.accountId,
      compact: compact,
      onClose: _closePlan,
      onPreview: _onPlanPreview,
      onDone: (r) => _planDone(context, r),
    );
    if (compact) {
      final h = MediaQuery.sizeOf(context).height;
      return Column(
        children: [
          Expanded(child: child),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: SizedBox(height: h * 0.46, child: panel),
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: child),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 12, 16, 10),
          child: SizedBox(width: 400, child: panel),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- toolbar

  Widget _toolbar(BuildContext context, Account account) {
    final theme = Theme.of(context);
    final end = lastVisibleDay(_viewStart, _visibleDays);
    return Row(
      children: [
        _unitGroup(theme, compact: false),
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
        _fitMenu(account, compact: false),
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
          message: 'Plan a payment or a balance goal',
          child: TextButton.icon(
            key: const ValueKey('open-plan'),
            onPressed: _openPlan,
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

  /// ◀ ▶ shift buttons; the unit itself is changed by the chart's floating
  /// horizontal scale pair (which also shows its name).
  Widget _unitGroup(ThemeData theme, {required bool compact}) {
    Widget divider() => Container(width: 1, height: 22, color: AppTheme.border);
    return Container(
      decoration: AppTheme.panel(color: AppTheme.raised, r: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('shift-left'),
            tooltip: 'Back one ${_unit.label.toLowerCase()} ([)',
            onPressed: () => _shift(-1),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          divider(),
          IconButton(
            key: const ValueKey('shift-right'),
            tooltip: 'Forward one ${_unit.label.toLowerCase()} (])',
            onPressed: () => _shift(1),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }

  Widget _fitMenu(Account account, {required bool compact}) {
    return PopupMenuButton<Object>(
      key: const ValueKey('fit-menu'),
      tooltip: 'Fit the view',
      onSelected: (choice) {
        if (choice is FitMode) {
          _fit(choice, account);
        } else if (choice == 'today') {
          _centerOn(DateTime.now());
        } else if (choice == 'seed') {
          _centerOn(account.seedDate);
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
        if (compact) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<Object>(
            value: 'today',
            child: Row(
              children: [
                Icon(Icons.today_rounded, size: 18),
                SizedBox(width: 10),
                Text('Go to today'),
              ],
            ),
          ),
          const PopupMenuItem<Object>(
            value: 'seed',
            child: Row(
              children: [
                Icon(Icons.flag_rounded, size: 18, color: AppTheme.violet),
                SizedBox(width: 10),
                Text('Go to seed date'),
              ],
            ),
          ),
        ],
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
      child: compact
          ? const SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.fit_screen_rounded),
            )
          : IgnorePointer(
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
    );
  }

  /// Phone toolbar: zoom, date range (tap to jump), fit, and a menu with
  /// Today / Seed. Everything is at least 44px tall.
  Widget _compactToolbar(BuildContext context, Account account) {
    final theme = Theme.of(context);
    final end = lastVisibleDay(_viewStart, _visibleDays);
    final fmt = DateFormat('d MMM yy');
    return Row(
      children: [
        _unitGroup(theme, compact: true),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton(
            key: const ValueKey('jump-to-date'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () => _jumpToDate(context),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${fmt.format(dateOnly(_viewStart))} → ${fmt.format(end)}',
                maxLines: 1,
              ),
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('open-plan-compact'),
          tooltip: 'Plan',
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: _planOpen ? _closePlan : _openPlan,
          isSelected: _planOpen,
          icon: const Icon(Icons.calculate_outlined),
          selectedIcon: const Icon(Icons.calculate, color: AppTheme.accent),
        ),
        _fitMenu(account, compact: true),
      ],
    );
  }

  IconData _fitIcon(FitMode mode) => switch (mode) {
    FitMode.all => Icons.fit_screen_rounded,
    FitMode.vertical => Icons.height_rounded,
    FitMode.horizontal => Icons.width_full_rounded,
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
                row(['Drag'], 'Pan time and balance (on the chart)'),
                row(['Pinch'], 'Zoom time (touch)'),
                row(['←', '→'], 'Pan time'),
                row(['↑', '↓'], 'Pan balance'),
                row(['Scroll'], 'Zoom time at the cursor'),
                row(['+', '−'], 'Smaller / larger view unit'),
                row(['[', ']'], 'Back / forward one unit'),
                row(['Shift', 'Scroll'], 'Pan balance'),
                row(['Alt', 'Scroll'], 'Zoom balance'),
                head('Fit'),
                row(['F'], 'Fit balance to what is in view'),
                row(['A'], 'Fit all data'),
                row(['H'], 'Fit all data horizontally'),
                head('Transactions'),
                row(['Click dot'], 'Show that occurrence’s details'),
                row(['Hover day', '+'], 'Add a one-off on that day'),
                row(['Drag dates'], 'Drag along the date axis, release to add'),
                row(['Tap dates'], 'Add a one-off on that day'),
                row(['Ctrl', 'Enter'], 'Save in the editor'),
                row(['Esc'], 'Cancel a date drag / close the editor'),
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

  void _planDone(BuildContext context, SolveResult result) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.message ??
              'Created ${result.transaction?.name.isNotEmpty == true ? result.transaction!.name : 'transaction'}',
        ),
      ),
    );
    _closePlan();
    ref.invalidate(transactionsProvider(widget.accountId));
    _invalidateBalance();
  }

  Future<void> _editAccount(BuildContext context, Account account) async {
    final edited = await showAccountDialog(
      context,
      projectId: account.projectId,
      existing: account,
      transactionCount: ref
          .read(transactionsProvider(widget.accountId))
          .valueOrNull
          ?.length,
    );
    if (edited == null) return;
    try {
      await ref
          .read(accountsProvider(account.projectId).notifier)
          .updateAccount(edited);
      ref.invalidate(accountProvider(widget.accountId));
      // A seed move shifts every schedule on the server.
      ref.invalidate(transactionsProvider(widget.accountId));
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
  const _AccountHeader({
    required this.account,
    required this.todayPoint,
    this.insights,
    this.compact = false,
  });

  final Account account;
  final BalancePoint? todayPoint;
  final BalanceInsights? insights;
  final bool compact;

  /// Phone header: "alert 19 Feb 27 · low −$2,450 15 Oct 27" (runway
  /// first: it matters most and the line may be cut off).
  String? _compactInsights() {
    final i = insights;
    if (i == null) return null;
    final short = DateFormat('d MMM yy');
    final today = dateOnly(DateTime.now());
    final alert = i.alertDate;
    final parts = <String>[
      alert == null
          ? 'runway OK'
          : (!alert.isAfter(today)
                ? 'below alert'
                : 'alert ${short.format(alert)}'),
    ];
    if (i.lowestBalance != null && i.lowestDate != null) {
      parts.add(
        'low ${formatMoneyAmount(i.lowestBalance!, account.currency)} '
        '${short.format(i.lowestDate!)}',
      );
    }
    return parts.join(' · ');
  }

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
              // Project > account jump menu (same picker as transfers).
              AccountPicker(
                keyPrefix: 'nav',
                title: 'Jump to account',
                currentAccountId: account.id,
                onSelected: (a) {
                  if (a.id == account.id) return;
                  context.pushReplacement('/accounts/${a.id}/timeline');
                },
                builder: (context, open) => InkWell(
                  key: const ValueKey('header-account-picker'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: open,
                  child: Tooltip(
                    message: 'Jump to another account',
                    waitDuration: const Duration(milliseconds: 500),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            account.name,
                            style: compact
                                ? theme.textTheme.titleMedium
                                : theme.textTheme.titleLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(
                          Icons.arrow_drop_down_rounded,
                          color: AppTheme.textMuted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (compact && today != null)
                Text(
                  [
                    'Today ${formatMoneyAmount(today.toDouble(), account.currency, decimalDigits: 2)}',
                    ?_compactInsights(),
                  ].join(' · '),
                  key: const ValueKey('header-today'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: loss ? AppTheme.debitColor : AppTheme.textMuted,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              else
                Text(
                  'Seed ${formatMoneyAmount(account.seedBalance.toDouble(), account.currency, decimalDigits: 2)} on ${DateFormat('d MMM y').format(account.seedDate)} · ${account.currency}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        if (insights != null && !compact) ...[
          const SizedBox(width: 10),
          _InsightChip(
            key: const ValueKey('header-lowest'),
            label: 'LOWEST · 12 MO',
            value: insights!.lowestBalance == null
                ? '—'
                : formatMoneyAmount(insights!.lowestBalance!, account.currency),
            detail: insights!.lowestDate == null
                ? null
                : DateFormat('d MMM y').format(insights!.lowestDate!),
            warn:
                insights!.lowestBalance != null &&
                insights!.lowestBalance! <= account.lossThreshold.toDouble(),
          ),
          const SizedBox(width: 8),
          _InsightChip(
            key: const ValueKey('header-runway'),
            label: 'RUNWAY',
            value: runwayText(insights!, account),
            detail: insights!.alertDate == null
                ? null
                : 'alert ≤ ${formatMoneyAmount(account.lossThreshold.toDouble(), account.currency)}',
            warn: insights!.alertDate != null,
          ),
        ],
        if (today != null && !compact) ...[
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

/// Runway headline: the first alert date (and the zero date when the
/// threshold is not zero), or that it holds for the whole horizon.
String runwayText(BalanceInsights i, Account account) {
  final fmt = DateFormat('d MMM y');
  final alert = i.alertDate;
  if (alert == null) {
    return 'OK ${(i.horizonDays / 365).round()}+ yrs';
  }
  final today = dateOnly(DateTime.now());
  if (!alert.isAfter(today)) return 'Below alert now';
  final zero = i.zeroDate;
  if (zero != null && zero != alert && account.lossThreshold.toDouble() != 0) {
    return '${fmt.format(alert)} · \$0 ${fmt.format(zero)}';
  }
  return fmt.format(alert);
}

class _InsightChip extends StatelessWidget {
  const _InsightChip({
    super.key,
    required this.label,
    required this.value,
    this.detail,
    this.warn = false,
  });

  final String label;
  final String value;
  final String? detail;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: AppTheme.panel(
        color: warn ? AppTheme.debitSoft : AppTheme.raised,
        r: 10,
        edge: warn ? AppTheme.debitColor.withValues(alpha: 0.4) : AppTheme.border,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1,
              color: AppTheme.textFaint,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: warn ? AppTheme.debitColor : AppTheme.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (detail != null)
                  TextSpan(
                    text: '  $detail',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
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
  const _TipsBar({this.compact = false});
  final bool compact;

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
            if (compact) ...[
              tip(Icons.ads_click_rounded, 'Tap near a dot for details'),
              tip(
                Icons.add_circle_outline_rounded,
                'Tap or drag the dates to add',
              ),
              tip(Icons.touch_app_outlined, 'Drag near dots for details'),
              tip(Icons.chevron_right_rounded, '◀ ▶ step one unit'),
              tip(Icons.pinch_outlined, 'Pinch to zoom'),
            ] else ...[
              tip(Icons.ads_click_rounded, 'Click or tap a dot for details'),
              tip(
                Icons.swipe_right_alt_rounded,
                'Drag or tap the dates to add',
              ),
              tip(Icons.pan_tool_alt_outlined, 'Drag the chart to pan'),
              tip(Icons.view_week_rounded, '↔ buttons change unit, ◀ ▶ step'),
              tip(Icons.mouse_outlined, 'Scroll or pinch to zoom'),
              tip(Icons.keyboard_rounded, 'Keyboard icon for all shortcuts'),
            ],
          ],
        ),
      ),
    );
  }
}
