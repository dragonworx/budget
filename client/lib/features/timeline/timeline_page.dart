import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../boot/page_stub.dart'
    if (dart.library.js_interop) '../../boot/page_web.dart'
    as page;
import '../../brand/brand.dart';
import '../../app.dart';
import '../streams/streams_page.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/repositories.dart' show StreamRepository;
import '../../widgets/conflict_dialog.dart';
import '../../data/sharing.dart';
import '../sharing/share_dialog.dart';
import '../../state/realtime_providers.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/stream_dialog.dart';
import '../../widgets/list_glyph.dart';
import '../../widgets/stream_picker.dart';
import '../../widgets/ui.dart';
import '../events/editor_outcome.dart';
import '../events/import_dialog.dart';
import '../planning/goal_models.dart';
import '../planning/scenarios_panel.dart' show scenarioColor;
import 'selection_period.dart';
import '../planning/goal_panel.dart';
import '../planning/plan_panel.dart';
import '../reminders/reminders_page.dart';
import '../events/event_editor.dart';
import '../events/events_panel.dart';
import 'balance_chart.dart';
import 'trim.dart';
import '../../widgets/confirm_dialog.dart';
import 'chart_geometry.dart';
import 'combined.dart';
import 'date_heatmap.dart';
import 'view_menu.dart';
import '../../state/auth_providers.dart';
import '../../state/stream_cleanup.dart';
import '../../state/app_prefs.dart';
import 'dock_split.dart';
import 'fit_ranges.dart';
import 'ghost_line.dart';
import 'saved_view.dart';
import 'view_units.dart';
import 'zoom_level.dart';
import 'occurrence_info.dart';

class TimelinePage extends ConsumerStatefulWidget {
  const TimelinePage({super.key, required this.streamId});

  final String streamId;

  @override
  ConsumerState<TimelinePage> createState() => _TimelinePageState();
}

/// Docked Events list: wide landscape screens (desktop, landscape
/// tablet) only; smaller ones keep the overlay panel.
const double dockedListMinWidth = 1024;

/// Tests: false lays the timeline out as on smaller screens (overlay list).
@visibleForTesting
bool dockedListEnabled = true;

/// The docked list starts open unless this browser closed it.
@visibleForTesting
bool dockedListDefaultOpen = true;

/// Eased show / hide of the docked list.
const Duration dockedListDuration = Duration(milliseconds: 280);

class _TimelinePageState extends ConsumerState<TimelinePage>
    with TickerProviderStateMixin {
  /// Eases unit zoom steps and ◀ ▶; pans, pinches, wheel and fits are instant.
  late final AnimationController _viewAnim = AnimationController(
    vsync: this,
    duration: zoomEaseDuration,
  )..addListener(_tickView);
  DateTime _animFromCenter = DateTime(2000);
  DateTime _animToCenter = DateTime(2000);
  double _animFromDays = 1;
  double _animToDays = 1;

  // ---- Docked Events list (wide landscape screens). ----

  // Was `budget_tx_docked` (moved by migrateLegacyLocalKeys).
  static const _dockStoreKey = 'budget_events_docked';

  /// Open / closed, remembered per browser.
  late bool _dockOpen = switch (page.localGet(_dockStoreKey)) {
    '1' => true,
    '0' => false,
    _ => dockedListDefaultOpen,
  };

  /// Drives the panel's width (the chart repaints into what is left).
  late final AnimationController _dockAnim = AnimationController(
    vsync: this,
    duration: dockedListDuration,
    value: _dockOpen ? 1 : 0,
  );
  late final Animation<double> _dockCurve = CurvedAnimation(
    parent: _dockAnim,
    curve: Curves.easeInOutCubic,
  );

  /// Wide landscape: the list docks beside the timeline. While the planner
  /// is docked there instead, the list falls back to the overlay.
  bool _dockable(BuildContext context) {
    if (!dockedListEnabled) return false;
    final size = MediaQuery.sizeOf(context);
    return size.width >= dockedListMinWidth &&
        size.width > size.height &&
        !(_planOpen && !_planFull(context));
  }

  /// Width dragged on this device (px; null: the default). Kept as chosen
  /// and clamped to the window when used, so a narrower window never
  /// overwrites it.
  double? _dockWidthPref = appPrefs.getDouble(PrefKeys.dockedListWidth);

  void _toggleDock() {
    setState(() => _dockOpen = !_dockOpen);
    page.localSet(_dockStoreKey, _dockOpen ? '1' : '0');
    if (_dockOpen) {
      _dockAnim.forward();
    } else {
      _dockAnim.reverse();
    }
  }

  /// [child] (the timeline) with the docked list on its right. The panel
  /// keeps its width and is revealed / clipped, so only the timeline
  /// relayouts while it eases; the date window and balance range stay.
  Widget _withDockedList(
    BuildContext context,
    BudgetStream stream,
    Widget child,
  ) {
    if (!_dockable(context)) return child;
    // The splitter sits in the 16px gap between the timeline card and the
    // list (the timeline's own right padding, no chart under it) and slides
    // with the list as it eases in / out.
    return DockSplit(
      reveal: _dockCurve,
      open: _dockOpen,
      savedWidth: _dockWidthPref,
      onWidthChanged: (w) {
        appPrefs.setDouble(PrefKeys.dockedListWidth, w);
        setState(() => _dockWidthPref = w);
      },
      onReset: () {
        appPrefs.remove(PrefKeys.dockedListWidth);
        setState(() => _dockWidthPref = null);
      },
      timeline: child,
      panel: RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.border),
            ),
            child: TickerMode(
              enabled: _dockOpen || _dockAnim.isAnimating,
              child: _eventsPanel(context, stream, docked: true),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _dockAnim.dispose();
    _flushView(keepalive: true);
    final h = _hiddenHandle;
    if (h != null) page.offPageHidden(h);
    _viewAnim.dispose();
    super.dispose();
  }

  // ---- Saved view: each member's last view of each stream (server, per
  // user per stream; cached in local storage for an instant restore). ----

  static const _viewStore = SavedViewStore();

  /// How long the view must stay still before it is saved.
  static const viewSaveDelay = Duration(seconds: 1);

  late final StreamRepository _viewRepo;
  Object? _hiddenHandle;
  Timer? _viewSaveTimer;

  /// The stream / user the view state below belongs to.
  String? _viewStreamId;
  String? _viewUid;

  /// Last view saved or restored (or the untouched default): a view equal
  /// to it is not saved again.
  SavedView? _viewSaved;

  /// The view was moved since this stream opened (a late server copy no
  /// longer replaces it).
  bool _viewTouched = false;

  /// Latest balance range the chart reported.
  BalanceExtents? _chartY;

  /// Saved balance range for the chart, applied when [_yRestoreToken] bumps.
  BalanceExtents? _restoreY;
  int _yRestoreToken = 0;

  SavedView get _currentView => SavedView(
    start: dayCoord(_viewStart),
    days: _visibleDays,
    unit: _unit,
    yMin: _chartY?.min,
    yMax: _chartY?.max,
  );

  /// The view changed: save it once it has been still for [viewSaveDelay]
  /// (a drag / pinch / ease keeps pushing the save back; never per frame).
  void _viewChanged() {
    if (_viewStreamId == null) return;
    _viewSaveTimer?.cancel();
    if (_currentView.sameAs(_viewSaved)) return;
    _viewSaveTimer = Timer(viewSaveDelay, () => _flushView());
  }

  /// Saves the current view now if it changed. [keepalive]: the page is
  /// being hidden / left, so the request must outlive it.
  void _flushView({bool keepalive = false}) {
    _viewSaveTimer?.cancel();
    _viewSaveTimer = null;
    final streamId = _viewStreamId, uid = _viewUid;
    // A deleted stream's view is not written back as its page closes.
    if (streamId == null || isForgottenStream(streamId)) return;
    final view = _currentView;
    if (view.sameAs(_viewSaved)) return;
    _viewSaved = view;
    if (uid != null) _viewStore.save(uid, streamId, view);
    _viewRepo
        .saveView(streamId, view, keepalive: keepalive)
        .catchError((Object _) {});
  }

  void _onChartY(BalanceExtents y) {
    _chartY = y;
    // The first fit of an untouched default view is not a change: a stream
    // never moved keeps opening on today.
    if (_viewSaved == null && !_viewTouched) {
      _viewSaved = _currentView;
      return;
    }
    if (!_currentView.sameAs(_viewSaved)) _viewTouched = true;
    _viewChanged();
  }

  /// Shows [v] (a saved view) instead of the default.
  void _applySavedView(SavedView v) {
    _viewStart = v.startDate;
    _visibleDays = v.days;
    _unit = v.unit ?? ViewUnit.nearest(v.days);
    final (from, to) = _dataWindowFor(_viewStart, _visibleDays);
    _dataFrom = from;
    _dataTo = to;
    _restoreY = v.yRange;
    _chartY = v.yRange;
    _yRestoreToken++;
    _viewSaved = v;
  }

  /// The server's copy (another device may have moved it since this
  /// browser's copy). Replaces the view only while it is untouched.
  Future<void> _fetchSavedView(String streamId) async {
    try {
      final v = await _viewRepo.loadView(streamId);
      if (!mounted || v == null || _viewStreamId != streamId || _viewTouched) {
        return;
      }
      if (v.sameAs(_viewSaved)) return;
      final uid = _viewUid;
      if (uid != null) _viewStore.save(uid, streamId, v);
      _viewAnim.stop();
      setState(() => _applySavedView(v));
    } catch (_) {
      // Offline or failed: keep the local / default view.
    }
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

  /// Selected view unit per stream (kept while the app is open).

  /// Always one selected; − / + step through [ViewUnit.values].
  ViewUnit _unit = ViewUnit.month;

  late DateTime _dataFrom;
  late DateTime _dataTo;
  late DateTime _viewStart;
  double _visibleDays = ZoomLevel.week.visibleDays.toDouble();
  String? _windowStreamId;
  BalanceSeries? _seriesCache;

  /// Window [_seriesCache] was fetched for; shown while a wider one loads.
  BalanceQuery? _seriesCacheQuery;

  /// Other streams combined into this timeline (View menu), remembered per
  /// user per stream by [CombineStore].
  Set<String> _combine = {};
  String? _combineLoadedFor;
  static const _combineStore = CombineStore();

  /// Last complete combined view and the selection + window it was built
  /// for: kept on screen while a pan / zoom refetches the other streams.
  _Combined? _combinedCache;
  String? _combinedCacheKey;

  /// Bumped by "Fit" to refit the chart's balance range to the data in view.
  int _fitToken = 0;

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
          .read(streamRepositoryProvider)
          .createScenario(widget.streamId, name: name.trim(), request: req);
      ref.invalidate(scenariosProvider(widget.streamId));
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
        in ref.watch(scenarioResultsProvider(widget.streamId)).valueOrNull ??
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
  Future<void> _onPlanPreview(BudgetEvent? t) async {
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
          .read(streamRepositoryProvider)
          .project(
            widget.streamId,
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
    _viewRepo = ref.read(streamRepositoryProvider);
    _hiddenHandle = page.onPageHidden(() => _flushView(keepalive: true));
    final today = dateOnly(DateTime.now());
    _viewStart = addCalendarDays(today, -7);
    _dataFrom = addCalendarDays(_viewStart, -30);
    _dataTo = addCalendarDays(today, 120);
  }

  /// Server-side "last opened" (the stream may come from cache, so the GET
  /// alone is not enough). Best effort.
  void _markOpened(String id) {
    final notifier = ref.read(streamsProvider.notifier);
    notifier.lastStreamId = id;
    ref.read(streamRepositoryProvider).markOpened(id).catchError((Object _) {});
  }

  String? get _userId => ref.read(authProvider).valueOrNull?.user?.id;

  void _loadCombine(String streamId) {
    if (_combineLoadedFor == streamId) return;
    _combineLoadedFor = streamId;
    final uid = _userId;
    _combine = uid == null ? {} : _combineStore.load(uid, streamId);
    _combinedCache = null;
    _combinedCacheKey = null;
  }

  void _toggleCombine(String otherId) {
    setState(() {
      _combine = {..._combine};
      if (!_combine.remove(otherId)) _combine.add(otherId);
    });
    final uid = _userId;
    if (uid != null && !isForgottenStream(widget.streamId)) {
      _combineStore.save(uid, widget.streamId, _combine);
    }
  }

  /// Every stream I can open other than this one, in my streams order, each
  /// with its stable tint.
  List<CombinedStream> _otherStreams(String currentId) {
    final all =
        ref.watch(streamsProvider).valueOrNull ?? const <BudgetStream>[];
    final others = [
      for (final p in all)
        if (p.id != currentId) p,
    ];
    return [
      for (final (i, p) in others.indexed)
        CombinedStream(
          id: p.id,
          name: p.name,
          color: combinedStreamColor(i),
          canEdit: p.role.canEdit,
        ),
    ];
  }

  /// Combined view: the other streams' event ids for the stacked lanes,
  /// stream by stream in the streams' order, each in that stream's list order (its
  /// saved order, then the rest as loaded).
  List<String> _otherLaneOrder(_Combined combo) {
    final out = <String>[];
    for (final p in combo.streams.values) {
      final order =
          ref.watch(streamProvider(p.id)).valueOrNull?.eventOrder ??
          const <String>[];
      final own = {
        for (final e in combo.events.entries)
          if (e.value.streamId == p.id) e.key,
      };
      out.addAll([
        for (final id in order)
          if (own.remove(id)) id,
        ...own,
      ]);
    }
    return out;
  }

  /// The combined view for the checked streams, or null when none are
  /// checked (or the current series has not loaded). Streams whose data is
  /// still loading are waited for (the last complete view stays up).
  _Combined? _combined(BudgetStream stream, BalanceSeries? series) {
    final q = _seriesCacheQuery;
    if (series == null || q == null || _combine.isEmpty) return null;
    final picked = [
      for (final p in _otherStreams(stream.id))
        if (_combine.contains(p.id)) p,
    ];
    if (picked.isEmpty) return null;
    final current = CombinedPart(
      streamId: stream.id,
      seedDate: stream.seedDate,
      series: series,
      events:
          ref.watch(eventsProvider(stream.id)).valueOrNull ??
          const <BudgetEvent>[],
    );
    final parts = <CombinedPart>[];
    final used = <CombinedStream>[];
    var loading = false;
    for (final p in picked) {
      final b = ref.watch(
        balanceProvider(BalanceQuery(streamId: p.id, from: q.from, to: q.to)),
      );
      final txs = ref.watch(eventsProvider(p.id));
      final full = ref.watch(streamProvider(p.id));
      if (b.hasError || txs.hasError || full.hasError) continue; // lost access
      final bv = b.valueOrNull, tv = txs.valueOrNull, pv = full.valueOrNull;
      if (bv == null || tv == null || pv == null || b.isLoading) {
        loading = true;
        continue;
      }
      used.add(p);
      parts.add(
        CombinedPart(
          streamId: p.id,
          seedDate: pv.seedDate,
          series: bv,
          events: tv,
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
        return _Combined.waiting(series, stream.seedDate, picked.length + 1);
      }
    }
    // Same inputs (by identity) as last time: reuse, so pans and zooms
    // don't re-sum every frame.
    final inputs = <Object>[
      current.series,
      current.events,
      for (final part in parts) ...[part.series, part.events, part.seedDate],
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
      streams: {for (final p in used) p.id: p},
      events: {
        for (final part in parts)
          for (final t in part.events) t.id: t,
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

  /// "Edit in `stream`" from a combined dot (only offered with edit rights).
  Future<void> _openOther(
    BuildContext context,
    CombinedStream other,
    BudgetEvent t,
    DateTime date,
  ) async {
    final q = _seriesCacheQuery;
    final otherSeries = q == null
        ? null
        : ref
              .read(
                balanceProvider(
                  BalanceQuery(streamId: other.id, from: q.from, to: q.to),
                ),
              )
              .valueOrNull;
    final result = await showEventEditor(
      context,
      streamId: other.id,
      existing: t,
      focusDate: date,
      skippedDates: {
        for (final o in otherSeries?.occurrences ?? const <Occurrence>[])
          if (o.eventId == t.id && o.skipped) dateOnly(o.date),
      },
    );
    ref.invalidate(balanceProvider);
    ref.invalidate(todayBalanceProvider(other.id));
    ref.invalidate(insightsProvider(other.id));
    if (!context.mounted) return;
    reportEditorOutcome(
      context,
      ref,
      streamId: other.id,
      outcome: result,
      onChanged: () => ref.invalidate(balanceProvider),
    );
  }

  void _ensureWindow(BudgetStream stream) {
    _loadCombine(stream.id);
    if (_windowStreamId == stream.id) return;
    _windowStreamId = stream.id;
    _markOpened(stream.id);
    _viewAnim.stop();
    _seriesCache = null;
    _seriesCacheQuery = null;
    // Leaving another stream: save where it was left first.
    _flushView();
    _viewStreamId = stream.id;
    _viewUid = _userId;
    _viewSaved = null;
    _viewTouched = false;
    _chartY = null;
    _restoreY = null;
    // Reopening restores my last view of this stream (this browser's copy
    // now, the server's when it arrives). Otherwise: today at the default
    // unit, $0 a third of the way up.
    final uid = _viewUid;
    final cached = uid == null ? null : _viewStore.load(uid, stream.id);
    if (cached != null) {
      _applySavedView(cached);
    } else {
      final today = dateOnly(DateTime.now());
      _unit = ViewUnit.month;
      final v = initialView(today, _unit);
      _viewStart = v.start;
      _visibleDays = v.days;
      _dataFrom = addCalendarDays(_viewStart, -30);
      final horizon = math.max(120, _visibleDays.ceil());
      _dataTo = addCalendarDays(today, horizon);
    }
    _fetchSavedView(stream.id);
  }

  BalanceQuery get _query =>
      BalanceQuery(streamId: widget.streamId, from: _dataFrom, to: _dataTo);

  /// The day selected on the date lane (pinned pick bubble): the date root
  /// imports count their day offsets from. Null when none is selected.
  DateTime? _pinnedDay;

  /// Go to today / seed also select that day on the date lane (as a tap
  /// there does): [_selectDay] each time [_selectDayToken] changes.
  DateTime? _selectDay;
  int _selectDayToken = 0;

  /// Today / Seed: show [day] from the left edge, then select it.
  void _goToAndSelect(DateTime day) {
    _showFrom(day);
    setState(() {
      _selectDay = dateOnly(day);
      _selectDayToken++;
    });
  }

  void _onPinnedDay(DateTime? day) {
    if (!mounted || day == _pinnedDay) return;
    setState(() => _pinnedDay = day);
  }

  /// Import needs a selected day (the root of its day offsets); without one
  /// it only explains how to select one.
  Future<void> _openImport(BuildContext context, BudgetStream stream) async {
    final root = _pinnedDay;
    if (root == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(importNeedsDayHint)));
      return;
    }
    final result = await showImportDialog(
      context,
      streamId: stream.id,
      root: root,
    );
    if (result == null || !mounted) return;
    _refreshAfterImport();
    // The undo bar says what happened and stays up (no timeout) until Undo
    // or its close box. A newer import replaces it.
    setState(() {
      _importUndo = result.createdIds.isEmpty
          ? null
          : _ImportUndo(widget.streamId, result);
      _importUndoError = null;
    });
    if (result.createdIds.isEmpty && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.message)));
    }
  }

  void _refreshAfterImport() {
    ref.invalidate(eventsProvider(widget.streamId));
    ref.invalidate(streamProvider(widget.streamId));
    _invalidateBalance();
  }

  /// The last import, while its undo bar is up. Page state, so leaving this
  /// stream's timeline (another stream, the stream list) dismisses it: its Undo
  /// only ever acts on the stream on screen.
  _ImportUndo? _importUndo;
  bool _undoingImport = false;
  String? _importUndoError;

  /// Undo: one bulk delete of exactly the ids that import created (one DB
  /// event server-side: all of them or none).
  Future<void> _undoImport() async {
    final u = _importUndo;
    if (u == null || _undoingImport) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _undoingImport = true;
      _importUndoError = null;
    });
    try {
      final res = await ref
          .read(eventRepositoryProvider)
          .undoImport(u.streamId, u.result.createdIds);
      if (!mounted) return;
      final deleted = res['deleted'] as int? ?? 0;
      final missing = (res['missing'] as List?)?.length ?? 0;
      setState(() {
        _undoingImport = false;
        if (identical(_importUndo, u)) _importUndo = null;
      });
      _refreshAfterImport();
      messenger.showSnackBar(
        SnackBar(
          key: const ValueKey('import-undone'),
          content: Text(
            missing == 0
                ? 'Import undone'
                : 'Import undone: removed $deleted; '
                      '$missing ${missing == 1 ? 'was' : 'were'} already gone',
          ),
        ),
      );
    } catch (error) {
      // The server deletes all or nothing: nothing changed, so the bar
      // stays with the error and Undo can be retried.
      if (!mounted) return;
      setState(() {
        _undoingImport = false;
        _importUndoError =
            'Undo failed: ${friendlyError(error)}. Nothing was removed.';
      });
    }
  }

  Widget _withImportUndo(Widget page) {
    final u = _importUndo;
    final show = u != null && u.streamId == widget.streamId;
    final pad = MediaQuery.viewPaddingOf(context).bottom;
    // Always the same Stack (the page keeps its element and state when the
    // bar comes and goes).
    return Stack(
      children: [
        Positioned.fill(child: page),
        if (show)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12 + pad,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: _ImportUndoBar(
                  message: _importUndoError ?? u.result.message,
                  error: _importUndoError != null,
                  busy: _undoingImport,
                  onUndo: _undoImport,
                  onClose: () => setState(() {
                    _importUndo = null;
                    _importUndoError = null;
                  }),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Bumped by every user edit of this stream's data; see
  /// [BalanceChart.dataEditToken].
  int _dataEditToken = 0;

  void _invalidateBalance() {
    _dataEditToken++;
    ref.invalidate(balanceProvider(_query));
    ref.invalidate(todayBalanceProvider(widget.streamId));
    ref.invalidate(insightsProvider(widget.streamId));
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
  /// events list): [day] at the left edge, then refit the balance.
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
  void _fit(FitMode mode, BudgetStream stream) {
    TimeSpan? span;
    switch (mode) {
      case FitMode.vertical:
        break;
      case FitMode.all:
      case FitMode.horizontal:
        final events =
            ref.read(eventsProvider(widget.streamId)).valueOrNull ??
            const <BudgetEvent>[];
        final range = streamDataRange(
          seedDate: stream.seedDate,
          events: events,
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

  (DateTime, DateTime) _dataWindowFor(DateTime start, double days) =>
      nextDataWindow(_dataFrom, _dataTo, start, days);

  void _applyViewport(DateTime start, double visibleDays) {
    final days = visibleDays.clamp(minVisibleDays, maxVisibleDays).toDouble();
    final (from, to) = _dataWindowFor(start, days);
    setState(() {
      _viewStart = start;
      _visibleDays = days;
      _dataFrom = from;
      _dataTo = to;
    });
    _viewTouched = true;
    _viewChanged();
  }

  @override
  Widget build(BuildContext context) {
    final streamAsync = ref.watch(streamProvider(widget.streamId));

    return streamAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => _isGone(error)
          ? _StreamGone(streamId: widget.streamId)
          : Scaffold(
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
                  child: Text(
                    friendlyError(error),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
      data: (stream) {
        _ensureWindow(stream);
        final balanceAsync = ref.watch(balanceProvider(_query));
        final liveSeries = balanceAsync.asData?.value;
        if (liveSeries != null) {
          _seriesCache = liveSeries;
          _seriesCacheQuery = _query;
        }
        final series = _seriesCache;
        final combo = _combined(stream, series);
        final shown = combo?.series ?? series;
        // Event names label the occurrence dots on the chart.
        final eventNames = {
          for (final t in combo?.events.values ?? const <BudgetEvent>[])
            t.id: eventLabel(t),
          for (final event
              in ref.watch(eventsProvider(widget.streamId)).asData?.value ??
                  const <BudgetEvent>[])
            event.id: eventLabel(event),
        };

        final events =
            ref.watch(eventsProvider(widget.streamId)).valueOrNull ??
            const <BudgetEvent>[];
        final eventsById = {for (final t in events) t.id: t};

        final width = MediaQuery.sizeOf(context).width;
        final compact = width < 600;
        return _withImportUndo(
          _withFullPlan(
            context,
            Scaffold(
              appBar: AppBar(
                toolbarHeight: compact ? 56 : 60,
                // Below 360 the back button's slot tightens (56 → 48) so the
                // stream name keeps room next to the full action row.
                leadingWidth: width < 360 ? 48 : null,
                leading: IconButton(
                  key: const ValueKey('timeline-back'),
                  tooltip: 'All streams',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => _goBack(context),
                ),
                titleSpacing: compact ? 0 : 4,
                title: Row(
                  children: [
                    _HeaderBrand(compact: compact, tight: width < 360),
                    // The picker takes all the room up to the actions: its
                    // arrow sits at the far right and the empty space after
                    // the name opens it too.
                    Expanded(
                      child: _StreamHeader(stream: stream, compact: compact),
                    ),
                  ],
                ),
                actions: _headerActions(context, stream, width, events),
              ),
              body: _withPlanPanel(
                context,
                compact: compact,
                child: _withDockedList(
                  context,
                  stream,
                  Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          compact ? 8 : 16,
                          compact ? 6 : 12,
                          compact ? 8 : 16,
                          0,
                        ),
                        // The second row is the date range heatmap alone,
                        // full width.
                        child: DateRangeHeatmap(
                          from: _firstClearDay,
                          to: lastVisibleDay(_viewStart, _visibleDays),
                          today: DateTime.now(),
                          height: 44,
                          nets: shown == null
                              ? const {}
                              : dayNetTotals(
                                  shown,
                                  enabledOf: (id) =>
                                      (eventsById[id] ?? combo?.events[id])
                                          ?.enabled,
                                ),
                          // The strip between the labels: the start picker, as
                          // the whole control did before (least surprising).
                          onTap: () => _pickRangeEnd(context, start: true),
                          onStartTap: () => _pickRangeEnd(context, start: true),
                          onEndTap: () => _pickRangeEnd(context, start: false),
                        ),
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
                                          key: ValueKey(stream.id),
                                          fitToken: _fitToken,
                                          combineKey: combo == null
                                              ? ''
                                              : (combo.streams.keys.toList()
                                                      ..sort())
                                                    .join(','),
                                          zeroToken: _zeroToken,
                                          onFitRequested: (mode) =>
                                              _fit(mode, stream),
                                          onZoomStep: _zoomStep,
                                          onShift: _shift,
                                          series: shown!,
                                          seedDate: stream.seedDate,
                                          // Combined: no opening diamond (the
                                          // line is a sum, not this seed).
                                          seedBalance: combo != null
                                              ? null
                                              : stream.seedBalance.toDouble(),
                                          lineStart: combo?.lineStart,
                                          combinedStreams:
                                              combo?.streams ?? const {},
                                          otherEvents:
                                              combo?.events ?? const {},
                                          onOpenOtherEvent: (other, t, date) =>
                                              _openOther(
                                                context,
                                                other,
                                                t,
                                                date,
                                              ),
                                          lossThreshold: stream.lossThreshold
                                              .toDouble(),
                                          currencyScale: stream.currencyScale
                                              .toDouble(),
                                          viewStart: _viewStart,
                                          visibleDays: _visibleDays,
                                          onViewportChanged: _onChartViewport,
                                          restoreYRange: _restoreY,
                                          yRestoreToken: _yRestoreToken,
                                          onYRangeChanged: _onChartY,
                                          onPinnedDayChanged: _onPinnedDay,
                                          selectDay: _selectDay,
                                          selectDayToken: _selectDayToken,
                                          dataEditToken: _dataEditToken,
                                          onCreateOnDay: (day) =>
                                              stream.role.canEdit
                                              ? _createOnceOnDay(context, day)
                                              : _viewOnlyToast(context),
                                          onTrimOccurrence: stream.role.canEdit
                                              ? (t, day) =>
                                                    _trimAt(context, t, day)
                                              : null,
                                          onNewOnDay: stream.role.canEdit
                                              ? (day) => _openEditor(
                                                  context,
                                                  stream,
                                                  initialDate: day,
                                                )
                                              : null,
                                          onEditEvent: stream.role.canEdit
                                              ? (t, date) => _openEditor(
                                                  context,
                                                  stream,
                                                  existing: t,
                                                  focusDate: date,
                                                )
                                              : null,
                                          eventNames: eventNames,
                                          laneOrder: stream.eventOrder,
                                          otherLaneOrder: combo == null
                                              ? const []
                                              : _otherLaneOrder(combo),
                                          events: {
                                            for (final t in events) t.id: t,
                                          },
                                          dataFrom: _seriesCacheQuery?.from,
                                          dataThrough: _seriesCacheQuery?.to,
                                          ghosts: _ghosts,
                                          target: _goalActive
                                              ? _goalTarget
                                              : null,
                                          targetMode:
                                              _goalActive && _targetMode,
                                          onTargetChanged: _onTargetDrag,
                                          onAddForPeriod: stream.role.canEdit
                                              ? (start, end) => _openEditor(
                                                  context,
                                                  stream,
                                                  initialDate: start,
                                                  initialEndDate: end,
                                                )
                                              : null,
                                          onPlanPeriod: (p) => _planPeriod(
                                            p,
                                            stream.lossThreshold.toDouble(),
                                          ),
                                        ),
                                        if (_goalActive)
                                          Positioned(
                                            top: combo != null ? 44 : 8,
                                            right: 8,
                                            child: FilterChip(
                                              key: const ValueKey(
                                                'target-tool',
                                              ),
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
                                              onSelected: (on) => setState(
                                                () => _targetMode = on,
                                              ),
                                            ),
                                          ),
                                        if (combo != null)
                                          Positioned(
                                            top: 8,
                                            right: 8,
                                            child: _CombinedLegend(
                                              combo: combo,
                                              streamName: stream.name,
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
    final stream = ref.read(streamProvider(widget.streamId)).valueOrNull;
    if (stream == null) return page;
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
                child: _planPanel(context, stream, compact: true, full: true),
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
    final stream = ref.read(streamProvider(widget.streamId)).valueOrNull;
    if (stream == null) return child;
    final panel = _planPanel(context, stream, compact: compact);
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
    BudgetStream stream, {
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
      stream: stream,
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

  // ---------------------------------------------------------------- header

  /// Every timeline action lives in the header row, right of the stream
  /// name. The right end is always Reminders (prominent) · Events
  /// (plain list icon) · View · More (⋮, rightmost, takes what does not
  /// fit); the rest sits left of Reminders:
  ///
  /// * ≥1240px: Today, Seed (labelled) · Share · Stream settings · Reminders
  ///   (labelled) · Events · View · More (Import, Gestures &
  ///   shortcuts).
  /// * 960–1240px: the same with icon-only Today / Seed.
  /// * 600–960px: Today, Seed (icons) · Reminders (tonal icon) ·
  ///   Events · View (icon) · More (Stream settings, Share, Import,
  ///   shortcuts).
  /// * <600px: Reminders · Events · View (with Go to today / seed) ·
  ///   More. Events stays in the header at every width; below 360px
  ///   the back slot, logo gap and View button tighten so it fits.
  List<Widget> _headerActions(
    BuildContext context,
    BudgetStream stream,
    double width,
    List<BudgetEvent> events,
  ) {
    final desk = width >= 600, mid = width >= 960, wide = width >= 1240;
    final tiny = width < 360;
    final canEdit = stream.role.canEdit, owner = stream.role.isOwner;
    Widget icon(String key, String tip, Widget glyph, VoidCallback f) =>
        IconButton(
          key: ValueKey(key),
          tooltip: tip,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: f,
          icon: glyph,
        );
    void today() => _goToAndSelect(DateTime.now());
    void seed() => _goToAndSelect(stream.seedDate);
    final seedIcon = const Icon(Icons.flag_rounded, color: AppTheme.violet);

    // More, in order: Stream settings first, then whatever overflowed.
    final more = <PopupMenuEntry<String>>[
      if (canEdit && !mid)
        const PopupMenuItem(
          key: ValueKey('more-settings'),
          value: 'settings',
          child: ListTile(
            leading: Icon(Icons.tune_rounded),
            title: Text('Stream settings'),
          ),
        ),
      if (owner && !mid)
        const PopupMenuItem(
          key: ValueKey('more-share'),
          value: 'share',
          child: ListTile(
            leading: Icon(Icons.person_add_alt_1_outlined),
            title: Text('Share stream'),
          ),
        ),
      if (canEdit)
        PopupMenuItem(
          key: const ValueKey('more-import'),
          value: 'import',
          enabled: _pinnedDay != null,
          child: ListTile(
            enabled: _pinnedDay != null,
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Import events'),
            subtitle: _pinnedDay == null
                ? const Text(
                    importNeedsDayHint,
                    key: ValueKey('more-import-hint'),
                  )
                : Text('Dates count from ${formatOccurrenceDate(_pinnedDay!)}'),
          ),
        ),
      const PopupMenuItem(
        key: ValueKey('shortcuts-help'),
        value: 'shortcuts',
        child: ListTile(
          leading: Icon(Icons.keyboard_rounded),
          title: Text('Gestures & shortcuts'),
        ),
      ),
    ];

    return [
      // Below 360 the sync dot sits on the logo's corner instead.
      if (!tiny) const RealtimeDot(),
      if (wide) ...[
        OutlinedButton.icon(
          key: const ValueKey('go-today'),
          onPressed: today,
          icon: const Icon(Icons.today_rounded, size: 18),
          label: const Text('Today'),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: 'Go to the seed date (start of the balance)',
          child: OutlinedButton.icon(
            key: const ValueKey('go-seed'),
            onPressed: seed,
            icon: const Icon(
              Icons.flag_rounded,
              size: 18,
              color: AppTheme.violet,
            ),
            label: const Text('Seed'),
          ),
        ),
        const SizedBox(width: 4),
      ] else if (desk) ...[
        icon('go-today', 'Go to today', const Icon(Icons.today_rounded), today),
        icon(
          'go-seed',
          'Go to the seed date (start of the balance)',
          seedIcon,
          seed,
        ),
      ],
      if (mid && owner)
        icon(
          'stream-share',
          'Share stream',
          const Icon(Icons.person_add_alt_1_outlined),
          () => _share(context, stream),
        ),
      if (mid && canEdit)
        icon(
          'stream-settings',
          'Stream settings: seed balance, date, threshold',
          const Icon(Icons.tune_rounded),
          () => _editStream(context, stream),
        ),
      SizedBox(width: mid ? 6 : 2),
      // The prominent header action: the reminders calendar.
      if (mid)
        FilledButton.tonalIcon(
          key: const ValueKey('open-reminders'),
          onPressed: () => showReminders(context, stream),
          icon: const Icon(Icons.calendar_month_rounded, size: 18),
          label: const Text(
            'Reminders',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        )
      else
        IconButton.filledTonal(
          key: const ValueKey('open-reminders'),
          tooltip: 'Reminders calendar',
          onPressed: () => showReminders(context, stream),
          icon: const Icon(Icons.calendar_month_rounded),
        ),
      SizedBox(width: mid ? 4 : 0),
      // Always in the header, at every width (320 included): below 360 the
      // left side and View tighten instead so it fits.
      _eventsButton(context, stream, count: events.length),
      _fitMenu(stream, compact: !desk, iconOnly: !mid, tight: tiny),
      // Always the rightmost item.
      PopupMenuButton<String>(
        key: const ValueKey('timeline-more'),
        tooltip: 'More',
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (v) {
          switch (v) {
            case 'import':
              _openImport(context, stream);
            case 'settings':
              _editStream(context, stream);
            case 'shortcuts':
              _showShortcuts(context);
            case 'share':
              _share(context, stream);
          }
        },
        itemBuilder: (context) => more,
      ),
      SizedBox(width: desk ? 8 : 2),
    ];
  }

  /// View options: Combine with other streams and, on phones, Go to today /
  /// seed date. The fit modes are keyboard-only (F / A / H, listed in the
  /// shortcuts sheet) and never stretch to the alert line.
  Widget _fitMenu(
    BudgetStream stream, {
    required bool compact,
    bool? iconOnly,
    bool tight = false,
  }) {
    final icon = iconOnly ?? compact;
    final others = _otherStreams(stream.id);
    final combined = others.where((p) => _combine.contains(p.id)).length;
    final small = Theme.of(context).textTheme.labelSmall;
    final tip = combined > 0
        ? 'View options · combined with $combined other stream${combined == 1 ? '' : 's'}'
        : 'View options';
    return ViewMenu(
      compact: compact,
      streams: others,
      combined: _combine,
      onToday: () => _goToAndSelect(DateTime.now()),
      onSeed: () => _goToAndSelect(stream.seedDate),
      onToggleStream: _toggleCombine,
      builder: (context, open) => icon
          ? IconButton(
              key: const ValueKey('fit-menu'),
              tooltip: tip,
              constraints: BoxConstraints(
                minWidth: tight ? 40 : 44,
                minHeight: 44,
              ),
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

  /// The events list: a plain bulleted-list icon (no box, border or
  /// fill) between Reminders and the View menu; the count is in its
  /// tooltip. On wide screens it toggles the docked list, and the icon is
  /// tinted accent while that list is open.
  Widget _eventsButton(
    BuildContext context,
    BudgetStream stream, {
    required int count,
  }) {
    final docked = _dockable(context) && _dockOpen;
    return IconButton(
      key: const ValueKey('open-events'),
      tooltip: 'Events ($count)',
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      color: docked ? AppTheme.accent : null,
      onPressed: () => _openEventsPanel(context, stream),
      icon: const ListGlyph(key: ValueKey('tx-list-glyph')),
    );
  }

  /// Start / end label of the date-range row: pick that end of the view.
  /// A start before the end (or an end on / after the start) moves just that
  /// end, so the span changes; otherwise the span is kept and the view
  /// shifts to the picked day. The balance range is refitted, as for every
  /// "go to a date" action.
  Future<void> _pickRangeEnd(
    BuildContext context, {
    required bool start,
  }) async {
    final first = _firstClearDay;
    final last = lastVisibleDay(_viewStart, _visibleDays);
    final picked = await showDatePicker(
      context: context,
      initialDate: start ? first : last,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
      helpText: start ? 'Start date' : 'End date',
    );
    if (picked == null || !mounted) return;
    final day = dateOnly(picked);
    final w = _chartWidth;
    final (DateTime, double) view;
    if (start) {
      if (!day.isBefore(last)) return _showFrom(day);
      view = viewForRange(
        day,
        last,
        w,
        stripWidth: ChartLayout.laneNameWidth(w),
      );
    } else {
      if (day.isBefore(first)) {
        // Keep the span: [day] becomes the last visible day.
        view = (addDays(day, 1 - _visibleDays), _visibleDays);
      } else {
        view = viewForRange(
          first,
          day,
          w,
          stripWidth: ChartLayout.laneNameWidth(w),
          anchorEnd: true,
        );
      }
    }
    _setUnit(ViewUnit.nearest(view.$2));
    _onViewport(view.$1, view.$2);
    setState(() => _fitToken++);
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
                row(['Pinch'], 'Zoom time (touch, or trackpad at the cursor)'),
                row(['Double-tap'], 'Zoom in there and centre its balance'),
                row(['←', '→'], 'Pan time'),
                row(['↑', '↓'], 'Pan balance'),
                row(['Scroll'], 'Pan balance (sideways or Shift: time)'),
                row(['⌘ / ⌥ / Ctrl', 'Scroll'], 'Zoom at the cursor'),
                row(['+', '−'], 'Smaller / larger view unit'),
                row(['[', ']'], 'Back / forward one unit'),
                head('Fit'),
                row(['F'], 'Fit balance to what is in view'),
                row(['A'], 'Fit all data'),
                row(['H'], 'Fit all data horizontally'),
                head('Events'),
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

  // ----------------------------------------------------------- events

  Set<DateTime> _skipsFor(String eventId) => {
    for (final o in _seriesCache?.occurrences ?? const <Occurrence>[])
      if (o.eventId == eventId && o.skipped) dateOnly(o.date),
  };

  /// One place every create / edit path goes through, so the timeline
  /// always refreshes afterwards (skips can change even on cancel).
  Future<void> _openEditor(
    BuildContext context,
    BudgetStream stream, {
    BudgetEvent? existing,
    DateTime? initialDate,
    DateTime? initialEndDate,
    DateTime? focusDate,
    bool onceOnly = false,
  }) async {
    final result = await showEventEditor(
      context,
      streamId: widget.streamId,
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
      streamId: widget.streamId,
      outcome: outcome,
      onChanged: _invalidateBalance,
    );
  }

  void _planDone(BuildContext context, SolveResult result) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.message ??
              'Created ${result.event?.name.isNotEmpty == true ? result.event!.name : 'event'}',
        ),
      ),
    );
    _closePlan();
    ref.invalidate(eventsProvider(widget.streamId));
    _invalidateBalance();
  }

  Future<void> _editStream(BuildContext context, BudgetStream stream) async {
    final edited = await showStreamDialog(
      context,
      existing: stream,
      eventCount: ref.read(eventsProvider(widget.streamId)).valueOrNull?.length,
    );
    if (edited == null || !context.mounted) return;
    try {
      final n = ref.read(streamsProvider.notifier);
      final r = await saveWithConflictCheck(
        context,
        save: (force) => n.updateStream(edited, force: force),
        reload: n.refresh,
      );
      if (r == SaveResult.cancelled) return;
      ref.invalidate(streamProvider(widget.streamId));
      // A seed move shifts every schedule on the server.
      ref.invalidate(eventsProvider(widget.streamId));
      _invalidateBalance();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Stream updated')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }

  void _goBack(BuildContext context) => context.go(streamsPath);

  void _viewOnlyToast(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('View only: you have viewer access to this stream'),
      ),
    );
  }

  Future<void> _share(BuildContext context, BudgetStream stream) async {
    final left = await showShareDialog(
      context,
      ShareTarget.stream(stream.id, stream.name),
    );
    if (left && context.mounted) context.go('/');
  }

  /// A dot's "Trim From Here": [t] keeps only what occurs before [day]
  /// ([trimFromHere]: the series now ends the day before, end dates being
  /// inclusive). No dialog for a series that keeps earlier occurrences: the
  /// explicit pick is the ask and the 5s "Series trimmed" tip has Undo (old
  /// end + the once-offs it dropped; the server prunes overrides past the
  /// new end on the same update). When nothing would remain (a once-off,
  /// or trimming from the first occurrence) it asks, then deletes, with
  /// the usual "Deleted" Undo. A transfer's other side follows (the server
  /// mirrors the end date and the delete).
  Future<void> _trimAt(
    BuildContext context,
    BudgetEvent t,
    DateTime day,
  ) async {
    final current =
        ref
            .read(eventsProvider(widget.streamId))
            .valueOrNull
            ?.where((x) => x.id == t.id)
            .firstOrNull ??
        t;
    final plan = trimFromHere(current, day);
    if (plan == null) return;
    final n = ref.read(eventsProvider(widget.streamId).notifier);
    final name = current.name.isEmpty ? 'this event' : current.name;
    try {
      if (plan.deletes) {
        final once = current.recurrenceMode == RecurrenceMode.once;
        final ok = await showConfirmDialog(
          context,
          title: 'Delete $name?',
          message:
              (once
                  ? 'This is a once-off event, so trimming it deletes it.'
                  : 'Trimming from its first occurrence leaves nothing, so '
                        'the whole series is deleted.') +
              (current.isTransfer
                  ? ' Both sides of the transfer are deleted.'
                  : ''),
        );
        if (!ok || !context.mounted) return;
        final order = ref
            .read(streamProvider(widget.streamId))
            .valueOrNull
            ?.eventOrder;
        final skips = _skipsFor(current.id);
        await n.delete(current.id);
        _invalidateBalance();
        if (!context.mounted) return;
        reportEditorOutcome(
          context,
          ref,
          streamId: widget.streamId,
          outcome: EditorOutcome(
            action: EditorAction.deleted,
            event: current,
            skippedBefore: skips,
          ),
          onChanged: _invalidateBalance,
          orderBefore: order,
        );
        return;
      }
      final trimmed = plan.trimmed!;
      final r = await saveWithConflictCheck(
        context,
        save: (force) => n.updateEvent(trimmed, force: force),
        reload: n.refresh,
      );
      _invalidateBalance();
      if (r != SaveResult.saved || !context.mounted) return;
      _report(
        context,
        EditorOutcome(
          action: EditorAction.trimmed,
          event: trimmed,
          previous: current,
          date: plan.end,
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }

  Future<void> _createOnceOnDay(BuildContext context, DateTime day) async {
    final stream = ref.read(streamProvider(widget.streamId)).valueOrNull;
    if (stream == null) return;
    await _openEditor(context, stream, initialDate: day, onceOnly: true);
  }

  /// The toolbar's Events: shows / hides the docked list on wide
  /// landscape screens, else opens it over the timeline.
  Future<void> _openEventsPanel(
    BuildContext context,
    BudgetStream stream,
  ) async {
    if (_dockable(context)) return _toggleDock();
    await showSidePanel<void>(
      context,
      width: 520,
      label: 'Events',
      builder: (panelContext) => _eventsPanel(
        context,
        stream,
        docked: false,
        close: () => Navigator.of(panelContext).pop(),
      ),
    );
  }

  Widget _eventsPanel(
    BuildContext context,
    BudgetStream stream, {
    required bool docked,
    VoidCallback? close,
  }) => EventsPanel(
    stream: stream,
    skipsFor: _skipsFor,
    onClose: docked ? _toggleDock : null,
    onPanelClosed: (outcome) {
      if (context.mounted) _report(context, outcome);
    },
    onChanged: _invalidateBalance,
    // New ▾ Plan: the only way into the planner.
    onPlan: () {
      close?.call();
      _openPlan();
      // "Plan a payment" (the planner's other tabs are one tap away).
      setState(() => _planTab = PlanTab.payment);
    },
  );
}

class _StreamHeader extends StatelessWidget {
  const _StreamHeader({required this.stream, this.compact = false});

  final BudgetStream stream;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Fills the free space between the brand and the actions (the toolbar
    // lays the actions out first, so they always fit): the name stays left
    // and ellipsises, the arrow sits at the right end, and the whole area,
    // empty space included, is one tap target with its ink.
    return SizedBox(
      key: const ValueKey('header-stream-area'),
      width: double.infinity,
      child: StreamPicker(
        keyPrefix: 'nav',
        title: 'Jump to stream',
        mineHeader: false,
        currentStreamId: stream.id,
        onSelected: (a) {
          if (a.id == stream.id) return;
          context.pushReplacement('/streams/${a.id}/timeline');
        },
        onNewStream: () async {
          final created = await createStream(context);
          if (created != null && context.mounted) {
            context.go('/streams/${created.id}/timeline');
          }
        },
        builder: (context, open) => InkWell(
          key: const ValueKey('header-stream-picker'),
          borderRadius: BorderRadius.circular(8),
          onTap: open,
          child: Tooltip(
            message: 'Jump to another stream',
            waitDuration: const Duration(milliseconds: 500),
            // Opaque: a tap anywhere in the stretched area hits, not only
            // on the glyphs.
            child: ColoredBox(
              color: Colors.transparent,
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        stream.name,
                        style: compact
                            ? theme.textTheme.titleMedium
                            : theme.textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(
                      Icons.arrow_drop_down_rounded,
                      key: ValueKey('header-stream-arrow'),
                      color: AppTheme.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
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
        tip(
          Icons.ads_click_rounded,
          'Tap an event lane, then its dot, for actions',
        ),
        tip(Icons.add_circle_outline_rounded, 'Tap or drag the dates to add'),
        tip(Icons.touch_app_outlined, 'Drag near dots for details'),
        tip(Icons.pinch_outlined, 'Pinch to zoom'),
      ] else ...[
        tip(
          Icons.ads_click_rounded,
          'Hover an event lane, click its dot for actions',
        ),
        tip(Icons.swipe_right_alt_rounded, 'Drag or tap the dates to add'),
        tip(Icons.pan_tool_alt_outlined, 'Drag the chart to pan'),
        tip(Icons.view_week_rounded, 'Pinch or − / + change unit, [ ] step'),
        tip(
          Icons.mouse_outlined,
          'Scroll to pan · ⌘/⌥/Ctrl+scroll or pinch to zoom',
        ),
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
    required this.streams,
    required this.events,
    required this.count,
    this.loading = false,
  });

  /// Nothing loaded yet for the checked streams: the current stream alone,
  /// with the indicator and a progress bar.
  _Combined.waiting(this.series, DateTime seedDate, this.count)
    : lineStart = seedDate,
      streams = const {},
      events = const {},
      loading = true;

  final BalanceSeries series;
  final DateTime lineStart;
  final Map<String, CombinedStream> streams;
  final Map<String, BudgetEvent> events;

  /// Streams in the view, this one included ("Combined: 3 streams").
  final int count;
  final bool loading;

  _Combined copyWith({required bool loading}) => _Combined(
    series: series,
    lineStart: lineStart,
    streams: streams,
    events: events,
    count: count,
    loading: loading,
  );
}

/// "Combined: N streams" over the chart, with each stream's tint (legend).
class _CombinedLegend extends StatelessWidget {
  const _CombinedLegend({required this.combo, required this.streamName});

  final _Combined combo;
  final String streamName;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.labelSmall ?? const TextStyle();
    Widget dot(Color c) => Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
    final names = [streamName, for (final p in combo.streams.values) p.name];
    return Tooltip(
      message:
          'Balance line is the sum of: ${names.join(', ')}.\n'
          'Transfers between them net out. + and Trim add to $streamName.',
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
              'Combined: ${combo.count} streams',
              style: small.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            dot(AppTheme.accent),
            for (final p in combo.streams.values) dot(p.color),
          ],
        ),
      ),
    );
  }
}

/// The Budgie icon (rounded tile, no wordmark) at the left of the
/// timeline header, between the back button and the stream name: sized to
/// the header row, a little smaller on phones. The landing intro glides
/// into it.
class _HeaderBrand extends StatelessWidget {
  const _HeaderBrand({required this.compact, this.tight = false});

  final bool compact;

  /// Below 360px: a smaller gap before the stream name, and the sync dot on
  /// the logo.
  final bool tight;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsetsDirectional.only(end: tight ? 6 : (compact ? 10 : 12)),
    child: Semantics(
      label: 'Budgie',
      image: true,
      child: BrandAnchor(
        key: const ValueKey('timeline-brand'),
        child: tight
            // Below 360px the sync dot rides on the logo's corner, so the
            // action row (with Events) and the stream name both fit.
            ? Stack(
                clipBehavior: Clip.none,
                children: [
                  BudgieIcon(size: compact ? 26 : 32),
                  const Positioned(
                    right: -9,
                    bottom: -2,
                    child: RealtimeDot(key: ValueKey('brand-rt-dot')),
                  ),
                ],
              )
            : BudgieIcon(size: compact ? 26 : 32),
      ),
    ),
  );
}

/// The import an undo bar can roll back.
class _ImportUndo {
  _ImportUndo(this.streamId, this.result);
  final String streamId;
  final ImportResult result;
}

/// Floating "Imported N events · Undo · ×" bar. Unlike the 5 s undo
/// tip it never times out: it stays until Undo or the close box.
class _ImportUndoBar extends StatelessWidget {
  const _ImportUndoBar({
    required this.message,
    required this.error,
    required this.busy,
    required this.onUndo,
    required this.onClose,
  });

  final String message;
  final bool error;
  final bool busy;
  final VoidCallback onUndo;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = scheme.onInverseSurface;
    return Material(
      key: const ValueKey('import-undo-bar'),
      color: scheme.inverseSurface,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        child: Row(
          children: [
            Icon(
              error ? Icons.error_outline_rounded : Icons.check_circle_rounded,
              size: 20,
              color: error ? scheme.error : fg,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                key: const ValueKey('import-undo-message'),
                style: theme.textTheme.bodyMedium?.copyWith(color: fg),
              ),
            ),
            TextButton(
              key: const ValueKey('import-undo'),
              onPressed: busy ? null : onUndo,
              style: TextButton.styleFrom(
                foregroundColor: scheme.inversePrimary,
                minimumSize: const Size(64, 44),
              ),
              child: Text(busy ? 'Undoing…' : (error ? 'Retry' : 'Undo')),
            ),
            IconButton(
              key: const ValueKey('import-undo-close'),
              tooltip: 'Close',
              onPressed: busy ? null : onClose,
              icon: Icon(Icons.close_rounded, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

/// The stream no longer exists for me (deleted, or my access was removed).
bool _isGone(Object error) =>
    error is ApiException &&
    (error.statusCode == 404 || error.statusCode == 403);

/// A deep link / last-opened / stale tab on a stream that is gone: back to
/// the streams home with a note, and this browser forgets the stream.
class _StreamGone extends ConsumerStatefulWidget {
  const _StreamGone({required this.streamId});
  final String streamId;
  @override
  ConsumerState<_StreamGone> createState() => _StreamGoneState();
}

class _StreamGoneState extends ConsumerState<_StreamGone> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      forgetStreamLocally(
        widget.streamId,
        userId: ref.read(authProvider).valueOrNull?.user?.id,
      );
      ref.invalidate(streamsProvider);
      // Already on the way out (the realtime "deleted" notice did it).
      final router = GoRouter.of(context);
      final path = router.routerDelegate.currentConfiguration.uri.path;
      if (!path.startsWith('/streams/${widget.streamId}/')) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      context.go(streamsPath);
      messenger?.showSnackBar(
        const SnackBar(content: Text('That stream no longer exists')),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
    key: ValueKey('stream-gone'),
    body: Center(child: CircularProgressIndicator()),
  );
}
