import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../brand/brand.dart';
import '../../app.dart';
import '../pools/pools_page.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../widgets/conflict_dialog.dart';
import '../../data/sharing.dart';
import '../sharing/share_dialog.dart';
import '../../state/realtime_providers.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/pool_dialog.dart';
import '../../widgets/pool_picker.dart';
import '../../widgets/money_text.dart';
import '../../widgets/ui.dart';
import '../transactions/editor_outcome.dart';
import '../transactions/import_dialog.dart';
import '../planning/goal_models.dart';
import '../planning/scenarios_panel.dart' show scenarioColor;
import 'selection_period.dart';
import '../planning/goal_panel.dart';
import '../planning/plan_panel.dart';
import '../reminders/reminders_page.dart';
import '../transactions/transaction_editor.dart';
import '../transactions/transactions_panel.dart';
import 'balance_chart.dart';
import 'occurrence_info.dart';
import 'trim.dart';
import 'chart_geometry.dart';
import 'combined.dart';
import 'view_menu.dart';
import '../../state/auth_providers.dart';
import 'fit_ranges.dart';
import 'ghost_line.dart';
import 'view_units.dart';
import 'zoom_level.dart';
import '../../data/alert.dart';

class TimelinePage extends ConsumerStatefulWidget {
  const TimelinePage({super.key, required this.poolId});

  final String poolId;

  @override
  ConsumerState<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends ConsumerState<TimelinePage>
    with SingleTickerProviderStateMixin {
  /// Eases unit zoom steps and ◀ ▶; pans, pinches, wheel and fits are instant.
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

  /// Selected view unit per pool (kept while the app is open).

  /// Always one selected; − / + step through [ViewUnit.values].
  ViewUnit _unit = ViewUnit.month;

  late DateTime _dataFrom;
  late DateTime _dataTo;
  late DateTime _viewStart;
  double _visibleDays = ZoomLevel.week.visibleDays.toDouble();
  String? _windowPoolId;
  BalanceSeries? _seriesCache;

  /// Window [_seriesCache] was fetched for; shown while a wider one loads.
  BalanceQuery? _seriesCacheQuery;

  /// Other pools combined into this timeline (View menu), remembered per
  /// user per pool by [CombineStore].
  Set<String> _combine = {};
  String? _combineLoadedFor;
  static const _combineStore = CombineStore();

  /// Last complete combined view and the selection + window it was built
  /// for: kept on screen while a pan / zoom refetches the other pools.
  _Combined? _combinedCache;
  String? _combinedCacheKey;

  /// Bumped by "Fit" to refit the chart's balance range to the data in view.
  int _fitToken = 0;

  /// Bumped when the combined selection's line has loaded: the balance
  /// range eases to it; the date window stays exactly where it is.
  int _smoothFitToken = 0;
  int _zeroToken = 0;

  /// Docked planner (non-blocking) and its live preview line.
  bool _planOpen = false;

  /// Phone portrait: the planner opens full screen; "Show on chart" (or the
  /// target tool) docks it under the chart again for the live ghost line.
  bool _planOnChart = false;
  final _planPanelKey = GlobalKey(debugLabel: 'plan-panel');

  bool _isPortraitPhone(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width < 600 && size.height > size.width;
  }

  bool _planFull(BuildContext context) =>
      _planOpen && !_planOnChart && !_targetMode && _isPortraitPhone(context);
  PlanTab _planTab = PlanTab.goal;
  GhostLine? _planGhost;
  GhostLine? _goalGhost;
  int _previewSeq = 0;
  final _goalKey = GlobalKey<GoalPanelState>();

  /// Target point of the goal (end date, target balance) for the chart.
  (DateTime, double)? _goalTarget;

  /// Target tool: taps / drags on the chart set the goal target.
  bool _targetMode = false;

  /// Names and stores the goal request as a what-if (explicit button only).
  Future<void> _saveScenario(BuildContext context, GoalRequest req) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Save scenario'),
        content: TextField(
          key: const ValueKey('scenario-name'),
          controller: ctrl,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('scenario-save'),
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await ref
          .read(poolRepositoryProvider)
          .createScenario(widget.poolId, name: name.trim(), request: req);
      ref.invalidate(scenariosProvider(widget.poolId));
      if (mounted) setState(() => _planTab = PlanTab.scenarios);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Couldn’t save: $e')));
      }
    }
  }

  void _openPlan() => setState(() {
    _planOpen = true;
    _planOnChart = false;
  });

  /// Selection card "Plan…": open the goal tab over the selected range,
  /// starting from the balance on its first day, and solve the largest
  /// one-off that keeps the balance above the alert line (affordability).
  void _planPeriod(PeriodSummary p, double threshold) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = p.start.isBefore(today) ? today : p.start;
    final end = p.end.isAfter(start)
        ? p.end
        : start.add(const Duration(days: 30));
    setState(() {
      _planOpen = true;
      _planOnChart = false;
      _planTab = PlanTab.goal;
    });
    final req = GoalRequest(
      solveFor: GoalVar.oneOff,
      mode: GoalMode.floor,
      startDate: start,
      endDate: end,
      startBalance: start == p.start ? p.startBalance : null,
      targetBalance: threshold,
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _goalKey.currentState?.load(req),
    );
  }

  void _onTargetDrag(DateTime day, double balance) {
    // A goal can only land in the future: clamp past days to tomorrow.
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    if (day.isBefore(tomorrow)) day = tomorrow;
    final rounded = (balance / 10).roundToDouble() * 10;
    setState(() => _goalTarget = (day, rounded));
    _goalKey.currentState?.setTarget(day, rounded);
  }

  void _closePlan() => setState(() {
    _planOpen = false;
    _planGhost = null;
    _goalGhost = null;
    _goalTarget = null;
    _targetMode = false;
    _previewSeq++;
  });

  void _onGoalResult(GoalRequest req, GoalResult? r) {
    final v = r?.values;
    setState(() {
      _goalGhost = r == null || v == null
          ? null
          : GhostLine(
              points: r.points,
              color: AppTheme.planGhost,
              from: v.startDate,
              label: 'Goal',
            );
      final end = v?.endDate ?? req.endDate;
      final target = v?.targetBalance ?? req.targetBalance;
      _goalTarget = end == null || target == null ? null : (end, target);
    });
  }

  bool get _goalActive => _planOpen && _planTab == PlanTab.goal;

  List<GhostLine> get _ghosts => [
    for (final (sc, r)
        in ref.watch(scenarioResultsProvider(widget.poolId)).valueOrNull ??
            const <(Scenario, GoalResult?)>[])
      if (sc.included && r != null && r.values != null)
        GhostLine(
          points: r.points,
          color: scenarioColor(sc.colorIndex),
          from: r.values!.startDate,
          label: sc.name,
        ),
    if (_planOpen && _planTab == PlanTab.goal) ?_goalGhost,
    if (_planOpen && _planTab == PlanTab.payment) ?_planGhost,
  ];

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
          .read(poolRepositoryProvider)
          .project(
            widget.poolId,
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

  /// Server-side "last opened" (the pool may come from cache, so the GET
  /// alone is not enough). Best effort.
  void _markOpened(String id) {
    final notifier = ref.read(poolsProvider.notifier);
    notifier.lastPoolId = id;
    ref.read(poolRepositoryProvider).markOpened(id).catchError((Object _) {});
  }

  String? get _userId => ref.read(authProvider).valueOrNull?.user?.id;

  void _loadCombine(String poolId) {
    if (_combineLoadedFor == poolId) return;
    _combineLoadedFor = poolId;
    final uid = _userId;
    _combine = uid == null ? {} : _combineStore.load(uid, poolId);
    _combinedCache = null;
    _combinedCacheKey = null;
    _fittedSelection = '';
  }

  void _toggleCombine(String otherId) {
    setState(() {
      _combine = {..._combine};
      if (!_combine.remove(otherId)) _combine.add(otherId);
    });
    final uid = _userId;
    if (uid != null) _combineStore.save(uid, widget.poolId, _combine);
  }

  /// Every pool I can open other than this one, in my pools order, each
  /// with its stable tint.
  List<CombinedPool> _otherPools(String currentId) {
    final all = ref.watch(poolsProvider).valueOrNull ?? const <Pool>[];
    final others = [
      for (final p in all)
        if (p.id != currentId) p,
    ];
    return [
      for (final (i, p) in others.indexed)
        CombinedPool(
          id: p.id,
          name: p.name,
          color: combinedPoolColor(i),
          canEdit: p.role.canEdit,
        ),
    ];
  }

  /// The combined view for the checked pools, or null when none are
  /// checked (or the current series has not loaded). Pools whose data is
  /// still loading are waited for (the last complete view stays up).
  _Combined? _combined(Pool pool, BalanceSeries? series) {
    final q = _seriesCacheQuery;
    if (series == null || q == null || _combine.isEmpty) return null;
    final picked = [
      for (final p in _otherPools(pool.id))
        if (_combine.contains(p.id)) p,
    ];
    if (picked.isEmpty) return null;
    final current = CombinedPart(
      poolId: pool.id,
      seedDate: pool.seedDate,
      series: series,
      transactions:
          ref.watch(transactionsProvider(pool.id)).valueOrNull ??
          const <Transaction>[],
    );
    final parts = <CombinedPart>[];
    final used = <CombinedPool>[];
    var loading = false;
    for (final p in picked) {
      final b = ref.watch(
        balanceProvider(BalanceQuery(poolId: p.id, from: q.from, to: q.to)),
      );
      final txs = ref.watch(transactionsProvider(p.id));
      final full = ref.watch(poolProvider(p.id));
      if (b.hasError || txs.hasError || full.hasError) continue; // lost access
      final bv = b.valueOrNull, tv = txs.valueOrNull, pv = full.valueOrNull;
      if (bv == null || tv == null || pv == null || b.isLoading) {
        loading = true;
        continue;
      }
      used.add(p);
      parts.add(
        CombinedPart(
          poolId: p.id,
          seedDate: pv.seedDate,
          series: bv,
          transactions: tv,
        ),
      );
    }
    final selKey = (picked.map((p) => p.id).toList()..sort()).join(',');
    if (loading) {
      final cached = _combinedCache;
      if (cached != null && _combinedCacheKey == selKey) {
        return cached.copyWith(loading: true);
      }
      if (parts.isEmpty) {
        return _Combined.waiting(series, pool.seedDate, picked.length + 1);
      }
    }
    // Same inputs (by identity) as last time: reuse, so pans and zooms
    // don't re-sum every frame.
    final inputs = <Object>[
      current.series,
      current.transactions,
      for (final part in parts) ...[
        part.series,
        part.transactions,
        part.seedDate,
      ],
      for (final p in used) p,
    ];
    final memo = _comboMemo;
    if (memo != null &&
        memo.$1.length == inputs.length &&
        [
          for (var i = 0; i < inputs.length; i++)
            identical(memo.$1[i], inputs[i]) || memo.$1[i] == inputs[i],
        ].every((b) => b)) {
      final c = memo.$2.copyWith(loading: loading);
      if (!loading) {
        _combinedCache = c;
        _combinedCacheKey = selKey;
      }
      return c;
    }
    final c = _Combined(
      series: combineSeries(current, parts),
      lineStart: combinedLineStart(current, parts),
      pools: {for (final p in used) p.id: p},
      transactions: {
        for (final part in parts)
          for (final t in part.transactions) t.id: t,
      },
      count: picked.length + 1,
      loading: loading,
    );
    _comboMemo = (inputs, c);
    if (!loading) {
      _combinedCache = c;
      _combinedCacheKey = selKey;
    }
    return c;
  }

  (List<Object>, _Combined)? _comboMemo;

  /// The selection the balance range was last fitted for. Checking or
  /// unchecking a pool changes the line's scale, so once the new combined
  /// line has loaded the balance range eases to a refit (once); the date
  /// window is left exactly as it was.
  String _fittedSelection = '';

  void _refitOnCombineChange(_Combined? combo) {
    if (combo != null && combo.loading) return;
    final sel = combo == null
        ? ''
        : (combo.pools.keys.toList()..sort()).join(',');
    if (sel == _fittedSelection) return;
    _fittedSelection = sel;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _smoothFitToken++);
    });
  }

  /// "Edit in `pool`" from a combined dot (only offered with edit rights).
  Future<void> _openOther(
    BuildContext context,
    CombinedPool other,
    Transaction t,
    DateTime date,
  ) async {
    final q = _seriesCacheQuery;
    final otherSeries = q == null
        ? null
        : ref
              .read(
                balanceProvider(
                  BalanceQuery(poolId: other.id, from: q.from, to: q.to),
                ),
              )
              .valueOrNull;
    final result = await showTransactionEditor(
      context,
      poolId: other.id,
      existing: t,
      focusDate: date,
      skippedDates: {
        for (final o in otherSeries?.occurrences ?? const <Occurrence>[])
          if (o.transactionId == t.id && o.skipped) dateOnly(o.date),
      },
    );
    ref.invalidate(balanceProvider);
    ref.invalidate(todayBalanceProvider(other.id));
    ref.invalidate(insightsProvider(other.id));
    if (!context.mounted) return;
    reportEditorOutcome(
      context,
      ref,
      poolId: other.id,
      outcome: result,
      onChanged: () => ref.invalidate(balanceProvider),
    );
  }

  void _ensureWindow(Pool pool) {
    _loadCombine(pool.id);
    if (_windowPoolId == pool.id) return;
    _windowPoolId = pool.id;
    _markOpened(pool.id);
    _viewAnim.stop();
    _seriesCache = null;
    _seriesCacheQuery = null;
    // Every open starts on today at the default unit (never the last view,
    // a fit or the seed); Fit / Seed / Today stay explicit actions.
    final today = dateOnly(DateTime.now());
    _unit = ViewUnit.month;
    final v = initialView(today, _unit);
    _viewStart = v.start;
    _visibleDays = v.days;
    _dataFrom = addCalendarDays(_viewStart, -30);
    final horizon = math.max(120, _visibleDays.ceil());
    _dataTo = addCalendarDays(today, horizon);
  }

  BalanceQuery get _query =>
      BalanceQuery(poolId: widget.poolId, from: _dataFrom, to: _dataTo);

  Future<void> _openImport(BuildContext context, Pool pool) async {
    final result = await showImportDialog(context, poolId: pool.id);
    if (result == null || !context.mounted) return;
    ref.invalidate(transactionsProvider(widget.poolId));
    ref.invalidate(poolProvider(widget.poolId));
    _invalidateBalance();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
  }

  void _invalidateBalance() {
    ref.invalidate(balanceProvider(_query));
    ref.invalidate(todayBalanceProvider(widget.poolId));
    ref.invalidate(insightsProvider(widget.poolId));
  }

  final _chartAreaKey = GlobalKey();

  /// Start of a view that shows [day] at the left edge: its left edge just
  /// clear of the lane names / y labels floating over the plot's left strip,
  /// so the whole day is visible. Same span; the balance range is refitted.
  @visibleForTesting
  static DateTime leftAlignedStart(
    DateTime day,
    double visibleDays,
    double chartWidth,
  ) {
    final dayPx = chartWidth / math.max(visibleDays, 0.001);
    final inset = ChartLayout.laneNameWidth(chartWidth) / dayPx;
    return addDays(dateOnly(day), -inset);
  }

  double get _chartWidth {
    final box = _chartAreaKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.size.width
        : MediaQuery.sizeOf(context).width - 32;
  }

  /// First day fully clear of the left strip: what the date range label
  /// starts on (so a jumped-to day reads as the range start).
  DateTime get _firstClearDay {
    final w = _chartWidth;
    final inset = ChartLayout.laneNameWidth(w) * _visibleDays / w;
    return dateFromDayCoord(
      (dayCoord(_viewStart) + inset - 1e-6).ceilToDouble(),
    );
  }

  /// Every "go to a date" action (date picker, Today, Seed, locate from the
  /// transactions list): [day] at the left edge, then refit the balance.
  void _showFrom(DateTime day) {
    _onViewport(leftAlignedStart(day, _visibleDays, _chartWidth), _visibleDays);
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

  /// [ (-1) / ] (1) keys: one unit back / forward, snapped to unit starts
  /// and eased. Mid-animation it steps from the pending target, so rapid taps
  /// accumulate without drift.
  void _shift(int n) {
    final from = _viewAnim.isAnimating
        ? addDays(_animToCenter, -_animToDays / 2)
        : _viewStart;
    final span = _unit.step(from, n);
    // The balance (vertical) range is left untouched: no refit on landing.
    _animateViewport(addDays(span.start, span.days / 2), span.days);
  }

  void _setUnit(ViewUnit unit) {
    _unit = unit;
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
  void _fit(FitMode mode, Pool pool) {
    TimeSpan? span;
    switch (mode) {
      case FitMode.vertical:
        break;
      case FitMode.all:
      case FitMode.horizontal:
        final transactions =
            ref.read(transactionsProvider(widget.poolId)).valueOrNull ??
            const <Transaction>[];
        final range = poolDataRange(
          seedDate: pool.seedDate,
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

  /// Instant view change (pan, pinch, wheel, fits); cancels any easing.
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
    final poolAsync = ref.watch(poolProvider(widget.poolId));

    return poolAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _goBack(context),
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
      data: (pool) {
        _ensureWindow(pool);
        final balanceAsync = ref.watch(balanceProvider(_query));
        final liveSeries = balanceAsync.asData?.value;
        if (liveSeries != null) {
          _seriesCache = liveSeries;
          _seriesCacheQuery = _query;
        }
        final series = _seriesCache;
        final combo = _combined(pool, series);
        final shown = combo?.series ?? series;
        _refitOnCombineChange(combo);
        // Transaction names label the occurrence dots on the chart.
        final transactionNames = {
          for (final t in combo?.transactions.values ?? const <Transaction>[])
            t.id: transactionLabel(t),
          for (final transaction
              in ref.watch(transactionsProvider(widget.poolId)).asData?.value ??
                  const <Transaction>[])
            transaction.id: transactionLabel(transaction),
        };

        final transactions =
            ref.watch(transactionsProvider(widget.poolId)).valueOrNull ??
            const <Transaction>[];
        final todayPoint = series == null
            ? null
            : _closingNear(series.points, DateTime.now());

        final width = MediaQuery.sizeOf(context).width;
        final compact = width < 600;
        // Header tiers (desktop body from 600px): the phone-style actions
        // (Reminders, Transactions, More) below 960px; the insight chips
        // from 1240px and the Today tile from 960px, else a one-line
        // summary under the name.
        final compactActions = width < 960;
        return _withFullPlan(
          context,
          Scaffold(
            appBar: AppBar(
              toolbarHeight: compact ? 60 : 68,
              leading: IconButton(
                key: const ValueKey('timeline-back'),
                tooltip: 'All pools',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => _goBack(context),
              ),
              titleSpacing: compact ? 0 : 4,
              title: Row(
                children: [
                  _HeaderBrand(compact: compact),
                  Expanded(
                    child: _PoolHeader(
                      pool: pool,
                      todayPoint: todayPoint,
                      insights: ref
                          .watch(insightsProvider(widget.poolId))
                          .valueOrNull,
                      compact: compact,
                      showToday: !compactActions,
                      showInsights: width >= 1240,
                    ),
                  ),
                ],
              ),
              actions: compactActions
                  ? [
                      const RealtimeDot(),
                      IconButton(
                        key: const ValueKey('open-reminders'),
                        tooltip: 'Reminders calendar',
                        onPressed: () => showReminders(context, pool),
                        icon: const Icon(Icons.calendar_month_rounded),
                      ),
                      IconButton(
                        key: const ValueKey('open-transactions'),
                        tooltip: 'Transactions (${transactions.length})',
                        onPressed: () => _openTransactionsPanel(context, pool),
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
                              _openImport(context, pool);
                            case 'settings':
                              _editPool(context, pool);
                            case 'plan':
                              _openPlan();
                            case 'shortcuts':
                              _showShortcuts(context);
                            case 'share':
                              _share(context, pool);
                          }
                        },
                        // Pool settings first (editors), then sharing.
                        itemBuilder: (context) => [
                          if (pool.role.canEdit)
                            const PopupMenuItem(
                              key: ValueKey('more-settings'),
                              value: 'settings',
                              child: ListTile(
                                leading: Icon(Icons.tune_rounded),
                                title: Text('Pool settings'),
                              ),
                            ),
                          if (pool.role.isOwner)
                            const PopupMenuItem(
                              value: 'share',
                              child: ListTile(
                                leading: Icon(Icons.person_add_alt_1_outlined),
                                title: Text('Share pool'),
                              ),
                            ),
                          if (pool.role.canEdit) ...const [
                            PopupMenuItem(
                              value: 'import',
                              child: ListTile(
                                leading: Icon(Icons.file_upload_outlined),
                                title: Text('Import transactions'),
                              ),
                            ),
                          ],
                          const PopupMenuItem(
                            value: 'plan',
                            child: ListTile(
                              leading: Icon(Icons.calculate_outlined),
                              title: Text('Plan a payment'),
                            ),
                          ),
                          const PopupMenuItem(
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
                      const RealtimeDot(),
                      if (!pool.role.canEdit)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: Chip(
                            key: ValueKey('timeline-view-only'),
                            avatar: Icon(Icons.visibility_outlined, size: 16),
                            label: Text('View only'),
                          ),
                        ),
                      if (pool.role.isOwner)
                        IconButton(
                          key: const ValueKey('pool-share'),
                          tooltip: 'Share pool',
                          onPressed: () => _share(context, pool),
                          icon: const Icon(Icons.person_add_alt_1_outlined),
                        ),
                      if (pool.role.canEdit) ...[
                        IconButton(
                          tooltip: 'Import transactions (JSON)',
                          onPressed: () => _openImport(context, pool),
                          icon: const Icon(Icons.file_upload_outlined),
                        ),
                        IconButton(
                          key: const ValueKey('pool-settings'),
                          tooltip:
                              'Pool settings: seed balance, date, threshold',
                          onPressed: () => _editPool(context, pool),
                          icon: const Icon(Icons.tune_rounded),
                        ),
                      ],
                      IconButton(
                        key: const ValueKey('open-reminders'),
                        tooltip: 'Reminders calendar',
                        onPressed: () => showReminders(context, pool),
                        icon: const Icon(Icons.calendar_month_rounded),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton.icon(
                        key: const ValueKey('open-transactions'),
                        onPressed: () => _openTransactionsPanel(context, pool),
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
                        ? _compactToolbar(context, pool)
                        : _toolbar(context, pool),
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
                          key: _chartAreaKey,
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
                                      key: ValueKey(pool.id),
                                      fitToken: _fitToken,
                                      smoothFitToken: _smoothFitToken,
                                      zeroToken: _zeroToken,
                                      onFitRequested: (mode) =>
                                          _fit(mode, pool),
                                      onZoomStep: _zoomStep,
                                      onShift: _shift,
                                      series: shown!,
                                      seedDate: pool.seedDate,
                                      // Combined: no opening diamond (the
                                      // line is a sum, not this seed).
                                      seedBalance: combo != null
                                          ? null
                                          : pool.seedBalance.toDouble(),
                                      lineStart: combo?.lineStart,
                                      combinedPools: combo?.pools ?? const {},
                                      otherTransactions:
                                          combo?.transactions ?? const {},
                                      onOpenOtherTransaction: (
                                        other,
                                        t,
                                        date,
                                      ) => _openOther(context, other, t, date),
                                      lossThreshold: pool.lossThreshold
                                          .toDouble(),
                                      currencyScale: pool.currencyScale
                                          .toDouble(),
                                      viewStart: _viewStart,
                                      visibleDays: _visibleDays,
                                      onViewportChanged: _onChartViewport,
                                      onCreateOnDay: (day) => pool.role.canEdit
                                          ? _createOnceOnDay(context, day)
                                          : _viewOnlyToast(context),
                                      onTrimOnDay: pool.role.canEdit
                                          ? (t, day, removed) => _confirmTrim(
                                              context,
                                              t,
                                              day,
                                              removed,
                                            )
                                          : null,
                                      onEditTransaction: pool.role.canEdit
                                          ? (t, date) => _openEditor(
                                              context,
                                              pool,
                                              existing: t,
                                              focusDate: date,
                                            )
                                          : null,
                                      transactionNames: transactionNames,
                                      transactions: {
                                        for (final t in transactions) t.id: t,
                                      },
                                      dataFrom: _seriesCacheQuery?.from,
                                      dataThrough: _seriesCacheQuery?.to,
                                      ghosts: _ghosts,
                                      target: _goalActive ? _goalTarget : null,
                                      targetMode: _goalActive && _targetMode,
                                      onTargetChanged: _onTargetDrag,
                                      onAddForPeriod: pool.role.canEdit
                                          ? (start, end) => _openEditor(
                                              context,
                                              pool,
                                              initialDate: start,
                                              initialEndDate: end,
                                            )
                                          : null,
                                      onPlanPeriod: (p) => _planPeriod(
                                        p,
                                        pool.lossThreshold.toDouble(),
                                      ),
                                    ),
                                    if (_goalActive)
                                      Positioned(
                                        top: combo != null ? 44 : 8,
                                        right: 8,
                                        child: FilterChip(
                                          key: const ValueKey('target-tool'),
                                          avatar: const Icon(
                                            Icons.my_location_rounded,
                                            size: 16,
                                          ),
                                          label: Text(
                                            _targetMode
                                                ? 'Tap or drag to set target'
                                                : 'Set target',
                                          ),
                                          tooltip: 'Target tool: tap or drag on the chart to set the goal balance and date',
                                          selected: _targetMode,
                                          onSelected: (on) =>
                                              setState(() => _targetMode = on),
                                        ),
                                      ),
                                    if (combo != null)
                                      Positioned(
                                        top: 8,
                                        right: 8,
                                        child: _CombinedLegend(
                                          combo: combo,
                                          poolName: pool.name,
                                        ),
                                      ),
                                    if (balanceAsync.isLoading ||
                                        (combo?.loading ?? false))
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
          ),
        );
      },
    );
  }

  /// Docks the planner beside (desktop) or under (phone) the chart.
  /// Full-screen planner over the whole page on phone portrait. The page
  /// (chart included) stays mounted underneath, so the goal panel state and
  /// viewport survive switching to "Show on chart" and back.
  Widget _withFullPlan(BuildContext context, Widget page) {
    if (!_planFull(context)) return page;
    final pool = ref.read(poolProvider(widget.poolId)).valueOrNull;
    if (pool == null) return page;
    final goal = _planTab == PlanTab.goal;
    return Stack(
      children: [
        Offstage(child: page),
        Positioned.fill(
          child: Scaffold(
            key: const ValueKey('plan-fullscreen'),
            appBar: AppBar(
              leading: IconButton(
                key: const ValueKey('plan-full-close'),
                tooltip: 'Close planner',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _closePlan,
              ),
              titleSpacing: 0,
              title: Text(switch (_planTab) {
                PlanTab.goal => 'Plan a goal',
                PlanTab.payment => 'Plan a payment',
                PlanTab.scenarios => 'Scenarios',
              }),
              actions: [
                if (goal)
                  IconButton(
                    key: const ValueKey('plan-full-target'),
                    tooltip: 'Set target on the chart',
                    icon: const Icon(Icons.my_location_rounded),
                    onPressed: () => setState(() => _targetMode = true),
                  ),
                IconButton(
                  key: const ValueKey('plan-full-chart'),
                  tooltip: 'Show on chart',
                  icon: const Icon(Icons.show_chart_rounded),
                  onPressed: () => setState(() => _planOnChart = true),
                ),
                const SizedBox(width: 4),
              ],
            ),
            body: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: _planPanel(context, pool, compact: true, full: true),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _withPlanPanel(
    BuildContext context, {
    required bool compact,
    required Widget child,
  }) {
    if (!_planOpen || _planFull(context)) return child;
    final pool = ref.read(poolProvider(widget.poolId)).valueOrNull;
    if (pool == null) return child;
    final panel = _planPanel(context, pool, compact: compact);
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

  Widget _planPanel(
    BuildContext context,
    Pool pool, {
    required bool compact,
    bool full = false,
  }) {
    final portrait = _isPortraitPhone(context);
    return PlanPanel(
      key: _planPanelKey,
      fullScreen: full,
      onExpand: !full && portrait
          ? () => setState(() {
              _planOnChart = false;
              _targetMode = false;
            })
          : null,
      pool: pool,
      tab: _planTab,
      onTab: (t) => setState(() => _planTab = t),
      compact: compact,
      goalKey: _goalKey,
      onClose: _closePlan,
      onPreview: _onPlanPreview,
      onDone: (r) => _planDone(context, r),
      onGoalResult: _onGoalResult,
      onSaveScenario: (req) => _saveScenario(context, req),
      onLoadScenario: (sc) {
        setState(() => _planTab = PlanTab.goal);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _goalKey.currentState?.load(sc.request),
        );
      },
    );
  }

  // ---------------------------------------------------------------- toolbar

  /// Desktop toolbar. Condenses as the window narrows so nothing overflows
  /// (≥1060px: labelled buttons; narrower: Today / Seed / Plan become icon
  /// buttons; <760px: Today / Seed move into the View menu and the date
  /// range drops the year). The date range ellipsises as a last resort.
  Widget _toolbar(BuildContext context, Pool pool) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final full = w >= 1060;
        final narrow = w < 760;
        final end = lastVisibleDay(_viewStart, _visibleDays);
        String fmt(DateTime d) =>
            narrow ? DateFormat('d MMM').format(d) : _shortDate(d);
        Widget iconBtn(
          String key,
          String tip,
          IconData icon,
          VoidCallback f, {
          Color? color,
        }) => IconButton.outlined(
          key: ValueKey(key),
          tooltip: tip,
          onPressed: f,
          icon: Icon(icon, size: 18, color: color),
        );
        return Row(
          children: [
            _fitMenu(pool, compact: narrow),
            const SizedBox(width: 8),
            Flexible(
              child: Tooltip(
                message: 'Jump to a date',
                child: OutlinedButton.icon(
                  key: const ValueKey('jump-to-date'),
                  onPressed: () => _jumpToDate(context),
                  icon: const Icon(Icons.calendar_month_rounded, size: 18),
                  label: Text(
                    '${fmt(_firstClearDay)}  →  ${fmt(end)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            if (full) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const ValueKey('go-today'),
                onPressed: () => _showFrom(DateTime.now()),
                icon: const Icon(Icons.today_rounded, size: 18),
                label: const Text('Today'),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Go to the seed date (start of the balance)',
                child: OutlinedButton.icon(
                  key: const ValueKey('go-seed'),
                  onPressed: () => _showFrom(pool.seedDate),
                  icon: const Icon(
                    Icons.flag_rounded,
                    size: 18,
                    color: AppTheme.violet,
                  ),
                  label: const Text('Seed'),
                ),
              ),
            ] else if (!narrow) ...[
              const SizedBox(width: 6),
              iconBtn(
                'go-today',
                'Go to today',
                Icons.today_rounded,
                () => _showFrom(DateTime.now()),
              ),
              const SizedBox(width: 4),
              iconBtn(
                'go-seed',
                'Go to the seed date (start of the balance)',
                Icons.flag_rounded,
                () => _showFrom(pool.seedDate),
                color: AppTheme.violet,
              ),
            ],
            const Spacer(),
            if (full)
              Tooltip(
                message: 'Plan a payment or a balance goal',
                child: TextButton.icon(
                  key: const ValueKey('open-plan'),
                  onPressed: _openPlan,
                  icon: const Icon(Icons.calculate_outlined, size: 18),
                  label: const Text('Plan'),
                ),
              )
            else
              IconButton(
                key: const ValueKey('open-plan'),
                tooltip: 'Plan a payment or a balance goal',
                onPressed: _openPlan,
                icon: const Icon(Icons.calculate_outlined),
              ),
            IconButton(
              key: const ValueKey('shortcuts-help'),
              tooltip: 'Keyboard and mouse shortcuts',
              onPressed: () => _showShortcuts(context),
              icon: const Icon(Icons.keyboard_rounded),
            ),
          ],
        );
      },
    );
  }

  /// View options: Combine with other pools and, on phones, Go to today /
  /// seed date. The fit modes are keyboard-only (F / A / H, listed in the
  /// shortcuts sheet) and never stretch to the alert line.
  Widget _fitMenu(Pool pool, {required bool compact}) {
    final others = _otherPools(pool.id);
    final combined = others.where((p) => _combine.contains(p.id)).length;
    final small = Theme.of(context).textTheme.labelSmall;
    final tip = combined > 0
        ? 'View options · combined with $combined other pool${combined == 1 ? '' : 's'}'
        : 'View options';
    return ViewMenu(
      compact: compact,
      pools: others,
      combined: _combine,
      onToday: () => _showFrom(DateTime.now()),
      onSeed: () => _showFrom(pool.seedDate),
      onTogglePool: _toggleCombine,
      builder: (context, open) => compact
          ? IconButton(
              key: const ValueKey('fit-menu'),
              tooltip: tip,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              onPressed: open,
              icon: Badge(
                key: const ValueKey('combine-badge'),
                isLabelVisible: combined > 0,
                label: Text('${combined + 1}'),
                backgroundColor: AppTheme.accent,
                textColor: AppTheme.onAccent,
                child: const Icon(Icons.visibility_outlined),
              ),
            )
          : Tooltip(
              message: tip,
              child: OutlinedButton.icon(
                key: const ValueKey('fit-menu'),
                onPressed: open,
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('View'),
                    if (combined > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        key: const ValueKey('combine-badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.accent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${combined + 1}',
                          style: small?.copyWith(
                            color: AppTheme.onAccent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 2),
                    const Icon(Icons.expand_more_rounded, size: 18),
                  ],
                ),
              ),
            ),
    );
  }

  /// Phone toolbar: date range (tap to jump), plan, and the View menu
  /// (with Today / Seed). Everything is at least 44px tall.
  Widget _compactToolbar(BuildContext context, Pool pool) {
    final end = lastVisibleDay(_viewStart, _visibleDays);
    final fmt = DateFormat('d MMM yy');
    return Row(
      children: [
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
                '${fmt.format(_firstClearDay)} → ${fmt.format(end)}',
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
        _fitMenu(pool, compact: true),
      ],
    );
  }

  String _shortDate(DateTime d) => DateFormat('d MMM y').format(d);

  Future<void> _jumpToDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _firstClearDay,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
      helpText: 'Jump to date',
    );
    if (picked == null) return;
    _showFrom(picked);
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
    Pool pool, {
    Transaction? existing,
    DateTime? initialDate,
    DateTime? initialEndDate,
    DateTime? focusDate,
    bool onceOnly = false,
  }) async {
    final result = await showTransactionEditor(
      context,
      poolId: widget.poolId,
      existing: existing,
      initialDate: initialDate,
      initialEndDate: initialEndDate,
      focusDate: focusDate,
      onceOnly: onceOnly,
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
      poolId: widget.poolId,
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
    ref.invalidate(transactionsProvider(widget.poolId));
    _invalidateBalance();
  }

  Future<void> _editPool(BuildContext context, Pool pool) async {
    final edited = await showPoolDialog(
      context,
      existing: pool,
      transactionCount: ref
          .read(transactionsProvider(widget.poolId))
          .valueOrNull
          ?.length,
    );
    if (edited == null || !context.mounted) return;
    try {
      final n = ref.read(poolsProvider.notifier);
      final r = await saveWithConflictCheck(
        context,
        save: (force) => n.updatePool(edited, force: force),
        reload: n.refresh,
      );
      if (r == SaveResult.cancelled) return;
      ref.invalidate(poolProvider(widget.poolId));
      // A seed move shifts every schedule on the server.
      ref.invalidate(transactionsProvider(widget.poolId));
      _invalidateBalance();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Pool updated')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }

  void _goBack(BuildContext context) => context.go(poolsPath);

  void _viewOnlyToast(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('View only: you have viewer access to this pool'),
      ),
    );
  }

  Future<void> _share(BuildContext context, Pool pool) async {
    final left = await showShareDialog(
      context,
      ShareTarget.pool(pool.id, pool.name),
    );
    if (left && context.mounted) context.go('/');
  }

  /// Release in the chart's Trim zone: confirm, then end the series on
  /// [day] (inclusive, like the editor's "On date") through the normal
  /// versioned update, so a concurrent edit gets the Reload/Overwrite ask.
  Future<void> _confirmTrim(
    BuildContext context,
    Transaction t,
    DateTime day,
    int removed,
  ) async {
    final name = t.name.trim().isEmpty ? 'Transaction' : t.name.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('trim-dialog'),
        title: Text('Trim “$name”?'),
        content: Text(
          '“$name” will end on ${formatOccurrenceDate(day)}: an occurrence on '
          'that day still happens, later ones stop'
          '${removed > 0 ? ' ($removed in the loaded range)' : ''}.'
          '${t.endMode == EndMode.untilDate && t.endDate != null
              ? '\nCurrently ends ${formatOccurrenceDate(t.endDate!)}.'
              : t.endMode == EndMode.count
              ? '\nCurrently ends after ${t.occurrenceCount} times.'
              : '\nCurrently repeats forever.'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('trim-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Trim'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    // Latest copy (and version) of the series.
    final current =
        ref
            .read(transactionsProvider(widget.poolId))
            .valueOrNull
            ?.where((x) => x.id == t.id)
            .firstOrNull ??
        t;
    try {
      final n = ref.read(transactionsProvider(widget.poolId).notifier);
      final r = await saveWithConflictCheck(
        context,
        save: (force) =>
            n.updateTransaction(trimmedTransaction(current, day), force: force),
        reload: n.refresh,
      );
      if (r == SaveResult.cancelled) return;
      _invalidateBalance();
      if (context.mounted && r == SaveResult.saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('“$name” now ends ${formatOccurrenceDate(day)}'),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }

  Future<void> _createOnceOnDay(BuildContext context, DateTime day) async {
    final pool = ref.read(poolProvider(widget.poolId)).valueOrNull;
    if (pool == null) return;
    await _openEditor(context, pool, initialDate: day, onceOnly: true);
  }

  Future<void> _openTransactionsPanel(BuildContext context, Pool pool) async {
    await showSidePanel<void>(
      context,
      width: 520,
      label: 'Transactions',
      builder: (panelContext) => TransactionsPanel(
        pool: pool,
        skipsFor: _skipsFor,
        onPanelClosed: (outcome) {
          if (context.mounted) _report(context, outcome);
        },
        onLocate: (date) {
          Navigator.of(panelContext).pop();
          _showFrom(date);
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

class _PoolHeader extends StatelessWidget {
  const _PoolHeader({
    required this.pool,
    required this.todayPoint,
    this.insights,
    this.compact = false,
    bool? showToday,
    bool? showInsights,
  }) : showToday = showToday ?? !compact,
       showInsights = showInsights ?? !compact;

  final bool showToday;
  final bool showInsights;

  final Pool pool;
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
        'low ${formatMoneyAmount(i.lowestBalance!)} '
        '${short.format(i.lowestDate!)}',
      );
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = todayPoint?.closingBalance;
    final loss = today != null && belowAlert(today, pool.lossThreshold);
    return Row(
      children: [
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pool jump menu (same picker as transfers), with
              // New pool / Manage pools at the bottom.
              PoolPicker(
                keyPrefix: 'nav',
                title: 'Jump to pool',
                currentPoolId: pool.id,
                onSelected: (a) {
                  if (a.id == pool.id) return;
                  context.pushReplacement('/pools/${a.id}/timeline');
                },
                onNewPool: () async {
                  final created = await createPool(context);
                  if (created != null && context.mounted) {
                    context.go('/pools/${created.id}/timeline');
                  }
                },
                onManagePools: () => context.go(poolsPath),
                builder: (context, open) => InkWell(
                  key: const ValueKey('header-pool-picker'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: open,
                  child: Tooltip(
                    message: 'Jump to another pool',
                    waitDuration: const Duration(milliseconds: 500),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            pool.name,
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
              if (!showToday && today != null)
                Text(
                  [
                    'Today ${formatMoneyAmount(today.toDouble(), decimalDigits: 2)}',
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
                  'Seed ${formatMoneyAmount(pool.seedBalance.toDouble(), decimalDigits: 2)} on ${DateFormat('d MMM y').format(pool.seedDate)}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        if (insights != null && showInsights) ...[
          const SizedBox(width: 10),
          _InsightChip(
            key: const ValueKey('header-lowest'),
            label: 'LOWEST · 12 MO',
            value: insights!.lowestBalance == null
                ? '—'
                : formatMoneyAmount(insights!.lowestBalance!),
            detail: insights!.lowestDate == null
                ? null
                : DateFormat('d MMM y').format(insights!.lowestDate!),
            warn:
                insights!.lowestBalance != null &&
                belowAlert(
                  insights!.lowestBalance!,
                  pool.lossThreshold.toDouble(),
                ),
          ),
          const SizedBox(width: 8),
          _InsightChip(
            key: const ValueKey('header-runway'),
            label: 'RUNWAY',
            value: runwayText(insights!, pool),
            detail: insights!.alertDate == null
                ? null
                : 'alert < ${formatMoneyAmount(pool.lossThreshold.toDouble())}',
            warn: insights!.alertDate != null,
          ),
        ],
        if (today != null && showToday) ...[
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
                  formatMoneyAmount(today.toDouble(), decimalDigits: 2),
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
String runwayText(BalanceInsights i, Pool pool) {
  final fmt = DateFormat('d MMM y');
  final alert = i.alertDate;
  if (alert == null) {
    return 'OK ${(i.horizonDays / 365).round()}+ yrs';
  }
  final today = dateOnly(DateTime.now());
  if (!alert.isAfter(today)) return 'Below alert now';
  final zero = i.zeroDate;
  if (zero != null && zero != alert && pool.lossThreshold.toDouble() != 0) {
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
        edge: warn
            ? AppTheme.debitColor.withValues(alpha: 0.4)
            : AppTheme.border,
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
    final tips = [
      if (compact) ...[
        tip(Icons.ads_click_rounded, 'Tap near a dot for details'),
        tip(Icons.add_circle_outline_rounded, 'Tap or drag the dates to add'),
        tip(Icons.touch_app_outlined, 'Drag near dots for details'),
        tip(Icons.pinch_outlined, 'Pinch to zoom'),
      ] else ...[
        tip(Icons.ads_click_rounded, 'Click or tap a dot for details'),
        tip(Icons.swipe_right_alt_rounded, 'Drag or tap the dates to add'),
        tip(Icons.pan_tool_alt_outlined, 'Drag the chart to pan'),
        tip(Icons.view_week_rounded, 'Pinch or − / + change unit, [ ] step'),
        tip(Icons.mouse_outlined, 'Scroll or pinch to zoom'),
        tip(Icons.keyboard_rounded, 'Keyboard icon for all shortcuts'),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: compact
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: tips),
            )
          // Desktop: one line of whole tips; those that don't fit wrap onto
          // a clipped second line (hidden) instead of being cut mid-word.
          : SizedBox(
              key: const ValueKey('tips-bar'),
              height: 18,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  maxHeight: double.infinity,
                  child: Wrap(children: tips),
                ),
              ),
            ),
    );
  }
}

/// Opening view: one [unit] wide, centred on [today].
({DateTime start, double days}) initialView(DateTime today, ViewUnit unit) {
  final days = unit.spanContaining(today).days.toDouble();
  return (start: addDays(dateOnly(today), 0.5 - days / 2), days: days);
}

/// The timeline's combined view (see [combineSeries]).
class _Combined {
  const _Combined({
    required this.series,
    required this.lineStart,
    required this.pools,
    required this.transactions,
    required this.count,
    this.loading = false,
  });

  /// Nothing loaded yet for the checked pools: the current pool alone,
  /// with the indicator and a progress bar.
  _Combined.waiting(this.series, DateTime seedDate, this.count)
    : lineStart = seedDate,
      pools = const {},
      transactions = const {},
      loading = true;

  final BalanceSeries series;
  final DateTime lineStart;
  final Map<String, CombinedPool> pools;
  final Map<String, Transaction> transactions;

  /// Pools in the view, this one included ("Combined: 3 pools").
  final int count;
  final bool loading;

  _Combined copyWith({required bool loading}) => _Combined(
    series: series,
    lineStart: lineStart,
    pools: pools,
    transactions: transactions,
    count: count,
    loading: loading,
  );
}

/// "Combined: N pools" over the chart, with each pool's tint (legend).
class _CombinedLegend extends StatelessWidget {
  const _CombinedLegend({required this.combo, required this.poolName});

  final _Combined combo;
  final String poolName;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.labelSmall ?? const TextStyle();
    Widget dot(Color c) => Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
    final names = [poolName, for (final p in combo.pools.values) p.name];
    return Tooltip(
      message:
          'Balance line is the sum of: ${names.join(', ')}.\n'
          'Transfers between them net out. + and Trim add to $poolName.',
      child: Container(
        key: const ValueKey('combined-indicator'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: AppTheme.panel(color: AppTheme.overlay, r: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.stacked_line_chart_rounded,
              size: 14,
              color: AppTheme.accent,
            ),
            const SizedBox(width: 6),
            Text(
              'Combined: ${combo.count} pools',
              style: small.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            dot(AppTheme.accent),
            for (final p in combo.pools.values) dot(p.color),
          ],
        ),
      ),
    );
  }
}

/// The Budgie icon (rounded tile, no wordmark) at the left of the
/// timeline header, between the back button and the pool name: sized to
/// the header row, a little smaller on phones. The landing intro glides
/// into it.
class _HeaderBrand extends StatelessWidget {
  const _HeaderBrand({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsetsDirectional.only(end: compact ? 10 : 12),
    child: Semantics(
      label: 'Budgie',
      image: true,
      child: BrandAnchor(
        key: const ValueKey('timeline-brand'),
        child: BudgieIcon(size: compact ? 26 : 32),
      ),
    ),
  );
}
