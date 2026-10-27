import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../data/models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/eye_icons.dart';
import '../../widgets/money_text.dart';
import 'chart_geometry.dart';
import 'combined.dart';
import 'day_totals.dart';
import 'duration_format.dart';
import 'fit_ranges.dart';
import 'ghost_line.dart';
import 'occurrence_info.dart';
import 'selection_period.dart';
import 'stack_lanes.dart';
import 'step_dots.dart';
import 'tap_menu.dart';
import 'trim.dart';
import 'alert_fill.dart';
import 'zoom_level.dart';
import '../../data/alert.dart';

typedef ViewportChanged = void Function(DateTime viewStart, double visibleDays);
typedef CreateOnDay = void Function(DateTime day);

/// The dot popup's Edit: open [event]'s editor (the series editor for
/// a recurring one), focused on the tapped occurrence [date].
typedef EditOccurrence = void Function(BudgetEvent event, DateTime date);

/// Step chart of closing balance with a calendar axis.
///
/// The balance (Y) range is explicit view state: fitted once when the chart
/// first shows data (or on [fitToken] change), then changed only by the
/// user. Panning or zooming time never rescales it, so a balance level keeps
/// its height on screen.
///
/// Click-drag pans time and balance. The wheel pans: vertical moves the
/// balance range, horizontal (or Shift+vertical) moves time. Cmd, Option or
/// Ctrl + wheel scales about the pointer (vertical → balance, horizontal →
/// time), and a trackpad pinch zooms time about the pointer. Touch: drag
/// pans, pinch zooms time at the pinch focus.
///
/// Pressing on the date axis (month/week/day lanes) picks a date instead:
/// a bubble, guide line and day highlight follow the pointer. The view
/// never moves: past an edge the day clamps to the first / last visible
/// day. The bubble shows the day's "+" from
/// the press on, following the picked day while dragging. Releasing (or a
/// plain tap) never acts by itself: the line and bubble stay pinned on
/// that day; only tapping "+" calls [onCreateOnDay]. Dragging anywhere
/// (however far up) just keeps tracking the day: there is no drag-to-
/// cancel. "+" is the bubble's only action: a pinned line goes on any
/// press (or tap) elsewhere on the chart, Esc, or a view navigation (Esc
/// mid-drag drops the pick). (Trimming lives in a lane dot's menu and the
/// day popup's ⋮ menu, [onTrimOccurrence].)
/// With focus: arrow keys pan, +/- zoom time, F fits balances.
/// Test hook: after each paint, every in-plot vertex as (name, x, labelled).
@visibleForTesting
void Function(String name, double x, bool labelled)? debugVertexLabel;

/// Test hook: after each paint, every label drawn for an in-view vertex as
/// (name, dot centre, dot radius, label box).
@visibleForTesting
void Function(String name, Offset center, double radius, Rect rect)?
debugVertexLabelRect;

/// Test hook: each event label as drawn: its box and its text lines
/// (the day total first, then names / "+N more").
@visibleForTesting
void Function(Rect rect, List<String> lines)? debugVertexLabelLines;

/// Test hook: each lane label as drawn: the event's name, its signed
/// amount text, that amount's colour and the amount pill's box.
@visibleForTesting
void Function(String name, String amount, Color color, Rect pill)?
debugLaneAmount;

/// Test hook: each lane name as drawn (left, sticky) and its box.
@visibleForTesting
void Function(String name, Rect rect)? debugLaneName;

/// Most event names listed under a day's total before "+N more".
const int maxLabelNames = 6;

/// A label kept from the previous paint: its box relative to the dot, how
/// many names it listed and whether it was the one-line "Name +N more".
typedef _LabelSpot = ({Rect rect, int names, bool compact});

/// An event label as painted last frame (chart coords) and the centre
/// of the dot it names; taps / hover on it act as on that dot.
typedef _LabelHit = ({Rect rect, Offset dot});

/// One text line under a label's total: a name, a "+N more", or both.
typedef _LabelLine = ({String? name, String? more});

/// Test hook: every date-axis label as painted, with its row name
/// ("Year", "Month", "Week", "Day") and the rect its text occupies.
@visibleForTesting
void Function(String row, String text, Rect rect)? debugAxisLabel;

/// Test hook: where the $0 line was painted, and the plot it sits in.
@visibleForTesting
void Function(double y, Rect plot)? debugZeroLine;

class BalanceChart extends StatefulWidget {
  const BalanceChart({
    super.key,
    required this.series,
    required this.seedDate,
    this.seedBalance,
    this.lossThreshold = 0,
    this.currencyScale,
    required this.viewStart,
    required this.visibleDays,
    required this.onViewportChanged,
    required this.onCreateOnDay,
    this.onTrimDay,
    this.trimDayBlock,
    this.onPinnedDayChanged,
    this.selectDay,
    this.selectDayToken = 0,
    this.dataEditToken = 0,
    this.eventNames = const {},
    this.dataFrom,
    this.dataThrough,
    this.fitToken = 0,
    this.combineKey = '',
    this.zeroToken = 0,
    this.restoreYRange,
    this.yRestoreToken = 0,
    this.onYRangeChanged,
    this.onFitRequested,
    this.onZoomStep,
    this.onShift,
    this.events = const {},
    this.ghosts = const [],
    this.target,
    this.targetMode = false,
    this.onTargetChanged,
    this.onPlanPeriod,
    this.onAddForPeriod,
    this.onTrimOccurrence,
    this.onEditEvent,
    this.onNewOnDay,
    this.lineStart,
    this.combinedStreams = const {},
    this.otherEvents = const {},
    this.onOpenOtherEvent,
    this.laneOrder = const [],
    this.otherLaneOrder = const [],
    this.onHideEvent,
  });

  /// "Hide" in a lane's tap menu (the whole series): the same flag as the
  /// Events list's eye (hidden from the timeline and excluded from the
  /// balance). Null: no Hide (viewers). Only the current stream's own
  /// events get it.
  final void Function(BudgetEvent t)? onHideEvent;

  /// The viewed stream's event ids in the Events list's order: the
  /// order of the stacked lanes (top first). Ids it misses follow, in
  /// [events] order.
  final List<String> laneOrder;

  /// Combined view: the other streams' event ids, stream by stream in the
  /// streams' order, each in its list order: the lanes after the viewed stream's.
  final List<String> otherLaneOrder;

  /// Combined view: where the (summed) line starts, the earliest seed of
  /// the included streams. Null: [seedDate].
  final DateTime? lineStart;

  /// Combined view: the other streams folded into [series], by id. Their
  /// occurrences carry [Occurrence.streamId] and get that stream's tint.
  final Map<String, CombinedStream> combinedStreams;

  /// Combined view: the other streams' events by id (popups only; Trim
  /// and Edit only ever use [events], the current stream's).
  final Map<String, BudgetEvent> otherEvents;

  /// "Open in `stream`" in a dot popup, for another stream's event when I
  /// can edit that stream. Opens its editor only.
  final void Function(CombinedStream stream, BudgetEvent t, DateTime date)?
  onOpenOtherEvent;

  /// "Edit" in the dot popup (a menu, in creation order, when the dot has
  /// several events). Null: no Edit (viewers). Only an explicit tap on
  /// Edit / a menu item calls this; other taps never edit.
  final EditOccurrence? onEditEvent;

  /// "+" on a dot popup row: a new event on that row's day, always in
  /// this stream (also for another stream's row in a combined view). Null: no
  /// "+" (viewers). Only a tap on that button calls it.
  final CreateOnDay? onNewOnDay;

  /// "Trim From Here" (a lane dot's menu, a day popup row's ⋮): drop the
  /// event's occurrences from that day on (the page ends the series the day
  /// before, or asks then deletes when nothing would remain; see
  /// [trimFromHere]). Null: disabled / hidden (viewers). Only the current
  /// stream's own events get it; only that pick calls it.
  final EditOccurrence? onTrimOccurrence;

  /// "Plan…" in the selection card: opens the goal planner pre-filled with
  /// the selected range. Opens a panel only; never edits data.
  final void Function(PeriodSummary period)? onPlanPeriod;

  /// "+" in the selection card: open the add-event editor bounded to
  /// the selected days (start .. end, inclusive). Opens the editor only;
  /// nothing is created until it is saved. Null: no "+" (viewers).
  final void Function(DateTime start, DateTime end)? onAddForPeriod;

  /// Target tool on: taps and drags on the plot set the goal target
  /// (date, balance) instead of panning / selecting. Never edits data.
  final bool targetMode;
  final void Function(DateTime day, double balance)? onTargetChanged;

  /// Goal target point (date, balance), drawn as a ringed marker.
  final (DateTime, double)? target;

  /// Dashed what-if lines (plan preview, scenarios) over the real line.
  final List<GhostLine> ghosts;

  /// Events by id, for the occurrence hover tooltip.
  final Map<String, BudgetEvent> events;

  /// +/− keys: one centred zoom step (-1 in, +1 out). Falls back to an
  /// unanimated centred zoom when null.
  final ValueChanged<int>? onZoomStep;

  /// [ / ] keys: shift the view one unit back (-1) / forward (1).
  final ValueChanged<int>? onShift;

  /// Keyboard shortcuts for the Fit menu (A, H, W, M). F is handled here.
  final ValueChanged<FitMode>? onFitRequested;

  final BalanceSeries series;

  /// Changing this refits the balance range to the data in view.
  final int fitToken;

  /// Which streams are combined into [series]. A change never refits or
  /// moves anything: the balance range stays exactly as it was and the
  /// line redraws in it (it may run off-range).
  final String combineKey;

  /// Bumped to widen the current balance range to include 0 without a full
  /// vertical refit (Fit horizontal).
  final int zeroToken;

  /// A saved balance range to show instead of the default fit: applied when
  /// the chart is created and whenever [yRestoreToken] changes.
  final BalanceExtents? restoreYRange;
  final int yRestoreToken;

  /// The visible balance range changed (pan, pinch, fits, restore). Called
  /// after the frame, at most once per frame; never per pointer event.
  final ValueChanged<BalanceExtents>? onYRangeChanged;

  /// First and last day [series] was computed for. The line is not drawn
  /// past them, so a stale series never shows a flat, made-up balance while
  /// a wider window is still loading.
  final DateTime? dataFrom;
  final DateTime? dataThrough;
  final DateTime seedDate;

  /// Opening balance on [seedDate]; drawn as the initial vertex. Null: none.
  final double? seedBalance;

  /// Closing balances below this value are drawn as a loss (equal is not).
  final double lossThreshold;

  /// Stream currency scale (dollars per y grid step). The chart opens at
  /// [currencyScaleRange] (zero a third up the plot) and re-applies it
  /// whenever the scale changes.
  final double? currencyScale;

  final DateTime viewStart;
  final double visibleDays;
  final ViewportChanged onViewportChanged;
  final CreateOnDay onCreateOnDay;

  /// The pick bubble's ✂ (next to its "+"): end every event on the day.
  /// Null: no ✂.
  final ValueChanged<DateTime>? onTrimDay;

  /// Why the ✂ is disabled on a day (view only, nothing to end), shown as
  /// its tooltip; null: enabled.
  final String? Function(DateTime day)? trimDayBlock;

  /// The day selected on the date lane (the pinned pick bubble), or null
  /// once it is dismissed. Notified after the frame that changes it.
  final ValueChanged<DateTime?>? onPinnedDayChanged;

  /// Selects [selectDay] on the date lane, exactly as tapping it there does
  /// (line, bubble with its "+", [onPinnedDayChanged]), each time
  /// [selectDayToken] changes (Go to today / seed). A view move in the same
  /// update (the jump itself) does not dismiss it; later ones do.
  final DateTime? selectDay;
  final int selectDayToken;

  /// Bumped when the user changed the data (import, undo, add, edit,
  /// delete): the balance that comes back refits the balance range if the
  /// line no longer fits it (see [_BalanceChartState._refitIfDataLeftRange]).
  /// Syncs from others and combining streams never refit.
  final int dataEditToken;

  /// Occurrence event id to display name. Missing ids are left unlabeled.
  final Map<String, String> eventNames;

  @override
  State<BalanceChart> createState() => _BalanceChartState();
}

class _BalanceChartState extends State<BalanceChart>
    with TickerProviderStateMixin {
  /// Double-tap zoom: time 2x in about the tapped point and the balance
  /// range centred on it, eased together over [doubleTapZoomDuration].
  late final AnimationController _dtAnim = AnimationController(
    vsync: this,
    duration: doubleTapZoomDuration,
  )..addListener(_tickDoubleTap);
  ({double startCoord, double days, BalanceExtents y})? _dtFrom, _dtTo;
  DateTime? _dtBase;

  /// The last plain tap on the plot (to recognise a second one).
  DateTime? _lastTapAt;
  Offset? _lastTapPos;

  void _tickDoubleTap() {
    final from = _dtFrom, to = _dtTo, base = _dtBase;
    if (from == null || to == null || base == null || !mounted) return;
    final k = Curves.easeInOutCubic.transform(_dtAnim.value);
    double lerp(double a, double b) => a + (b - a) * k;
    final start = lerp(from.startCoord, to.startCoord);
    setState(
      () => _yRange = BalanceExtents(
        lerp(from.y.min, to.y.min),
        lerp(from.y.max, to.y.max),
      ),
    );
    widget.onViewportChanged(
      addDays(base, start - from.startCoord),
      lerp(from.days, to.days),
    );
  }

  void _stopDoubleTap() {
    if (_dtAnim.isAnimating) _dtAnim.stop();
    _dtFrom = _dtTo = _dtBase = null;
  }

  /// Second tap of a double-tap at [pos]: zoom (never creates or edits).
  void _doubleTapZoom(Offset pos) {
    final layout = _layout;
    final plot = layout.plot;
    final y = _ensureYRange();
    if (y == null || plot.width <= 0 || plot.height <= 0) return;
    _stopDoubleTap();
    _clearTip();
    _tapTip = false;
    _tapTipTimer?.cancel();
    _hoverDots.value = null;
    final from = (
      startCoord: dayCoord(widget.viewStart),
      days: widget.visibleDays,
      y: y,
    );
    _dtFrom = from;
    _dtTo = doubleTapZoomTarget(
      startCoord: from.startCoord,
      days: from.days,
      y: y,
      fx: (pos.dx - plot.left) / plot.width,
      fy: (pos.dy - plot.top) / plot.height,
    );
    _dtBase = widget.viewStart;
    _dtAnim.forward(from: 0);
  }

  /// Tests: the balance range currently shown.
  @visibleForTesting
  BalanceExtents? get debugYRange => _yRange;

  Size _size = Size.zero;
  int? _pointer;
  Offset? _downPos;
  DateTime? _originStart;
  double _originDays = 70;
  bool _dragged = false;
  _Gesture _mode = _Gesture.none;
  Timer? _holdTimer;

  /// Live positions of pointers that are down (two = pinch).
  final Map<int, Offset> _down = {};

  /// Pinch start: finger distance, focus x, and the view at that moment.
  double _pinchDist = 1;
  double _pinchFocusX = 0;
  double _pinchFocusY = 0;

  /// A second finger went down during this gesture: no tap / long-press /
  /// scrub tooltips until every finger is up (incl. the one left behind).
  bool _multiTouch = false;
  PinchAxis _pinchAxis = PinchAxis.time;
  BalanceExtents? _pinchY;

  /// Date picking on the axis: the picked day and where the pointer is.
  DateTime? _pickDay;
  Offset? _pickPos;
  bool _pickTouch = false;

  /// The pick was released: its line and bubble stay up (with the "+"
  /// button) until acted on or dismissed.
  bool _pickPinned = false;
  final GlobalKey _pinKey = GlobalKey();

  void _clearPin() {
    if (!_pickPinned) return;
    setState(() {
      _pickPinned = false;
      _pickDay = null;
      _pickPos = null;
    });
  }

  /// The pinned bubble's "+": the only way a pick acts.
  void _addFromPin() {
    final day = _pickDay;
    _clearPin();
    if (day == null) return;
    widget.onCreateOnDay(day);
  }

  /// A long-press on a dot (touch) shows its tooltip instead of opening it.
  bool _longPressTip = false;

  /// Touch drag started near a dot: dragging scrubs tooltips, not the view.
  bool _scrubCandidate = false;
  final ValueNotifier<DateTime?> _hoverDay = ValueNotifier(null);

  /// Dots under the mouse (several when they overlap) and where it is.
  final ValueNotifier<_DotTip?> _hoverDots = ValueNotifier(null);

  /// The balance step whose dot is hovered (mouse) or tapped: its
  /// tooltip (net change, balance after) and axis guides show.
  final _StepTip _stepTip = _StepTip();

  /// [_stepTip] was set by a tap / click: it stays until a tap elsewhere,
  /// another dot, or a pan (hover leaving the dot keeps it).
  bool _stepPinned = false;

  late final Listenable _paintTips = Listenable.merge([_hoverDots, _stepTip]);

  /// Day of the hover "+" button the current press started on, if any.
  DateTime? _downOnAdd;

  /// Visible balance range; null until fitted to the first data shown.
  BalanceExtents? _yRange;

  /// Next automatic y-range uses the currency scale instead of a data fit.
  bool _scaleDefault = true;

  /// Set by a fit whose time range is not loaded yet; the balance range is
  /// refit again once [BalanceChart.dataFrom]..dataThrough covers the view.
  bool _fitAwaitingData = false;

  bool get _dataCoversView {
    final from = widget.dataFrom, through = widget.dataThrough;
    if (from == null || through == null) return false;
    final start = dayCoord(widget.viewStart);
    return dayCoord(from) <= start + 1e-6 &&
        dayCoord(through) + 1 >= start + widget.visibleDays - 1e-6;
  }

  BalanceExtents? _originY;

  /// Vertex keys labelled last paint; see [_BalanceChartPainter.labelMemory].
  final Map<int, _LabelSpot> _labelMemory = <int, _LabelSpot>{};

  /// Painted label boxes (see [_LabelHit]); refreshed by every paint.
  final List<_LabelHit> _labelHits = <_LabelHit>[];
  static const Duration _holdDelay = Duration(milliseconds: 450);
  bool _overAdd = false;

  /// Pointer is over an occurrence dot (click opens its series).
  bool _overDot = false;
  final FocusNode _focus = FocusNode(debugLabel: 'BalanceChart');

  static const double _addButtonSize = 28;

  @override
  void initState() {
    super.initState();
    _restoreY();
  }

  /// Shows [BalanceChart.restoreYRange] (a saved view), skipping the fit.
  void _restoreY() {
    final y = widget.restoreYRange;
    if (y == null || !y.min.isFinite || !y.max.isFinite || !(y.min < y.max)) {
      return;
    }
    _yRange = y;
    _scaleDefault = false;
    _fitAwaitingData = false;
    _restorePending = true;
  }

  BalanceExtents? _reportedY;
  bool _reportQueued = false;

  /// Tells the owner about a new balance range once the frame is done.
  void _queueYReport() {
    if (widget.onYRangeChanged == null || _reportQueued) return;
    final y = _yRange;
    if (y == null) return;
    final r = _reportedY;
    if (r != null && r.min == y.min && r.max == y.max) return;
    _reportQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportQueued = false;
      final now = _yRange;
      if (!mounted || now == null) return;
      final last = _reportedY;
      if (last != null && last.min == now.min && last.max == now.max) return;
      _reportedY = now;
      widget.onYRangeChanged?.call(now);
    });
  }

  @override
  void didUpdateWidget(covariant BalanceChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sentView = null;
    if (oldWidget.viewStart != widget.viewStart ||
        oldWidget.visibleDays != widget.visibleDays ||
        oldWidget.fitToken != widget.fitToken ||
        oldWidget.currencyScale != widget.currencyScale) {
      // Any view navigation (pan, pinch, wheel, zoom, ◀ ▶, Fit, Today)
      // closes the info card and its y-axis highlight, and a pinned pick.
      // The selection is anchored to its dates and survives navigation;
      // only closing its card clears it.
      _clearTip();
      if (_mode != _Gesture.pick) _clearPin();
    }
    // After the clear above: the jump that comes with it must not dismiss.
    final select = widget.selectDay;
    if (oldWidget.selectDayToken != widget.selectDayToken &&
        select != null &&
        _mode != _Gesture.pick) {
      _pickDay = dateOnly(select);
      _pickPos = null; // the bubble sits just above the date lane
      _pickTouch = false;
      _pickPinned = true;
      // Esc dismisses it as it does a tapped one: the chart takes focus
      // (from the Today / Seed button or menu that asked).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pickPinned) _focus.requestFocus();
      });
    }
    if (oldWidget.fitToken != widget.fitToken ||
        oldWidget.zeroToken != widget.zeroToken ||
        oldWidget.currencyScale != widget.currencyScale) {
      _stopDoubleTap();
    }
    final y = _yRange;
    if (oldWidget.zeroToken != widget.zeroToken && y != null) {
      _yRange = includeZero(y);
    }
    // Combining / uncombining streams never moves the view: no refit, not
    // even one still waiting for its data (the combined refetch would
    // otherwise complete it). The line just redraws in the same scale.
    if (oldWidget.combineKey != widget.combineKey) _fitAwaitingData = false;
    if (oldWidget.currencyScale != widget.currencyScale) {
      _yRange = null;
      _scaleDefault = true;
    }
    if (oldWidget.fitToken != widget.fitToken) {
      _yRange = null;
      _scaleDefault = false;
      _fitAwaitingData = !_dataCoversView;
    } else if (_fitAwaitingData && _dataCoversView) {
      _yRange = null;
      _fitAwaitingData = false;
    }
    if (oldWidget.yRestoreToken != widget.yRestoreToken) {
      _stopDoubleTap();
      _restoreY();
    }
    if (oldWidget.dataEditToken != widget.dataEditToken) {
      _refitAfterEdit = true;
    }
    if (_refitAfterEdit && !identical(oldWidget.series, widget.series)) {
      _refitIfDataLeftRange(oldWidget);
    }
  }

  /// An edit is waiting for its refreshed balance.
  bool _refitAfterEdit = false;

  /// The user's edit (an import, add, edit, undo) came back and pushes the
  /// line out of a balance range it fitted in before: refit the range so
  /// the changed line and its dots stay in view. A range the line was
  /// already outside (the user panned or zoomed the balance axis) is kept.
  /// Waits (keeps [_refitAfterEdit]) while the line is unchanged.
  void _refitIfDataLeftRange(BalanceChart old) {
    final y = _yRange;
    final now = _visible()?.extents;
    final before = visibleBalance(
      points: old.series.points,
      viewStart: old.viewStart,
      viewEnd: addDays(old.viewStart, old.visibleDays),
      seedDate: dateOnly(old.lineStart ?? old.seedDate),
    )?.extents;
    if (now == null) return;
    if (before != null && before.min == now.min && before.max == now.max) {
      return; // not the refreshed balance yet
    }
    _refitAfterEdit = false;
    if (y == null || _extentsWithin(now, y)) return;
    if (before != null && !_extentsWithin(before, y)) return;
    _yRange = null;
    _scaleDefault = false;
    _restorePending = false;
  }

  static bool _extentsWithin(BalanceExtents e, BalanceExtents range) {
    final tol = (range.max - range.min).abs() * 1e-6;
    return e.min >= range.min - tol && e.max <= range.max + tol;
  }

  /// A restored (saved) range is checked against the data once it is in:
  /// one far too small for the line in view (it fitted a flat line, before
  /// events arrived, e.g. an import) is dropped for a fit.
  bool _restorePending = false;

  void _checkRestoredRange() {
    if (!_restorePending) return;
    final y = _yRange;
    final now = _visible()?.extents;
    if (y == null) {
      _restorePending = false;
      return;
    }
    if (now == null || widget.series.points.isEmpty) return;
    _restorePending = false;
    if (_extentsWithin(now, y)) return;
    final dataSpan = now.max - now.min;
    if (dataSpan > 10 * (y.max - y.min)) {
      _yRange = null;
      _scaleDefault = false;
    }
  }

  /// Current balance range, fitting it to the data in view the first time.
  BalanceExtents? _ensureYRange() {
    if (_yRange != null) return _yRange;
    final visible = _visible();
    if (visible == null) return null;
    // The stacked lanes hang under the line, so a fit leaves room for the
    // whole stack below the lowest balance (and a net chip's height above
    // the highest).
    final below = _stackBelowPx();
    final above = below > 0 ? _stackAbovePx : 0.0;
    final plotH = _layout.plot.height;
    BalanceExtents fit(double lo, double hi) {
      var r = _fitRange(lo, hi);
      if (below <= 0 || plotH <= (below + above) * 1.6) return r;
      for (var i = 0; i < 3; i++) {
        final perPx = (r.max - r.min) / plotH;
        r = _fitRange(lo - below * perPx, hi + above * perPx);
      }
      return r;
    }

    return _yRange = fit(visible.extents.min, visible.extents.max);
  }

  /// The tallest stack of lanes under the line, in px, plus a little air.
  double _stackBelowPx() {
    final lanes = _laneSet();
    if (lanes.isEmpty) return 0;
    return laneGap + lanes.maxActive * _laneHeight(lanes, _layout) + 6;
  }

  /// Room over the highest balance for its net chip.
  static const double _stackAbovePx = 22;

  BalanceExtents _fitRange(double min, double max) {
    // The default view anchors $0 a third of the way up the plot.
    if (_scaleDefault) {
      return currencyScaleRange(widget.currencyScale ?? 0, min, max);
    }
    // A line flat at $0 (no events in view yet) fits the currency
    // scale's default rather than ±$1, so what is added next shows.
    final seedV = widget.seedBalance != null && _seedInView
        ? widget.seedBalance!
        : 0.0;
    if (min.abs() < 1e-9 && max.abs() < 1e-9 && seedV.abs() < 1e-9) {
      return currencyScaleRange(widget.currencyScale ?? 0, 0, 0);
    }
    // Fits always include the origin, so the zero line is in view.
    return paddedRange(
      min,
      max,
      include: [
        0,
        if (widget.seedBalance != null && _seedInView) widget.seedBalance!,
      ],
    );
  }

  /// Where the line starts: the seed, or the earliest combined seed.
  DateTime get _lineStart => dateOnly(widget.lineStart ?? widget.seedDate);

  BudgetEvent? _txOf(String id) => widget.events[id] ?? widget.otherEvents[id];

  bool get _seedInView {
    final seed = dateOnly(widget.seedDate);
    final end = addDays(widget.viewStart, widget.visibleDays);
    return !seed.isBefore(dateOnly(widget.viewStart)) && seed.isBefore(end);
  }

  /// Closes the info card (and the y-axis highlight that follows it).
  void _clearTip() {
    if (_mode == _Gesture.scrub || _longPressTip) return;
    _tapTipTimer?.cancel();
    _tapTip = false;
    _stickyTip = false;
    if (_hoverDots.value != null) _hoverDots.value = null;
  }

  void _setYRange(BalanceExtents range) {
    if (!range.min.isFinite || !range.max.isFinite) return;
    _stopDoubleTap();
    _clearTip();
    setState(() => _yRange = range);
  }

  void _fitY() {
    _stopDoubleTap();
    _clearTip();
    setState(() => _yRange = null);
  }

  @override
  void dispose() {
    if (_notifiedPin != null) {
      // The parent must not keep a selection this chart no longer shows.
      final cb = widget.onPinnedDayChanged;
      WidgetsBinding.instance.addPostFrameCallback((_) => cb?.call(null));
    }
    _holdTimer?.cancel();
    _tapTipTimer?.cancel();
    _nudgeTimer?.cancel();
    _dtAnim.dispose();
    _switchTimer?.cancel();
    _hoverDay.dispose();
    _hoverDots.dispose();
    _stepTip.dispose();
    _focus.dispose();
    super.dispose();
  }

  ChartLayout get _layout => ChartLayout.of(_size, widget.visibleDays);

  DateTime _dayAt(double localDx) {
    return _layout.dateAt(localDx, widget.viewStart, widget.visibleDays);
  }

  /// The day a date-lane pick at [localDx] selects, clamped to the visible
  /// days: from the first day fully clear of the lane-name strip to the
  /// last day whose start is on screen. Picking never moves the view.
  DateTime _pickDayAt(double localDx) {
    final layout = _layout;
    final (first, last) = pickableDays(
      layout,
      widget.viewStart,
      widget.visibleDays,
      ChartLayout.laneNameWidth(layout.size.width),
    );
    final day = _dayAt(localDx);
    return day.isBefore(first) ? first : (day.isAfter(last) ? last : day);
  }

  void _onPointerDown(PointerDownEvent event) {
    final touch = event.kind != PointerDeviceKind.mouse;
    _touchUi = touch;
    if (!touch && (event.buttons & kPrimaryButton) == 0) return;
    _stopDoubleTap();
    _down[event.pointer] = event.localPosition;
    // Any press on the chart (its bubble sits above and keeps its own)
    // dismisses a pinned pick.
    _clearPin();
    if (_down.length >= 2) {
      _multiTouch = true;
      _holdTimer?.cancel();
      _tapTipTimer?.cancel();
      _hoverDots.value = null;
    }
    if (_pointer != null) {
      // A second finger turns a pending pan into a pinch (not while picking).
      if (touch && _down.length == 2 && _mode != _Gesture.pick) {
        _startPinch();
      }
      return;
    }
    _pointer = event.pointer;
    _downPos = event.localPosition;
    _focus.requestFocus();
    // A press outside the selection band / card (they sit above this
    // listener) blurs the selection; that press never shows dot info.
    // The selection stays through a pan (it is anchored to its dates);
    // a plain tap here clears it on release.
    _dismissPress = _selA != null;
    _longPressTip = false;
    final layout = _layout;
    // The "+" button ignores pointers so it never blocks a pan or zoom that
    // starts on it; a plain click on it is resolved in [_finishPointer].
    final hovered = _hoverDay.value;
    final addRect = hovered == null ? null : _dayButtonRect(layout, hovered);
    _downOnAdd = addRect != null && addRect.contains(event.localPosition)
        ? hovered
        : null;
    _hoverDay.value = null;
    _touchDown = touch;
    // Touch: a pinned tip stays up while this press is still a tap or a
    // scrub; a pan clears it, and release resolves taps in [_showTapTip].
    _stickyTip = touch && _hoverDots.value != null;
    if (!_stickyTip) _hoverDots.value = null;
    _tapTip = false;
    _tapTipTimer?.cancel();
    _originStart = widget.viewStart;
    _originDays = widget.visibleDays;
    _originY = _ensureYRange();
    _dragged = false;
    _holdTimer?.cancel();
    if (layout.axis.contains(event.localPosition)) {
      _downOnAdd = null;
      setState(() {
        _mode = _Gesture.pick;
        _pickTouch = touch;
        _pickPos = event.localPosition;
        _pickDay = _pickDayAt(event.localPosition.dx);
      });
      return;
    }
    _mode = _Gesture.pan;
    // A drag scrubs from the shown (revealed) dot, anywhere along its
    // revealed lane, or from an always-drawn dot; anywhere else on the
    // lanes it pans (they cover much of the plot).
    final shown = _hoverDots.value;
    bool onShownLane() {
      if (shown == null || shown.dots.length != 1) return false;
      final id = shown.dots.first.txId;
      if (id == null) return false;
      return _laneDotAt(layout, event.localPosition, slop: 6)?.txId == id;
    }

    _scrubCandidate =
        touch &&
        !_hasSelection &&
        (_nearestDot(layout, event.localPosition, touchVertexHitRadius) !=
                null ||
            shown != null &&
                (shown.anchor - event.localPosition).distance <=
                    touchVertexHitRadius ||
            onShownLane());
    // Press-and-hold (touch or mouse, within the slop) in empty graph
    // space enters selection mode; near a dot (44px touch / 18px mouse) a
    // hold shows that dot's info as before. A quick tap still shows dot
    // info and an immediate drag still scrubs (near dots) or pans.
    _holdTimer = Timer(_holdDelay, () {
      if (!mounted || _pointer != event.pointer || _dragged || _multiTouch) {
        return;
      }
      final pos = _downPos;
      if (pos == null || !_layout.plot.contains(pos)) return;
      final layout = _layout;
      final lane = _laneDotAt(layout, pos, slop: touch ? 6 : 2);
      final near = lane ?? _dotAt(layout, pos, vertexHitRadius(event.kind));
      final lineTol = touch ? touchLineHitTolerance : mouseLineHitTolerance;
      if (near == null && _distanceToLine(layout, pos) <= lineTol) {
        return; // on the balance line: no selection (and nothing else)
      }
      if (near == null) {
        // Empty graph space only: a hold near a dot keeps showing its info.
        _startSelection(pos);
        return;
      }
      if (!touch) return; // mouse: hover already shows the dot's info
      // Touch long-press on a dot shows / pins its tooltip.
      final hits = lane != null ? [lane] : _overlapping(layout, near);
      _longPressTip = true;
      _hoverDots.value = _DotTip(
        hits,
        lane != null ? _tipAnchor(layout, lane) : near.center,
      );
    });
  }

  /// Selection: anchor day and the moving / other edge (unordered).
  DateTime? _selA;
  DateTime? _selB;

  /// Where the user dragged the selection card (top-left, chart coords);
  /// null = default placement. Kept while the selection exists.
  Offset? _cardPos;
  final GlobalKey _cardKey = GlobalKey(debugLabel: 'selection-card');

  /// Clamps a card at [pos] of [size] inside the chart area.
  Offset _clampCard(Offset pos, Size size) {
    final plot = _layout.plot;
    final minX = 4.0, minY = plot.top + 4;
    final maxX = math.max(minX, _size.width - size.width - 4);
    final maxY = math.max(minY, _size.height - size.height - 4);
    return Offset(pos.dx.clamp(minX, maxX), pos.dy.clamp(minY, maxY));
  }

  Size get _cardSize {
    final box = _cardKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : const Size(300, 200);
  }

  /// The hold that created the selection is still down (extending it).
  bool _selecting = false;

  /// The current press started by blurring a selection.
  bool _dismissPress = false;

  /// Edge / body drag state for the handles.
  double _selDragX = 0;
  DateTime? _selDragA;
  DateTime? _selDragB;

  bool get _hasSelection => _selA != null;

  /// Screen distance from [pos] to the plotted step line (plateaus and
  /// vertical steps), mirroring [_BalanceChartPainter._paintSeries].
  double _distanceToLine(ChartLayout layout, Offset pos) {
    final range = _ensureYRange();
    final visible = _visible();
    if (range == null || visible == null) return double.infinity;
    final scale = _YScale(range.min, range.max, layout.plot);
    final seed = _lineStart;
    final viewEnd = addDays(widget.viewStart, widget.visibleDays);
    var drawStart = widget.viewStart.isBefore(seed) ? seed : widget.viewStart;
    final from = widget.dataFrom;
    if (from != null && drawStart.isBefore(from) && !from.isBefore(seed)) {
      drawStart = from;
    }
    var drawEnd = viewEnd;
    final through = widget.dataThrough;
    if (through != null) {
      final coverEnd = addCalendarDays(through, 1);
      if (coverEnd.isBefore(drawEnd)) drawEnd = coverEnd;
    }
    if (!drawStart.isBefore(drawEnd)) return double.infinity;
    double xOf(DateTime d) => layout
        .xOf(d, widget.viewStart, widget.visibleDays)
        .clamp(layout.plot.left, layout.plot.right)
        .toDouble();
    double? current;
    final jumps = <BalancePoint>[];
    for (final p in visible.samples) {
      if (!dateOnly(p.date).isAfter(drawStart)) {
        current = p.closingBalance.toDouble();
      } else {
        jumps.add(p);
      }
    }
    var best = double.infinity;
    var cursor = xOf(drawStart);
    // Stacked lanes: the line and the lanes hanging under it are one
    // ribbon, so a point inside it is on the line; [depth] is how far the
    // stack reaches below the balance.
    final lanes = _laneSet();
    final laneH = lanes.isEmpty ? 0.0 : _laneHeight(lanes, layout);
    double depthAt(DateTime day) {
      if (lanes.isEmpty) return 0.0;
      final n = lanes.activeOn(day).length;
      return n == 0 ? 0.0 : laneGap + n * laneH;
    }

    void band(double x0, double x1, double top, double bottom) {
      final dx = pos.dx < x0 ? x0 - pos.dx : (pos.dx > x1 ? pos.dx - x1 : 0.0);
      final dy = pos.dy < top
          ? top - pos.dy
          : (pos.dy > bottom ? pos.dy - bottom : 0.0);
      best = math.min(best, math.sqrt(dx * dx + dy * dy));
    }

    var curDepth = depthAt(drawStart);
    for (final j in jumps) {
      final jx = xOf(dateOnly(j.date));
      final next = j.closingBalance.toDouble();
      final nextDepth = depthAt(dateOnly(j.date));
      if (current != null) {
        final y = scale.yOf(current), yn = scale.yOf(next);
        band(cursor, jx, y, y + curDepth);
        band(jx, jx, math.min(y, yn), math.max(y + curDepth, yn + nextDepth));
      }
      current = next;
      cursor = jx;
      curDepth = nextDepth;
    }
    if (current != null) {
      final y = scale.yOf(current);
      band(cursor, xOf(drawEnd), y, y + curDepth);
    }
    return best;
  }

  void _startSelection(Offset pos) {
    HapticFeedback.lightImpact();
    _tapTipTimer?.cancel();
    _tapTip = false;
    _stickyTip = false;
    _longPressTip = false;
    _scrubCandidate = false;
    _hoverDots.value = null;
    final day = _dayAt(pos.dx);
    setState(() {
      _mode = _Gesture.select;
      _selA = day;
      _selB = day;
      _cardPos = null; // a new selection gets the default card placement
      _selecting = true;
    });
  }

  void _clearSelection() {
    if (_selA == null && !_selecting) return;
    final apply = mounted;
    void clear() {
      _selA = null;
      _selB = null;
      _cardPos = null;
      _selecting = false;
    }

    apply ? setState(clear) : clear();
  }

  void _startPinch() {
    _holdTimer?.cancel();
    final pts = _down.values.toList();
    _pinchDist = math.max(1, (pts[0] - pts[1]).distance);
    _pinchFocusX = (pts[0].dx + pts[1].dx) / 2;
    _pinchFocusY = (pts[0].dy + pts[1].dy) / 2;
    _pinchAxis = pinchAxisFor(pts[0] - pts[1]);
    _pinchY = _yRange;
    _originStart = widget.viewStart;
    _originDays = widget.visibleDays;
    _hoverDots.value = null;
    _stickyTip = false;
    _tapTip = false;
    _longPressTip = false;
    _scrubCandidate = false;
    setState(() {
      _mode = _Gesture.pinch;
      _dragged = true;
    });
    _clearStepTip();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_down.containsKey(event.pointer)) return;
    _down[event.pointer] = event.localPosition;
    if (_mode == _Gesture.pinch) {
      _updatePinch();
      return;
    }
    if (event.pointer != _pointer) return;
    if (_mode == _Gesture.select) {
      final day = _dayAt(
        event.localPosition.dx.clamp(
          _layout.plot.left,
          _layout.plot.right - 0.5,
        ),
      );
      if (day != _selB) setState(() => _selB = day);
      return;
    }
    final origin = _downPos;
    final originStart = _originStart;
    if (origin == null || originStart == null) return;

    final dx = event.localPosition.dx - origin.dx;
    final dy = event.localPosition.dy - origin.dy;
    final slop = event.kind == PointerDeviceKind.mouse ? 4.0 : 10.0;
    if (!_dragged && dx * dx + dy * dy > slop * slop) {
      _dragged = true;
      _holdTimer?.cancel();
      _clearStepTip();
      if (_longPressTip) {
        _longPressTip = false;
        _hoverDots.value = null;
      }
      if (_mode == _Gesture.pan && _scrubCandidate) {
        setState(() => _mode = _Gesture.scrub);
      } else if (_stickyTip) {
        // A pan from empty space closes the pinned tip.
        _stickyTip = false;
        _hoverDots.value = null;
      }
    }

    if (_mode == _Gesture.scrub) {
      _updateScrub(event.localPosition);
      return;
    }

    if (_mode == _Gesture.pick) {
      _updatePick(event.localPosition);
      return;
    }
    if (!_dragged || _longPressTip) return;

    final width = _layout.plot.width;
    if (width <= 0) return;
    final days = -dx / width * _originDays;
    final originY = _originY;
    if (originY != null) {
      _setYRange(panBalanceRange(originY, dy, _layout.plot.height));
    }
    widget.onViewportChanged(addDays(originStart, days), _originDays);
  }

  void _updatePinch() {
    if (_down.length < 2) return;
    final originStart = _originStart;
    if (originStart == null) return;
    final pts = _down.values.take(2).toList();
    final dist = math.max(1.0, (pts[0] - pts[1]).distance);
    final focusX = (pts[0].dx + pts[1].dx) / 2;
    final y = _pinchY;
    if (_pinchAxis != PinchAxis.time && y != null) {
      // Balance zoom around the starting focal point; the focus moving
      // up/down also pans.
      final plot = _layout.plot;
      final h = plot.height <= 0 ? 1.0 : plot.height;
      final fraction = (plot.bottom - _pinchFocusY) / h;
      final focusY = (pts[0].dy + pts[1].dy) / 2;
      final zoomed = zoomBalanceRange(y, _pinchDist / dist, fraction);
      _setYRange(panBalanceRange(zoomed, focusY - _pinchFocusY, h));
    }
    if (_pinchAxis == PinchAxis.balance) return;
    final view = pinchView(
      layout: _layout,
      originStart: originStart,
      originDays: _originDays,
      startDistance: _pinchDist,
      distance: dist,
      startFocusX: _pinchFocusX,
      focusX: focusX,
    );
    widget.onViewportChanged(view.$1, view.$2);
  }

  void _updatePick(Offset pos) {
    // Anywhere on screen (however far up or past an edge) it just tracks
    // the day, clamped to the visible ones: the view never scrolls.
    final day = _pickDayAt(pos.dx);
    setState(() {
      _pickPos = pos;
      _pickDay = day;
    });
  }

  void _endPick({required bool commit}) {
    final day = _pickDay;
    final ok = commit && day != null;
    setState(() {
      _mode = _Gesture.none;
      if (ok) {
        // Release never acts: pin the line + bubble; its "+" does.
        _pickPinned = true;
        return;
      }
      _pickDay = null;
      _pickPos = null;
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    _down.remove(event.pointer);
    if (_multiTouch) {
      // Ignore the rest of a multi-finger gesture; no tap on release.
      if (_down.isEmpty) {
        _reset();
        _multiTouch = false;
        _hoverDots.value = null;
      }
      return;
    }
    if (_mode == _Gesture.pinch) {
      // Stay out of tap / pan handling until every finger is up.
      if (_down.isEmpty) _reset();
      return;
    }
    if (event.pointer != _pointer) return;
    _finishPointer(event.localPosition, vertexHitRadius(event.kind));
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _down.remove(event.pointer);
    if (_multiTouch) {
      if (_down.isEmpty) {
        _reset();
        _multiTouch = false;
        _hoverDots.value = null;
      }
      return;
    }
    if (_mode == _Gesture.pinch) {
      if (_down.isEmpty) _reset();
      return;
    }
    if (event.pointer != _pointer) return;
    if (_mode == _Gesture.pick) _endPick(commit: false);
    if (_mode == _Gesture.select) setState(() => _selecting = false);
    _reset();
  }

  void _reset() {
    _holdTimer?.cancel();
    _pointer = null;
    _downPos = null;
    _downOnAdd = null;
    _stickyTip = false;
    if (_longPressTip || _mode == _Gesture.scrub) {
      final tip = _hoverDots.value;
      if (_touchDown && tip != null && !_multiTouch) {
        // Touch: pin the last scrubbed / long-pressed dot after lift-off,
        // until the next tap.
        _tapTip = true;
        // Keep the same tip (incl. its finger point) so the card does not
        // jump from finger-relative to dot-relative placement on lift.
        _hoverDots.value = tip;
      } else {
        _hoverDots.value = null;
      }
    }
    _longPressTip = false;
    _scrubCandidate = false;
    setState(() {
      _mode = _Gesture.none;
      _dragged = false;
    });
  }

  void _finishPointer(Offset localPosition, [double hitRadius = 18]) {
    _holdTimer?.cancel();
    final mode = _mode;
    final dragged = _dragged;
    final longPress = _longPressTip;
    final dismiss = _dismissPress;
    _dismissPress = false;
    if (mode == _Gesture.select) {
      setState(() => _selecting = false);
      _reset();
      return;
    }
    if (mode == _Gesture.scrub) {
      _reset();
      return;
    }
    if (mode == _Gesture.pick) {
      _endPick(commit: true);
      _reset();
      return;
    }
    _reset();
    // A tap outside the band / card keeps the selection (it clears only
    // via its card's close button) and still never shows dot info.
    if (dismiss && !dragged) return;
    if (longPress || dismiss) return;

    // A second quick tap near the first: zoom in there (time 2x, balance
    // centred), never the second tap's info / create.
    if (!dragged) {
      final now = clock.now(), last = _lastTapAt, lastPos = _lastTapPos;
      if (last != null &&
          lastPos != null &&
          now.difference(last) <= kDoubleTapTimeout &&
          (localPosition - lastPos).distance <= kDoubleTapSlop &&
          _layout.plot.contains(localPosition)) {
        _lastTapAt = _lastTapPos = null;
        _doubleTapZoom(localPosition);
        return;
      }
      _lastTapAt = now;
      _lastTapPos = localPosition;
    } else {
      _lastTapAt = _lastTapPos = null;
    }
    final addDay = _downOnAdd;
    if (!dragged && addDay != null) {
      widget.onCreateOnDay(addDay);
      return;
    }
    // A tap on the plot only shows info: the nearest dot's tooltip, or
    // dismisses it. Creating is on the date axis; editing in the panel.
    if (!dragged) _showTapTip(localPosition, hitRadius);
  }

  /// Tooltip pinned by a tap; hides on the next tap, a pan, or after a while.
  bool _tapTip = false;

  /// The current press is touch (vs mouse).
  bool _touchDown = false;

  /// A touch press began while a tip was pinned; it stays visible until the
  /// press turns into a pan or resolves as a tap.
  bool _stickyTip = false;
  Timer? _tapTipTimer;
  static const Duration _tapTipDuration = Duration(seconds: 5);

  void _showTapTip(Offset pos, double hitRadius) {
    _tapTipTimer?.cancel();
    final layout = _layout;
    final onPlot = layout.plot.contains(pos);
    // Right on a step dot (its drawn size and a few px), the dot wins;
    // otherwise a net chip keeps its whole-day popup.
    final onDot = onPlot ? _stepOnDot(layout, pos) : null;
    final chip = onDot != null || !onPlot || _laneSet().isEmpty
        ? null
        : _labelDotAt(layout, pos, slop: 0);
    // A tap / click anywhere on an event's lane (or, with a mouse, on its
    // hover-revealed dot) opens that event's action menu at the tap, in
    // one step (touch has no reveal-then-tap). Its day: the step at or
    // before the tapped x (the revealed dot's step for a dot click).
    // A balance step's dot: its net change and balance (never creates or
    // edits anything).
    final step =
        onDot ??
        (chip != null || !onPlot
            ? null
            : _stepHit(layout, pos, touch: _touchDown));
    if (step != null) {
      _tapTip = false;
      _hoverDots.value = null;
      _stepPinned = true;
      _stepTip.value = step.step;
      if (_touchDown) _stepTip.bumpSoon(() => mounted && _stepPinned);
      return;
    }
    _clearStepTip();
    final lane = chip != null || !onPlot
        ? null
        : (_touchDown ? null : _laneDotHit(layout, pos, touch: false)) ??
              _laneDotAt(layout, pos, slop: _touchDown ? 6 : 2);
    if (lane != null) {
      _openDotMenu(lane, at: pos);
      return;
    }
    // Otherwise a net chip, then the always-drawn dots (opening diamond,
    // lane-less occurrences).
    final nearest = onPlot ? chip ?? _dotAt(layout, pos, hitRadius) : null;
    if (nearest == null) {
      _tapTip = false;
      _hoverDots.value = null;
      return;
    }
    final group = _overlapping(layout, nearest);
    final anchor = nearest.center;
    _tapTip = true;
    final current = _hoverDots.value;
    if (current != null && identical(current.dots.first, nearest) ||
        current != null &&
            current.dots.length == group.length &&
            (current.anchor - anchor).distance < 0.5) {
      // Tapping the dot that is already shown: keep the card where it is.
      _hoverDots.value = current;
    } else {
      _hoverDots.value = _DotTip(group, anchor);
    }
    // Touch tips stay until the next tap; mouse clicks time out.
    if (_touchDown) {
      _repaintSoon();
      return;
    }
    _armTapTipTimer();
  }

  /// Safari (WebKit) can leave the canvas unpresented after a touch tap
  /// until the next input event, so a freshly opened popup would not show.
  /// A couple of re-notifications a moment later force real frames.
  void _repaintSoon() {
    if (!kIsWeb) return;
    for (final ms in const [50, 200]) {
      Timer(Duration(milliseconds: ms), () {
        final tip = _hoverDots.value;
        if (!mounted || tip == null || !_tapTip) return;
        _hoverDots.value = _DotTip(tip.dots, tip.anchor, finger: tip.finger);
      });
    }
  }

  final _chartPaintKey = GlobalKey();
  Timer? _nudgeTimer;

  /// Safari (WebKit) can also leave the canvas showing the previous frame
  /// after a wheel / pinch change until the next input event: repaint the
  /// chart again shortly after the last such event.
  void _nudgePaint() {
    if (!kIsWeb) return;
    void paint() =>
        _chartPaintKey.currentContext?.findRenderObject()?.markNeedsPaint();
    _nudgeTimer?.cancel();
    _nudgeTimer = Timer(const Duration(milliseconds: 50), () {
      if (!mounted) return;
      paint();
      _nudgeTimer = Timer(const Duration(milliseconds: 150), () {
        if (mounted) paint();
      });
    });
  }

  void _armTapTipTimer() {
    _tapTipTimer?.cancel();
    _tapTipTimer = Timer(_tapTipDuration, () {
      if (!mounted || !_tapTip) return;
      // Not while the mouse is on the card (reaching for Edit).
      if (_overTipCard) return _armTapTipTimer();
      _tapTip = false;
      _hoverDots.value = null;
    });
  }

  /// The popup card, for hit-testing hover against it.
  final GlobalKey _tipCardKey = GlobalKey();

  /// The mouse is over (or within a short reach of) the popup card.
  bool _overTipCard = false;

  /// Whether [pos] (chart-local) is on the popup card or in the gap between
  /// it and its dot, so moving from the dot to Edit keeps the tip.
  bool _tipCardContains(Offset pos) {
    final actionable =
        widget.onEditEvent != null ||
        widget.onNewOnDay != null ||
        widget.onTrimOccurrence != null ||
        widget.onOpenOtherEvent != null;
    if (!actionable || _hoverDots.value == null) return false;
    return _keyContains(_tipCardKey, pos, inflate: 18);
  }

  /// Whether chart-local [pos] is on [key]'s widget (grown by [inflate]).
  bool _keyContains(GlobalKey key, Offset pos, {double inflate = 0}) {
    final box = key.currentContext?.findRenderObject();
    final me = context.findRenderObject();
    if (box is! RenderBox || me is! RenderBox || !box.attached) return false;
    final topLeft = me.globalToLocal(box.localToGlobal(Offset.zero));
    return (topLeft & box.size).inflate(inflate).contains(pos);
  }

  void _hideTip() {
    _tapTipTimer?.cancel();
    _tapTip = false;
    _stickyTip = false;
    _overTipCard = false;
    _hoverDots.value = null;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        _handleScroll,
      );
    } else if (event is PointerScaleEvent) {
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        _handleScale,
      );
    }
  }

  /// Cmd, Option or Ctrl is held: the wheel scales instead of panning.
  static bool get _scaleKeys {
    final k = HardwareKeyboard.instance;
    return k.isMetaPressed || k.isAltPressed || k.isControlPressed;
  }

  /// The wheel. Plain: vertical pans the balance range (natural direction:
  /// wheel down shows lower balances, like a scrolled page) and horizontal
  /// (or Shift+vertical) pans time; a diagonal trackpad swipe does both.
  /// With Cmd, Option or Ctrl: scales about the pointer ([_scaleAtPointer]).
  void _handleScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _pointer != null) return;
    var dx = event.scrollDelta.dx;
    var dy = event.scrollDelta.dy;
    final plot = _layout.plot;
    if (plot.width <= 0 || (dx == 0 && dy == 0)) return;
    final range = _ensureYRange();
    _nudgePaint();
    if (_scaleKeys) {
      _scaleAtPointer(event.localPosition, dx, dy, range);
      return;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      // Shift+wheel pans time (browsers may already turn it horizontal).
      dx = dy != 0 ? dy : dx;
      dy = 0;
    }
    // A delta under a fifth of the other is trackpad drift.
    final major = math.max(dx.abs(), dy.abs());
    if (dx.abs() < major * 0.2) dx = 0;
    if (dy.abs() < major * 0.2) dy = 0;
    _clearTip();
    if (dy != 0 && range != null) {
      _setYRange(panBalanceRange(range, -dy, plot.height));
    }
    if (dx != 0) {
      final (start, days) = _wheelView;
      _sendWheelView(addDays(start, dx / plot.width * days), days);
    }
  }

  /// Cmd/Option/Ctrl+wheel: a vertical delta scales the $ axis about the
  /// pointer's y (the balance under it stays put) and a horizontal delta
  /// scales the time axis about the pointer's x (the date under it stays
  /// put), each by `exp(delta * 0.0016)` (positive zooms out), within the
  /// usual limits. Both apply when both deltas are present; a delta under a
  /// fifth of the other is trackpad drift and ignored. The y change is a
  /// deliberate range (not auto-fitted again; Fit resets it).
  void _scaleAtPointer(
    Offset local,
    double dx,
    double dy,
    BalanceExtents? range,
  ) {
    final major = math.max(dx.abs(), dy.abs());
    final sx = dx.abs() >= major * 0.2 ? dx : 0.0;
    final sy = dy.abs() >= major * 0.2 ? dy : 0.0;
    _clearTip();
    if (sy != 0 && range != null) {
      final plot = _layout.plot;
      final fraction = plot.height <= 0
          ? 0.5
          : (plot.bottom - local.dy) / plot.height;
      _setYRange(
        zoomBalanceRange(
          range,
          math.exp(sy.clamp(-400.0, 400.0) * 0.0016),
          fraction,
        ),
      );
    }
    if (sx != 0) {
      _zoomAt(local.dx, math.exp(sx.clamp(-400.0, 400.0) * 0.0016));
    }
  }

  /// Scale signals. In a browser these are Ctrl+wheel events, each its own
  /// ratio (`scale = exp(-deltaY / 200)`): a trackpad pinch (no key held),
  /// zooming time about the pointer's x, or a mouse wheel with the Ctrl key
  /// really held (Windows / Linux), which behaves like Cmd/Option+wheel:
  /// the $ axis about the pointer's y.
  void _handleScale(PointerSignalEvent event) {
    if (event is! PointerScaleEvent || _pointer != null) return;
    final scale = event.scale;
    if (scale <= 0 || scale == 1) return;
    _nudgePaint();
    if (_scaleKeys) {
      _scaleAtPointer(
        event.localPosition,
        0,
        -200 * math.log(scale),
        _ensureYRange(),
      );
      return;
    }
    _clearTip();
    _zoomAt(event.localPosition.dx, 1 / scale);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && _hasSelection) {
      _clearSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _mode == _Gesture.pick) {
      _endPick(commit: false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _pickPinned) {
      _clearPin();
      return KeyEventResult.handled;
    }
    final span = widget.visibleDays;
    void pan(double fraction) => widget.onViewportChanged(
      addDays(widget.viewStart, span * fraction),
      span,
    );
    final center = _layout.plot.center.dx;
    final range = _ensureYRange();
    if (range != null &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      final h = _layout.plot.height;
      final up = key == LogicalKeyboardKey.arrowUp;
      _setYRange(panBalanceRange(range, (up ? 0.15 : -0.15) * h, h));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _fitY();
      return KeyEventResult.handled;
    }
    final fitKeys = {
      LogicalKeyboardKey.keyA: FitMode.all,
      LogicalKeyboardKey.keyH: FitMode.horizontal,
    };
    final fitMode = fitKeys[key];
    if (fitMode != null &&
        widget.onFitRequested != null &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      widget.onFitRequested!(fitMode);
      return KeyEventResult.handled;
    }
    if (widget.onShift != null &&
        (key == LogicalKeyboardKey.bracketLeft ||
            key == LogicalKeyboardKey.bracketRight)) {
      widget.onShift!(key == LogicalKeyboardKey.bracketLeft ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      pan(-0.15);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      pan(0.15);
    } else if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      widget.onZoomStep != null
          ? widget.onZoomStep!(-1)
          : _zoomAt(center, 1 / zoomStep);
    } else if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      widget.onZoomStep != null
          ? widget.onZoomStep!(1)
          : _zoomAt(center, zoomStep);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _zoomAt(double localDx, double factor) {
    final layout = _layout;
    final width = layout.plot.width;
    if (width <= 0 || factor <= 0) return;
    final (start, days) = _wheelView;
    final fraction = ((localDx - layout.plot.left) / width).clamp(0.0, 1.0);
    final anchor = addDays(start, fraction * days);
    final nextDays = (days * factor)
        .clamp(minVisibleDays, maxVisibleDays)
        .toDouble();
    _sendWheelView(addDays(anchor, -fraction * nextDays), nextDays);
  }

  /// The view a wheel / pinch event last asked for, until the parent
  /// rebuilds with it: several events can land in one frame (fast wheels,
  /// 120 Hz trackpads) and each must build on the previous one.
  (DateTime, double)? _sentView;

  (DateTime, double) get _wheelView =>
      _sentView ?? (widget.viewStart, widget.visibleDays);

  void _sendWheelView(DateTime start, double days) {
    if (_sentView == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sentView = null);
    }
    _sentView = (start, days);
    widget.onViewportChanged(start, days);
  }

  /// Last value sent to [BalanceChart.onPinnedDayChanged].
  DateTime? _notifiedPin;

  void _syncPinnedDay() {
    final pinned = _pickPinned ? _pickDay : null;
    if (pinned == _notifiedPin || widget.onPinnedDayChanged == null) return;
    _notifiedPin = pinned;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _notifiedPin == pinned) widget.onPinnedDayChanged!(pinned);
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncPinnedDay();
    _checkRestoredRange();
    final theme = Theme.of(context);
    final cursor = _mode == _Gesture.pick || _mode == _Gesture.select
        ? SystemMouseCursors.resizeColumn
        : _pointer != null && _dragged
        ? SystemMouseCursors.grabbing
        : _overAdd || _overDot
        ? SystemMouseCursors.click
        : SystemMouseCursors.grab;

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      autofocus: true,
      child: MouseRegion(
        cursor: cursor,
        onHover: _onHover,
        onExit: (_) {
          _hoverDay.value = null;
          // A row's ⋮ menu takes the mouse: keep its popup up.
          if (_rowMenuOpen) return;
          _hoverDots.value = null;
          _tapTip = false;
          if (!_stepPinned) _stepTip.value = null;
          if (_overAdd || _overDot) {
            setState(() {
              _overAdd = false;
              _overDot = false;
            });
          }
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            _size = Size(constraints.maxWidth, constraints.maxHeight);
            final yRange = _ensureYRange();
            _queueYReport();
            return Stack(
              children: [
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerCancel,
                  onPointerSignal: _onPointerSignal,
                  // Own layer: moving the hover "+" button must not repaint the chart.
                  child: RepaintBoundary(
                    child: ListenableBuilder(
                      listenable: _paintTips,
                      builder: (context, _) => CustomPaint(
                        key: _chartPaintKey,
                        painter: _BalanceChartPainter(
                          labelMemory: _labelMemory,
                          labelHits: _labelHits,
                          series: widget.series,
                          seedDate: widget.seedDate,
                          lineStart: _lineStart,
                          streamColors: {
                            for (final p in widget.combinedStreams.values)
                              p.id: p.color,
                          },
                          seedBalance: widget.seedBalance,
                          lossThreshold: widget.lossThreshold,
                          viewStart: widget.viewStart,
                          visibleDays: widget.visibleDays,
                          labelStyle:
                              theme.textTheme.bodySmall ?? const TextStyle(),
                          strongStyle:
                              (theme.textTheme.labelMedium ?? const TextStyle())
                                  .copyWith(fontWeight: FontWeight.w700),
                          laneStyle:
                              (theme.textTheme.labelSmall ?? const TextStyle())
                                  .copyWith(fontWeight: FontWeight.w600),
                          eventNames: widget.eventNames,
                          eventOrder: widget.events.keys.toList(),
                          lanes: _laneSet(),
                          textScaler: MediaQuery.textScalerOf(context),
                          dataFrom: widget.dataFrom,
                          dataThrough: widget.dataThrough,
                          // Read now, as the step dots below are: a tip
                          // rebuild never paints the line and its dots
                          // from two different balance ranges.
                          yRange: yRange,
                          highlightY: _paintHighlightY(),
                          stepDots: _stepDots(_layout),
                          activeStep: _stepTip.value?.day,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
                if ((widget.ghosts.isNotEmpty || widget.target != null) &&
                    yRange != null)
                  _ghostOverlay(yRange),
                if (widget.targetMode &&
                    widget.onTargetChanged != null &&
                    yRange != null)
                  _targetOverlay(yRange),
                if ((_mode == _Gesture.pick || _pickPinned) && _pickDay != null)
                  ..._pickOverlay(theme),
                if (_selA != null && _selB != null) ..._selectionOverlay(theme),
                ValueListenableBuilder<DateTime?>(
                  valueListenable: _hoverDay,
                  builder: (context, day, _) {
                    if (day == null || _pointer != null) {
                      return const SizedBox.shrink();
                    }
                    return _addButton(theme, day);
                  },
                ),
                ValueListenableBuilder<_DotTip?>(
                  valueListenable: _hoverDots,
                  builder: (context, tip, _) {
                    // A lane's dot is only revealed (no popup): a tap /
                    // click on its lane opens its action menu.
                    if (!_tipShown(tip) || _isLaneTip(tip!)) {
                      return const SizedBox.shrink();
                    }
                    return Stack(
                      children: [
                        ..._yHighlight(theme, tip),
                        ..._xHighlight(theme, tip),
                        _tooltip(theme, tip),
                      ],
                    );
                  },
                ),
                ValueListenableBuilder<BalanceStep?>(
                  valueListenable: _stepTip,
                  builder: (context, step, _) {
                    final dot = step == null || _selA != null
                        ? null
                        : _stepDotOf(step);
                    if (dot == null) return const SizedBox.shrink();
                    return Stack(children: _stepOverlay(theme, dot));
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Plot position to (day, balance) for the target tool.
  (DateTime, double) _targetAt(Offset pos, BalanceExtents range) {
    final plot = _layout.plot;
    final x = pos.dx.clamp(plot.left, plot.right - 0.5).toDouble();
    final y = pos.dy.clamp(plot.top, plot.bottom).toDouble();
    final day = dateOnly(
      addDays(
        widget.viewStart,
        (x - plot.left) / math.max(plot.width, 1) * widget.visibleDays,
      ),
    );
    final t = (plot.bottom - y) / math.max(plot.height, 1);
    return (day, range.min + t * (range.max - range.min));
  }

  /// Captures plot taps / drags while the target tool is on (the wheel
  /// still zooms).
  Widget _targetOverlay(BalanceExtents range) {
    final plot = _layout.plot;
    void set(Offset p) {
      final (d, v) = _targetAt(p, range);
      widget.onTargetChanged!(d, v);
    }

    return Positioned.fromRect(
      rect: plot,
      child: Listener(
        onPointerSignal: _onPointerSignal,
        // Raw pointer events so touch drags track live regardless of which
        // recognizer wins the arena; the detector below just claims it.
        onPointerDown: (e) => set(e.localPosition + plot.topLeft),
        onPointerMove: (e) => set(e.localPosition + plot.topLeft),
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: GestureDetector(
            key: const ValueKey('target-overlay'),
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            onPanUpdate: (_) {},
          ),
        ),
      ),
    );
  }

  Widget _ghostOverlay(BalanceExtents range) {
    final layout = _layout;
    final scale = _YScale(range.min, range.max, layout.plot);
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          key: const ValueKey('ghost-lines'),
          painter: GhostLinePainter(
            ghosts: widget.ghosts,
            target: widget.target,
            plot: layout.plot,
            xOf: (d) => layout.xOf(d, widget.viewStart, widget.visibleDays),
            yOf: scale.yOf,
            repaintKey: (
              widget.viewStart,
              widget.visibleDays,
              range.min,
              range.max,
              layout.plot,
            ),
          ),
        ),
      ),
    );
  }

  /// Y of the pill the axis labels keep clear of: the shown dot tip's, else
  /// the shown step dot's.
  double? _paintHighlightY() {
    final tip = _hoverDots.value;
    if (_tipShown(tip) && !_isLaneTip(tip!)) return _highlightDot(tip).balanceY;
    final step = _stepTip.value;
    final dot = step == null || _selA != null ? null : _stepDotOf(step);
    return dot?.center.dy;
  }

  List<StepDot>? _stepDotsMemo;
  Object? _stepDotsKey;

  /// The balance line's step dots in view, as the painter draws them
  /// (stacked lanes only: a lane-less chart already dots every day).
  List<StepDot> _stepDots(ChartLayout layout) {
    final range = _ensureYRange();
    if (range == null || _size == Size.zero || _laneSet().isEmpty) {
      return const [];
    }
    final key = (
      widget.series,
      widget.viewStart,
      widget.visibleDays,
      range.min,
      range.max,
      layout.plot,
      _lineStart,
      widget.dataFrom,
    );
    if (_stepDotsKey == key && _stepDotsMemo != null) return _stepDotsMemo!;
    _stepDotsKey = key;
    // The line begins at the later of its start and the loaded data: a
    // close there has no riser, so no step.
    var start = _lineStart;
    final from = widget.dataFrom;
    if (from != null && from.isAfter(start)) start = from;
    final scale = _YScale(range.min, range.max, layout.plot);
    return _stepDotsMemo = visibleStepDots(
      steps: balanceSteps(widget.series, lineStart: start),
      xOf: (d) => layout.xOf(d, widget.viewStart, widget.visibleDays),
      yOf: scale.yOf,
      plot: layout.plot,
      dayPx: layout.plot.width / math.max(widget.visibleDays, 0.001),
    );
  }

  /// The drawn step dot on [day], if any (in view, not thinned out).
  StepDot? _stepDotOn(ChartLayout layout, DateTime day) {
    for (final d in _stepDots(layout)) {
      if (d.step.day == day) return d;
    }
    return null;
  }

  /// Where the hovered / tapped dot's highlight ring goes, from the current
  /// geometry (the very dot the painter draws, even after a resize, a
  /// balance-axis zoom or new data moved it since the tip opened). Null for
  /// a lane tip: event lanes draw no dots, so there is nothing to ring.
  ({Offset center, double radius})? _tipRing(_DotTip tip) {
    final first = tip.dots.first;
    if (_isLaneTip(tip)) return null;
    final layout = _layout;
    final day = first.day;
    if (first.wholeDay && day != null) {
      // The day's net stands on the line, at its step dot (lanes draw no
      // dots of their own): never the first lane's slot under the line.
      final step = _stepDotOn(layout, day);
      if (step != null) return (center: step.center, radius: step.radius);
      // No step drawn (a zero net, or thinned out): the same spot on the
      // line, from today's layout.
      for (final o in _dots(layout)) {
        if (o.day == day) {
          return (
            center: Offset(o.center.dx, o.balanceY),
            radius: stepDotRadius(
              layout.plot.width / math.max(widget.visibleDays, 0.001),
            ),
          );
        }
      }
      return (center: Offset(first.center.dx, first.balanceY), radius: 3.5);
    }
    for (final o in _dots(layout)) {
      if (o.txId == null &&
          o.day == day &&
          o.isSeed == first.isSeed &&
          (day != null || first.isSeed)) {
        return (center: o.center, radius: o.radius);
      }
    }
    return (center: tip.anchor, radius: first.radius);
  }

  /// [step]'s drawn dot, if it is in view (and not thinned out).
  StepDot? _stepDotOf(BalanceStep step) {
    for (final d in _stepDots(_layout)) {
      if (d.step.day == step.day) return d;
    }
    return null;
  }

  /// Mouse hover over a step dot shows its tooltip (true: the pointer is on
  /// one, so lanes get no hover). Off every dot, an unpinned tip hides.
  bool _stepHover(ChartLayout layout, Offset pos) {
    final hit = layout.plot.contains(pos)
        ? _stepHit(layout, pos, touch: false)
        : null;
    if (hit == null) {
      if (!_stepPinned && _stepTip.value != null) _stepTip.value = null;
      return false;
    }
    if (_stepTip.value?.day != hit.step.day) {
      _stepPinned = false;
      _stepTip.value = hit.step;
    }
    if (_hoverDots.value != null) {
      _hoverDots.value = null;
      _tapTip = false;
    }
    _switchTimer?.cancel();
    _switchTimer = null;
    if (_overDot) setState(() => _overDot = false);
    return true;
  }

  /// The step dot a press at [pos] is for: within its hit radius (22px
  /// mouse / 44px touch target) above the line and level with the dot;
  /// lower down only where no event lane is (a lane's own tap opens its
  /// menu).
  StepDot? _stepHit(ChartLayout layout, Offset pos, {required bool touch}) {
    final hit = stepDotAt(_stepDots(layout), pos, touch: touch);
    if (hit == null) return null;
    if (pos.dy <= hit.center.dy + hit.radius + 3) return hit;
    return _laneDotAt(layout, pos, slop: touch ? 6 : 2) == null ? hit : null;
  }

  /// A step dot [pos] is right on (within 6px of its edge), which beats
  /// a nearby net chip.
  StepDot? _stepOnDot(ChartLayout layout, Offset pos) {
    for (final d in _stepDots(layout)) {
      if ((d.center - pos).distance <= d.radius + 6) return d;
    }
    return null;
  }

  void _clearStepTip() {
    _stepPinned = false;
    if (_stepTip.value != null) _stepTip.value = null;
  }

  /// A step dot's guides (balance on the y axis, date on the x axis) and
  /// its tooltip.
  List<Widget> _stepOverlay(ThemeData theme, StepDot dot) {
    final s = dot.step;
    final r = dot.radius + 2;
    return [
      ..._yGuide(
        theme,
        y: dot.center.dy,
        toX: dot.center.dx - r - 2,
        label: formatStepBalance(s.balance),
      ),
      ..._xGuide(
        theme,
        x: dot.center.dx,
        fromY: dot.center.dy + r + 2,
        day: s.day,
      ),
      Positioned.fill(
        child: IgnorePointer(
          child: CustomSingleChildLayout(
            delegate: _StepTipLayout(dot.center, r + 10, _layout.plot),
            child: _stepCard(theme, s),
          ),
        ),
      ),
    ];
  }

  Widget _stepCard(ThemeData theme, BalanceStep s) {
    final base = theme.textTheme.bodySmall ?? const TextStyle();
    final faint = base.copyWith(
      color: AppTheme.textFaint,
      fontWeight: FontWeight.w600,
    );
    return Container(
      key: const ValueKey('step-tooltip'),
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
      decoration: BoxDecoration(
        color: AppTheme.raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatSelectedDate(s.day),
            key: const ValueKey('step-tooltip-date'),
            style: faint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            formatStepDelta(s.delta),
            key: const ValueKey('step-tooltip-delta'),
            style: (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
              color: s.delta < 0 ? AppTheme.debitColor : AppTheme.creditColor,
              fontWeight: FontWeight.w800,
            ),
            maxLines: 1,
          ),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Balance '),
                TextSpan(
                  text: formatStepBalance(s.balance),
                  style: const TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            key: const ValueKey('step-tooltip-balance'),
            style: base.copyWith(color: AppTheme.textMuted),
            maxLines: 1,
          ),
          if (s.events > 0)
            Text(
              formatStepEvents(s.events),
              key: const ValueKey('step-tooltip-events'),
              style: faint,
              maxLines: 1,
            ),
        ],
      ),
    );
  }

  bool _tipShown(_DotTip? tip) =>
      tip != null &&
      _selA == null &&
      !(_pointer != null &&
          !_longPressTip &&
          !_stickyTip &&
          _mode != _Gesture.scrub);

  /// The dot whose balance the y-axis highlight shows: the day's dot
  /// (end-of-day balance) for a group, else the seed diamond.
  _Dot _highlightDot(_DotTip tip) =>
      tip.dots.firstWhere((d) => !d.isSeed, orElse: () => tip.dots.first);

  /// Guide line from the active dot to the left axis, and its exact
  /// balance on a pill in the y gutter.
  List<Widget> _yHighlight(ThemeData theme, _DotTip tip) {
    final dot = _highlightDot(tip);
    // Up to the ring, on the dot's current spot (so a resize or a new
    // balance range never leaves the guide off its dot).
    final ring = _tipRing(tip);
    return _yGuide(
      theme,
      y: ring?.center.dy ?? dot.balanceY,
      toX: ring != null
          ? ring.center.dx - ring.radius - 7
          : dot.center.dx - dot.radius - 2,
      label: formatMoneyAmount(dot.balanceAfter),
    );
  }

  /// A guide at [y] from the left axis to [toX], with [label] on a pill
  /// in the y gutter.
  List<Widget> _yGuide(
    ThemeData theme, {
    required double y,
    required double toX,
    required String label,
  }) {
    final layout = _layout;
    if (y < layout.plot.top || y > layout.plot.bottom) return const [];
    // Cyan, so the dot's crosshair never reads as the (mint) today line.
    const color = guideColor;
    final style = (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w800,
      color: Colors.white,
    );
    const pillH = 22.0;
    final top = (y - pillH / 2)
        .clamp(
          layout.plot.top + 1,
          math.max(layout.plot.top + 1, layout.plot.bottom - pillH - 1),
        )
        .toDouble();
    final left = layout.plot.left + 3;
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            key: const ValueKey('y-highlight-line'),
            painter: _GuideLinePainter(
              from: Offset(layout.plot.left, y),
              to: Offset(toX, y),
              color: color.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
      Positioned(
        left: left,
        top: top,
        height: pillH,
        child: IgnorePointer(
          child: Container(
            key: const ValueKey('y-highlight'),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                color.withValues(alpha: 0.35),
                AppTheme.raised,
              ),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color, width: 1.2),
            ),
            child: Text(label, style: style),
          ),
        ),
      ),
    ];
  }

  /// The date of the dot [_yHighlight] follows: its occurrences' day, or
  /// the seed date for the opening-balance diamond.
  DateTime _highlightDay(_Dot dot) =>
      dateOnly(dot.day ?? dot.occurrence?.date ?? widget.seedDate);

  /// Matching vertical guide from the active dot down to the date lanes,
  /// the dot's day lit across the lanes, and its exact date on a pill in the
  /// day lane (styled like the y pill), so the date reads even when that
  /// day's tick is thinned out. Same lifetime as [_yHighlight].
  List<Widget> _xHighlight(ThemeData theme, _DotTip tip) {
    final dot = _highlightDot(tip);
    final ring = dot.wholeDay ? _tipRing(tip) : null;
    return _xGuide(
      theme,
      x: ring?.center.dx ?? dot.center.dx,
      fromY: ring != null
          ? ring.center.dy + ring.radius + 7
          : dot.center.dy + dot.radius + 2,
      day: _highlightDay(dot),
    );
  }

  /// A guide at [x] from [fromY] down to the date lanes, [day] lit across
  /// them and its date on a pill in the day lane.
  List<Widget> _xGuide(
    ThemeData theme, {
    required double x,
    required double fromY,
    required DateTime day,
  }) {
    final layout = _layout;
    if (x < layout.plot.left || x > layout.plot.right) return const [];
    // Cyan, so the dot's crosshair never reads as the (mint) today line.
    const color = guideColor;
    final axis = layout.axis;
    final x0 = layout.xOf(day, widget.viewStart, widget.visibleDays);
    final x1 = layout.xOf(
      addCalendarDays(day, 1),
      widget.viewStart,
      widget.visibleDays,
    );
    final colLeft = math.max(axis.left, math.min(x0, x1));
    final colRight = math.min(axis.right, math.max(x0, x1));
    final style = (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w800,
      color: Colors.white,
    );
    const pillH = 22.0;
    final band = layout.dayBand ?? layout.weekBand ?? layout.monthBand;
    final pillTop = (band.center.dy - pillH / 2)
        .clamp(axis.top, math.max(axis.top, axis.bottom - pillH))
        .toDouble();
    final label = formatSelectedDate(day);
    final textW = (TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout()).width;
    // Never wider than the axis (a 320px phone): long dates ellipsize.
    final pillW = math.min(textW + 16, math.max(40.0, axis.width - 2));
    final pillLeft = (x - pillW / 2)
        .clamp(axis.left + 1, math.max(axis.left + 1, axis.right - pillW - 1))
        .toDouble();
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            key: const ValueKey('x-highlight-line'),
            painter: _GuideLinePainter(
              from: Offset(x, fromY),
              to: Offset(x, axis.top),
              color: color.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
      if (colRight > colLeft)
        Positioned(
          left: colLeft,
          top: axis.top,
          width: colRight - colLeft,
          height: axis.height,
          child: IgnorePointer(
            child: ColoredBox(
              key: const ValueKey('x-highlight-day'),
              color: color.withValues(alpha: 0.22),
            ),
          ),
        ),
      Positioned(
        left: pillLeft,
        top: pillTop,
        width: pillW,
        height: pillH,
        child: IgnorePointer(
          child: Container(
            key: const ValueKey('x-highlight'),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                color.withValues(alpha: 0.35),
                AppTheme.raised,
              ),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color, width: 1.2),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              label,
              style: style,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    ];
  }

  /// Guide line, day highlight and floating date bubble while picking.
  List<Widget> _pickOverlay(ThemeData theme) {
    final layout = _layout;
    final day = _pickDay!;
    final pos = _pickPos ?? layout.axis.center;
    final x0 = layout.xOf(day, widget.viewStart, widget.visibleDays);
    final x1 = layout.xOf(
      addDays(day, 1),
      widget.viewStart,
      widget.visibleDays,
    );
    final left = x0.clamp(layout.plot.left, layout.plot.right).toDouble();
    final right = x1.clamp(layout.plot.left, layout.plot.right).toDouble();
    final cx = (left + right) / 2;
    const color = AppTheme.accent;
    final pinned = _pickPinned;
    // The day's totals show from touch-down, live while dragging, and stay
    // on release.
    final stats = pickDayStats(day);
    final bubbleW = widget.onTrimDay == null ? 256.0 : 292.0;
    final bubbleH = stats.balance == null ? 64.0 : 84.0;
    // Above the finger on touch so it stays visible; just above the cursor
    // otherwise. Clamped inside the chart.
    final lift = _pickTouch ? 84.0 : 56.0;
    final bx = (cx - bubbleW / 2)
        .clamp(4.0, math.max(4.0, _size.width - bubbleW - 4))
        .toDouble();
    // Bottom-anchored, so a taller bubble grows away from the finger.
    final by = (pos.dy - lift + 30 - bubbleH)
        .clamp(4.0, math.max(4.0, _size.height - bubbleH - 4))
        .toDouble();
    return [
      Positioned(
        left: left,
        top: layout.plot.top,
        width: math.max(2, right - left),
        height: layout.axis.bottom - layout.plot.top,
        child: IgnorePointer(
          child: ColoredBox(color: color.withValues(alpha: 0.14)),
        ),
      ),
      // The guide sits on the day's start (its left edge), like the
      // selection edges; the band fills the day and the bubble centres on it.
      if (x0 >= layout.plot.left - 1 && x0 <= layout.plot.right + 1)
        Positioned(
          key: const ValueKey('pick-line'),
          left: x0 - 1,
          top: layout.plot.top,
          width: 2,
          height: layout.axis.bottom - layout.plot.top,
          child: IgnorePointer(child: ColoredBox(color: color)),
        ),
      Positioned(
        left: bx,
        top: by,
        width: bubbleW,
        height: bubbleH,
        // One bubble for pressed, dragging and released (and a tap): same
        // content, the + throughout. While the pointer is still down
        // it ignores pointers (they belong to the drag).
        child: KeyedSubtree(
          key: _pinKey,
          child: IgnorePointer(
            ignoring: !pinned,
            child: _pickBubble(theme, day, stats),
          ),
        ),
      ),
    ];
  }

  /// Money in / out on [day] (non-skipped occurrences of enabled series,
  /// once-off overrides included) and that day's closing balance (null
  /// before the seed date / outside the loaded series).
  @visibleForTesting
  PickDayStats pickDayStats(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    var gains = 0.0, losses = 0.0;
    for (final o in widget.series.occurrences) {
      if (o.date.year != d.year ||
          o.date.month != d.month ||
          o.date.day != d.day) {
        continue;
      }
      // Same rule as [dayNetTotals].
      if (!countsInDayTotals(o, enabled: _txOf(o.eventId)?.enabled)) {
        continue;
      }
      final v = o.signedDelta.toDouble();
      if (v >= 0) {
        gains += v;
      } else {
        losses -= v;
      }
    }
    double? balance;
    for (final p in widget.series.points) {
      if (p.date.year == d.year &&
          p.date.month == d.month &&
          p.date.day == d.day) {
        balance = p.closingBalance.toDouble();
        break;
      }
    }
    return PickDayStats(gains: gains, losses: losses, balance: balance);
  }

  /// The pick's bubble: date, the day's money in / out and closing balance
  /// ([stats]) and the day's "+", its only action (no close button).
  /// Identical while pressed, dragging and released; "+" acts once the
  /// pick is pinned.
  Widget _pickBubble(ThemeData theme, DateTime day, PickDayStats stats) {
    // A dark card like the dot popup, edged in the action colour, so the
    // day's green / red totals read clearly.
    const fg = AppTheme.accent;
    final btn = IconButton.styleFrom(
      backgroundColor: fg.withValues(alpha: 0.18),
      foregroundColor: fg,
      visualDensity: VisualDensity.compact,
    );
    final small = theme.textTheme.labelSmall ?? const TextStyle();
    String money(double v) =>
        formatMoneyAmount(v, decimalDigits: v == 0 ? 0 : null);
    final balance = stats.balance;
    final low = balance != null && belowAlert(balance, widget.lossThreshold);
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: Material(
        key: const ValueKey('pick-bubble'),
        elevation: 10,
        color: AppTheme.overlay,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: fg, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatOccurrenceDate(day),
                      key: const ValueKey('pick-date'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    // The day's money in (green) and out (red), overrides
                    // included (they come from the projected occurrences).
                    Text.rich(
                      key: const ValueKey('pick-day-totals'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      TextSpan(
                        style: small.copyWith(fontWeight: FontWeight.w700),
                        children: [
                          TextSpan(
                            text: '+${money(stats.gains)}',
                            style: TextStyle(
                              color: stats.gains > 0
                                  ? AppTheme.creditColor
                                  : AppTheme.textFaint,
                            ),
                          ),
                          const TextSpan(
                            text: '  ·  ',
                            style: TextStyle(color: AppTheme.textFaint),
                          ),
                          TextSpan(
                            text: '−${money(stats.losses)}',
                            style: TextStyle(
                              color: stats.losses > 0
                                  ? AppTheme.debitColor
                                  : AppTheme.textFaint,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (balance != null)
                      Text.rich(
                        key: const ValueKey('pick-day-balance'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        TextSpan(
                          text: 'Balance end of day: ',
                          style: small.copyWith(color: AppTheme.textFaint),
                          children: [
                            TextSpan(
                              text: money(balance),
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: low
                                    ? AppTheme.debitColor
                                    : AppTheme.creditColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              // The only action. Shows from the press on (while dragging
              // the pointer is busy, so it acts once the pick is pinned).
              const SizedBox(width: 8),
              if (widget.onTrimDay != null) ...[
                _trimDayButton(day, btn),
                const SizedBox(width: 4),
              ],
              IconButton(
                key: const ValueKey('pick-add'),
                tooltip: 'Add an event on ${formatOccurrenceDate(day)}',
                style: btn,
                icon: const Icon(Icons.add_rounded, size: 22),
                onPressed: _addFromPin,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The pick bubble's ✂: ends every event on [day] (the page confirms,
  /// with one Undo). Disabled, saying why, when [BalanceChart.trimDayBlock]
  /// has a reason.
  Widget _trimDayButton(DateTime day, ButtonStyle style) {
    final block = widget.trimDayBlock?.call(day);
    return IconButton(
      key: const ValueKey('pick-trim'),
      tooltip: block ?? 'End all events on ${formatOccurrenceDate(day)}',
      style: style,
      icon: const Icon(Icons.content_cut_rounded, size: 20),
      onPressed: block != null ? null : () => widget.onTrimDay!(day),
    );
  }

  /// Shaded band, edge lines, 44px drag handles and the summary card.
  List<Widget> _selectionOverlay(ThemeData theme) {
    final layout = _layout;
    final (s, e) = orderedDays(_selA!, _selB!);
    final dayPx = layout.plot.width / math.max(widget.visibleDays, 0.001);
    final rawX0 = layout.xOf(s, widget.viewStart, widget.visibleDays);
    final rawX1 = layout.xOf(
      addCalendarDays(e, 1),
      widget.viewStart,
      widget.visibleDays,
    );
    final x0 = rawX0.clamp(layout.plot.left, layout.plot.right).toDouble();
    final x1 = rawX1.clamp(layout.plot.left, layout.plot.right).toDouble();
    final top = layout.plot.top;
    final height = layout.plot.height;
    const color = AppTheme.accent;
    const hit = 44.0;
    final summary = summarizePeriod(
      series: widget.series,
      start: s,
      end: e,
      seedDate: _lineStart,
      seedBalance: widget.seedBalance,
      threshold: widget.lossThreshold,
    );

    double centreX(DateTime d) =>
        layout.xOf(addDays(d, 0.5), widget.viewStart, widget.visibleDays);

    Widget edgeHandle(Key key, double x, bool isStart) => Positioned(
      left: x - hit / 2,
      top: top,
      width: hit,
      height: height,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (_) {
            _clearTip();
            _selDragX = centreX(isStart ? s : e);
            _selDragA = isStart ? e : s; // the edge that stays put
          },
          onPanUpdate: (d) {
            _selDragX += d.delta.dx;
            final day = _dayAt(
              _selDragX.clamp(layout.plot.left, layout.plot.right - 0.5),
            );
            setState(() {
              _selA = _selDragA;
              _selB = day;
            });
          },
          child: Center(
            child: Container(
              width: 8,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white70, width: 1),
              ),
            ),
          ),
        ),
      ),
    );

    // Fully scrolled out of view: keep the selection (and its card) but
    // draw no band or handles until it comes back.
    if (rawX1 <= layout.plot.left || rawX0 >= layout.plot.right) {
      return [_selectionCard(theme, summary, x0, x1)];
    }
    final widgets = <Widget>[
      Positioned(
        left: x0,
        top: top,
        width: math.max(0, x1 - x0),
        height: height,
        child: IgnorePointer(
          child: Container(
            key: const ValueKey('selection-band'),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              border: Border.symmetric(
                vertical: BorderSide(
                  color: color.withValues(alpha: 0.9),
                  width: 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    ];
    if (!_selecting) {
      // Always present (possibly 0 wide) so the handles keep their
      // element (and an in-flight drag) when the band gets narrow.
      final bodyL = x0 + hit / 2, bodyR = math.max(x0 + hit / 2, x1 - hit / 2);
      {
        widgets.add(
          Positioned(
            left: bodyL,
            top: top,
            width: bodyR - bodyL,
            height: height,
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                key: const ValueKey('selection-body'),
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: (_) {
                  _selDragX = 0;
                  _selDragA = s;
                  _selDragB = e;
                },
                onPanUpdate: (d) {
                  _selDragX += d.delta.dx;
                  final shift = (_selDragX / math.max(dayPx, 0.001)).round();
                  setState(() {
                    _selA = addCalendarDays(_selDragA!, shift);
                    _selB = addCalendarDays(_selDragB!, shift);
                  });
                },
              ),
            ),
          ),
        );
      }
      // Off-screen edges keep a handle pinned at the plot edge.
      widgets.add(edgeHandle(const ValueKey('selection-start'), x0, true));
      widgets.add(edgeHandle(const ValueKey('selection-end'), x1, false));
    }
    widgets.add(_selectionCard(theme, summary, x0, x1));
    return widgets;
  }

  Widget _selectionCard(
    ThemeData theme,
    PeriodSummary sum,
    double x0,
    double x1,
  ) {
    final layout = _layout;
    final phone = _size.width < 600;
    final small = theme.textTheme.bodySmall ?? const TextStyle();
    final label = small.copyWith(color: AppTheme.textMuted);
    final strong = (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w800,
    );
    final dm = DateFormat('dd/MM');
    final range = DateFormat('d MMM y');
    Color signColor(double v) => v > 0
        ? AppTheme.creditColor
        : v < 0
        ? AppTheme.debitColor
        : AppTheme.textMuted;
    Widget row(String name, String detail, Widget value, Key key) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        key: key,
        children: [
          Text(name, style: theme.textTheme.labelMedium),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              detail,
              style: label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          value,
        ],
      ),
    );
    final pct = sum.percent;
    final net = sum.net;
    final header = Row(
      children: [
        const Padding(
          padding: EdgeInsets.only(right: 6),
          child: Icon(
            Icons.drag_indicator_rounded,
            size: 16,
            color: AppTheme.textMuted,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sum.days == 1
                    ? range.format(sum.start)
                    : '${DateFormat(sum.start.year == sum.end.year ? 'd MMM' : 'd MMM y').format(sum.start)} – ${range.format(sum.end)}',
                key: const ValueKey('selection-range'),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                formatSpanDuration(
                  sum.start,
                  sum.end,
                  precision: durationPrecisionFor(widget.visibleDays),
                ),
                key: const ValueKey('selection-duration'),
                maxLines: 1,
                softWrap: false,
                style: label,
              ),
            ],
          ),
        ),
        SizedBox(
          width: phone ? 40 : 32,
          height: phone ? 40 : 32,
          child: IconButton(
            key: const ValueKey('selection-close'),
            tooltip: 'Close selection',
            padding: EdgeInsets.zero,
            iconSize: 18,
            onPressed: _clearSelection,
            icon: const Icon(Icons.close_rounded),
          ),
        ),
      ],
    );
    final stats = <Widget>[
      row(
        'Start',
        'opening ${dm.format(sum.start)}',
        Text(
          formatMoneyAmount(sum.startBalance),
          key: const ValueKey('selection-start-balance'),
          style: strong,
        ),
        const ValueKey('sel-row-start'),
      ),
      row(
        'End',
        'close ${dm.format(sum.end)}',
        Text(
          formatMoneyAmount(sum.endBalance),
          key: const ValueKey('selection-end-balance'),
          style: strong,
        ),
        const ValueKey('sel-row-end'),
      ),
      row(
        net > 0
            ? 'Gain'
            : net < 0
            ? 'Loss'
            : 'No change',
        pct == null || net == 0
            ? ''
            : '${net >= 0 ? '+' : '−'}${pct.abs().toStringAsFixed(1)}%',
        Text(
          formatSignedAmount(net),
          key: const ValueKey('selection-net'),
          style: strong.copyWith(color: signColor(net)),
        ),
        const ValueKey('sel-row-net'),
      ),
      const Divider(height: 10),
      row(
        'Total gains',
        '',
        Text(
          formatSignedAmount(sum.gains),
          key: const ValueKey('selection-gains'),
          style: strong.copyWith(color: signColor(sum.gains)),
        ),
        const ValueKey('sel-row-gains'),
      ),
      row(
        'Total losses',
        '',
        Text(
          formatSignedAmount(sum.losses),
          key: const ValueKey('selection-losses'),
          style: strong.copyWith(color: signColor(sum.losses)),
        ),
        const ValueKey('sel-row-losses'),
      ),
      row(
        'Events',
        '',
        Text(
          '${sum.occurrences.length}',
          key: const ValueKey('selection-count'),
          style: strong,
        ),
        const ValueKey('sel-row-count'),
      ),
      const Divider(height: 10),
      if (sum.lowestBalance != null)
        row(
          'Lowest',
          sum.lowestDate == null ? '' : dm.format(sum.lowestDate!),
          Text(
            formatMoneyAmount(sum.lowestBalance!),
            key: const ValueKey('selection-lowest'),
            style: strong.copyWith(
              color: belowAlert(sum.lowestBalance!, widget.lossThreshold)
                  ? AppTheme.debitColor
                  : null,
            ),
          ),
          const ValueKey('sel-row-lowest'),
        ),
      row(
        'Alert',
        '< ${formatMoneyAmount(widget.lossThreshold)}',
        Text(
          sum.alertDate == null ? 'Never' : dm.format(sum.alertDate!),
          key: const ValueKey('selection-alert'),
          style: strong.copyWith(
            color: sum.alertDate == null
                ? AppTheme.creditColor
                : AppTheme.debitColor,
          ),
        ),
        const ValueKey('sel-row-alert'),
      ),
      if (widget.onPlanPeriod != null || widget.onAddForPeriod != null)
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Row(
            children: [
              if (widget.onPlanPeriod != null)
                OutlinedButton.icon(
                  key: const ValueKey('sel-plan'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: () => widget.onPlanPeriod!(sum),
                  icon: const Icon(Icons.flag_rounded, size: 16),
                  label: const Text('Plan…'),
                ),
              if (widget.onAddForPeriod != null) ...[
                const SizedBox(width: 6),
                IconButton.outlined(
                  key: const ValueKey('sel-add'),
                  tooltip: 'Add an event for this period',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: () => widget.onAddForPeriod!(
                    dateOnly(sum.start),
                    dateOnly(sum.end),
                  ),
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ],
          ),
        ),
    ];
    Widget card = Material(
      key: _cardKey,
      elevation: 12,
      color: AppTheme.raised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(phone ? 16 : 12),
        side: const BorderSide(color: Color(0x22FFFFFF)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
        child: Column(
          key: const ValueKey('selection-card'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Column(mainAxisSize: MainAxisSize.min, children: stats),
            ),
          ],
        ),
      ),
    );
    // The whole card is the grab surface (the close button keeps its tap).
    // The card sits above the chart's listener, so this never pans the
    // chart, moves the selection or starts hold-to-select.
    card = MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        key: const ValueKey('selection-card-handle'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          final box = _cardKey.currentContext?.findRenderObject();
          final chart = context.findRenderObject();
          if (box is RenderBox && chart is RenderBox) {
            _cardPos ??= chart.globalToLocal(box.localToGlobal(Offset.zero));
          }
        },
        onPanUpdate: (d) {
          final from = _cardPos;
          if (from == null) return;
          setState(() => _cardPos = _clampCard(from + d.delta, _cardSize));
        },
        child: card,
      ),
    );
    final maxW = math.max(160.0, _size.width * 0.85);
    card = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW),
      child: IntrinsicWidth(child: card),
    );
    final moved = _cardPos;
    if (moved != null) {
      final w = math.min(_cardSize.width, maxW);
      final maxH = phone
          ? math.max(120.0, math.min(_size.height * 0.5, 340.0))
          : math.max(160.0, layout.plot.height - 16);
      // Re-clamp every build so resizes keep it inside the chart.
      final size = _cardSize;
      final pos = _clampCard(moved, Size(w, math.min(size.height, maxH)));
      return Positioned(
        left: pos.dx,
        top: pos.dy,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: card,
        ),
      );
    }
    if (phone) {
      // Bottom sheet-like: over the date lanes, leaving the band's upper
      // part (where the line usually is) visible.
      // Just above the date lanes.
      final bottom = math.max(6.0, _size.height - layout.plot.bottom + 6);
      final maxH = math.max(
        120.0,
        math.min(
          _size.height * 0.5,
          math.min(340.0, _size.height - bottom - 8),
        ),
      );
      return Positioned(
        right: 6,
        bottom: bottom,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: card,
        ),
      );
    }
    final w = math.min(_cardSize.width, maxW);
    final fitsRight = x1 + 12 + w <= _size.width - 8;
    final fitsLeft = x0 - 12 - w >= layout.plot.left;
    final left = fitsRight
        ? x1 + 12
        : fitsLeft
        ? x0 - 12 - w
        : (_size.width - w - 8);
    return Positioned(
      left: left.clamp(4.0, math.max(4.0, _size.width - w - 4)).toDouble(),
      top: layout.plot.top + 8,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.max(160, layout.plot.height - 16),
        ),
        child: card,
      ),
    );
  }

  void _onHover(PointerHoverEvent event) {
    // Touch has no hover (browsers may synthesise one on release).
    if (event.kind == PointerDeviceKind.touch) return;
    if (_pointer != null || _multiTouch || _size == Size.zero) return;
    final pos = event.localPosition;
    _lastHover = pos;
    final layout = _layout;
    if (_pickPinned && _keyContains(_pinKey, pos)) {
      if (_hoverDay.value != null) _hoverDay.value = null;
      if (_overAdd) setState(() => _overAdd = false);
      return;
    }
    _overTipCard = _tipCardContains(pos);
    if (_overTipCard) {
      _switchTimer?.cancel();
      _switchTimer = null;
      // Heading for (or on) the popup's Edit: keep the tip, no "+".
      if (_hoverDay.value != null) _hoverDay.value = null;
      if (_overAdd) setState(() => _overAdd = false);
      return;
    }
    if (!_hasSelection && !_stepHover(layout, pos)) {
      _updateDotHover(layout, pos);
    }
    final axisBottom =
        (layout.dayBand ?? layout.weekBand ?? layout.monthBand).bottom;
    final inColumns =
        pos.dx >= layout.plot.left &&
        pos.dx <= layout.plot.right &&
        pos.dy >= layout.plot.top &&
        pos.dy <= axisBottom;
    if (!inColumns) {
      if (_hoverDay.value != null) _hoverDay.value = null;
      if (_overAdd) setState(() => _overAdd = false);
      return;
    }
    final under = layout.dateAt(pos.dx, widget.viewStart, widget.visibleDays);
    final current = _hoverDay.value;
    final rect = current == null ? null : _dayButtonRect(layout, current);
    final overAdd = rect != null && rect.contains(pos);
    if (overAdd != _overAdd) setState(() => _overAdd = overAdd);
    if (current == under || overAdd) return;
    _hoverDay.value = under;
  }

  // Hover runs on every mouse move; recomputing the visible window (a sort of
  // the whole series) each time made hovering a multi-year view stutter.
  VisibleBalance? _visibleMemo;
  Object? _visibleMemoKey;

  VisibleBalance? _visible() {
    final key = (
      widget.series,
      widget.viewStart,
      widget.visibleDays,
      _lineStart,
    );
    if (_visibleMemoKey != key) {
      _visibleMemoKey = key;
      _visibleMemo = visibleBalance(
        points: widget.series.points,
        viewStart: widget.viewStart,
        viewEnd: addDays(widget.viewStart, widget.visibleDays),
        seedDate: _lineStart,
      );
    }
    return _visibleMemo;
  }

  /// In the hovered [day]'s column of the bottom (day) axis row, so it never
  /// covers the line or its dots.
  Rect? _dayButtonRect(ChartLayout layout, DateTime day) {
    final band = layout.dayBand ?? layout.weekBand ?? layout.monthBand;
    final size = _addButtonSize;
    final leftEdge = layout.xOf(day, widget.viewStart, widget.visibleDays);
    final rightEdge = layout.xOf(
      addDays(day, 1),
      widget.viewStart,
      widget.visibleDays,
    );
    final left = _clampEdge(
      (leftEdge + rightEdge) / 2 - size / 2,
      layout.plot.left,
      layout.plot.right - size,
    );
    final top = _clampEdge(
      band.center.dy - size / 2,
      layout.plot.bottom,
      (_size.height - size).toDouble(),
    );
    return Rect.fromLTWH(left, top, size, size);
  }

  LaneSet? _lanesMemo;
  Object? _lanesKey;

  /// The stacked lanes (see stack_lanes.dart), rebuilt only when the
  /// events or their order change.
  LaneSet _laneSet() {
    final key = (
      widget.events,
      widget.otherEvents,
      widget.laneOrder,
      widget.otherLaneOrder,
    );
    final last = _lanesKey as (Map, Map, List, List)?;
    if (last != null &&
        _lanesMemo != null &&
        mapEquals(last.$1, key.$1) &&
        mapEquals(last.$2, key.$2) &&
        listEquals(last.$3, key.$3) &&
        listEquals(last.$4, key.$4)) {
      return _lanesMemo!;
    }
    _lanesKey = key;
    return _lanesMemo = buildLaneSet(
      order: widget.laneOrder,
      events: widget.events,
      others: widget.otherEvents,
      otherOrder: widget.otherLaneOrder,
    );
  }

  List<_Dot>? _dotsMemo;
  Object? _dotsKey;

  /// Occurrence dots as the painter draws them (same x, y, stacking, radius).
  List<_Dot> _dots(ChartLayout layout) {
    final range = _ensureYRange();
    final key = (
      widget.series,
      widget.viewStart,
      widget.visibleDays,
      range,
      layout.plot,
      widget.seedDate,
      widget.seedBalance,
      _lineStart,
      _laneSet(),
    );
    if (_dotsKey == key && _dotsMemo != null) return _dotsMemo!;
    _dotsKey = key;
    _wholeDayMemo.clear();
    final dots = <_Dot>[];
    if (range == null) return _dotsMemo = dots;
    final scale = _YScale(range.min, range.max, layout.plot);
    final seed = dateOnly(widget.seedDate);
    final lineStart = _lineStart;
    final viewEnd = addDays(widget.viewStart, widget.visibleDays);
    final closes = <DateTime, double>{
      for (final p in widget.series.points)
        dateOnly(p.date): p.closingBalance.toDouble(),
    };
    final dayPx = layout.plot.width / math.max(widget.visibleDays, 0.001);
    final radius = dayPx > 28
        ? 4.5
        : dayPx > 12
        ? 3.4
        : 2.2;
    final seedBalance = widget.seedBalance;
    if (seedBalance != null) {
      final x = layout.xOf(seed, widget.viewStart, widget.visibleDays);
      final c = Offset(x, scale.yOf(seedBalance));
      if (layout.plot.inflate(2).contains(c)) {
        dots.add(_Dot(c, seedVertexRadius(radius), const [], seedBalance));
      }
    }
    final lanes = _laneSet();
    final laneH = lanes.isEmpty ? 0.0 : _laneHeight(lanes, layout);
    if (!lanes.isEmpty && dayPx < laneDotsMinDayPx) return _dotsMemo = dots;
    for (final g in groupByDay(widget.series.occurrences)) {
      final day = g.day;
      if (day.isBefore(lineStart) ||
          !addCalendarDays(day, 1).isAfter(widget.viewStart) ||
          day.isAfter(viewEnd)) {
        continue;
      }
      final close = closes[day];
      if (close == null) continue;
      // The day's left edge: where its balance steps and its lanes begin.
      final x = layout.xOf(day, widget.viewStart, widget.visibleDays);
      final balanceY = scale.yOf(close);
      if (lanes.isEmpty) {
        dots.add(_Dot(Offset(x, balanceY), radius, g.all, close, day: day));
        continue;
      }
      final r = laneDotRadius(radius, laneH);
      final laneDots = laneDotsForDay(
        lanes: lanes,
        group: g,
        balanceY: balanceY,
        thickness: laneH,
      );
      for (final d in laneDots.dots) {
        dots.add(
          _Dot(
            Offset(x, d.y),
            r,
            d.own,
            close,
            balanceY: balanceY,
            day: day,
            txId: d.txId,
            idle: d.idle,
          ),
        );
      }
    }
    return _dotsMemo = dots;
  }

  /// [nearest] with the dots drawn on top of it (a different day group at
  /// the same spot, e.g. the opening diamond). Dots of one day, in different
  /// lanes, are never merged: each inspects its own event only.
  List<_Dot> _overlapping(ChartLayout layout, _Dot nearest) => [
    nearest,
    for (final d in _dots(layout))
      if (!nearest.wholeDay &&
          !nearest.idle &&
          !d.idle &&
          !identical(d, nearest) &&
          !identical(d.occurrences, nearest.occurrences) &&
          // Lane dots of one day are never merged: one dot, one event.
          !(d.txId != null && d.day == nearest.day) &&
          (d.center - nearest.center).distance < 2)
        d,
  ];

  /// The dot at [pos]: the nearest within [maxDistance], else the dot whose
  /// painted label (amount + names, pushed or "+N more") is under [pos].
  /// Priority: dot > label > the chart itself.
  /// With stacked lanes a net chip is an explicit target: inside its rect it
  /// wins over the (far bigger) dot hit radius, whose nearest dot is just
  /// one event.
  _Dot? _dotAt(ChartLayout layout, Offset pos, double maxDistance) =>
      (_laneSet().isEmpty ? null : _labelDotAt(layout, pos, slop: 0)) ??
      _nearestDot(layout, pos, maxDistance) ??
      _labelDotAt(layout, pos);

  /// The dot whose painted label contains [pos] (topmost / last painted).
  _Dot? _labelDotAt(
    ChartLayout layout,
    Offset pos, {
    double slop = labelHitSlop,
  }) {
    if (!layout.plot.contains(pos)) return null;
    for (final hit in _labelHits.reversed) {
      if (!hit.rect.inflate(slop).contains(pos)) continue;
      for (final d in _dots(layout)) {
        if ((d.center - hit.dot).distance < 1.5) return _wholeDay(layout, d);
      }
    }
    return null;
  }

  /// A day's net chip speaks for the whole day: the popup lists every
  /// event on it (a lane dot, by contrast, inspects only its own).
  _Dot _wholeDay(ChartLayout layout, _Dot d) {
    final day = d.day;
    if (d.isSeed || day == null || _laneSet().isEmpty) return d;
    return _wholeDayMemo[day] ??= _wholeDayOf(layout, d, day);
  }

  final Map<DateTime, _Dot> _wholeDayMemo = {};

  _Dot _wholeDayOf(ChartLayout layout, _Dot d, DateTime day) {
    final all = <Occurrence>[];
    for (final o in _dots(layout)) {
      if (o.day == day) all.addAll(o.occurrences);
    }
    // Its card anchors at the first lane's slot (clear of the next
    // days' chips); its ring and guides go on the step dot ([_tipRing]).
    return _Dot(
      d.center,
      d.radius,
      all,
      d.balanceAfter,
      balanceY: d.balanceY,
      day: day,
      wholeDay: true,
    );
  }

  /// Nearest dot to [pos] within [maxDistance], by 2D distance. Lane dots
  /// are hidden until their lane is hovered / tapped ([_laneDotAt]), so only
  /// the ones always drawn count: the opening diamond, and occurrences with
  /// no lane (on the line itself).
  _Dot? _nearestDot(ChartLayout layout, Offset pos, double maxDistance) {
    if (!layout.plot.inflate(maxDistance).contains(pos)) return null;
    final dots = _dots(layout)
        .where(
          (d) => d.txId == null && layout.plot.inflate(8).contains(d.center),
        )
        .toList();
    final i = nearestPointIndex(
      [for (final d in dots) d.center],
      pos,
      maxDistance: maxDistance,
    );
    return i == null ? null : dots[i];
  }

  List<(DateTime, double)>? _stepsMemo;
  List<DayGroup>? _groupsMemo;
  Object? _stepsKey;

  /// Balance steps (day, closing balance), and the occurrence days, both in
  /// date order, for [_laneDotAt].
  (List<(DateTime, double)>, List<DayGroup>) _steps() {
    final key = widget.series;
    if (!identical(_stepsKey, key) ||
        _stepsMemo == null ||
        _groupsMemo == null) {
      _stepsKey = key;
      final byDay = <DateTime, double>{
        for (final p in widget.series.points)
          dateOnly(p.date): p.closingBalance.toDouble(),
      };
      _stepsMemo = [
        for (final d in byDay.keys.toList()..sort()) (d, byDay[d]!),
      ];
      _groupsMemo = groupByDay(widget.series.occurrences).toList()
        ..sort((a, b) => a.day.compareTo(b.day));
    }
    return (_stepsMemo!, _groupsMemo!);
  }

  /// Index of the last entry of [days] on or before [day] (-1: none).
  static int _lastOnOrBefore<T>(
    List<T> list,
    DateTime Function(T) dayOf,
    DateTime day,
  ) {
    var lo = 0, hi = list.length - 1, best = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (dayOf(list[mid]).isAfter(day)) {
        hi = mid - 1;
      } else {
        best = mid;
        lo = mid + 1;
      }
    }
    return best;
  }

  /// The lane dot for the event lane under [pos]: anywhere along an
  /// event's band (any day it spans), its dot for the step the pointer is
  /// on (on the left edge of the step's day, where the balance changed), as
  /// if that dot itself were hovered. [slop] grows the stack's top and
  /// bottom a little (thin lanes). Null off every lane.
  _Dot? _laneDotAt(ChartLayout layout, Offset pos, {double slop = 2}) {
    final lanes = _laneSet();
    final range = _ensureYRange();
    if (lanes.isEmpty || range == null || !layout.plot.contains(pos)) {
      return null;
    }
    final dayPx = layout.plot.width / math.max(widget.visibleDays, 0.001);
    if (dayPx < laneDotsMinDayPx) return null;
    final day = layout.dateAt(pos.dx, widget.viewStart, widget.visibleDays);
    if (day.isBefore(_lineStart)) return null;
    final from = widget.dataFrom, through = widget.dataThrough;
    if (from != null && day.isBefore(from) && !from.isBefore(_lineStart)) {
      return null;
    }
    if (through != null && day.isAfter(through)) return null;
    final (steps, groups) = _steps();
    final si = _lastOnOrBefore(steps, (s) => s.$1, day);
    if (si < 0) return null;
    final active = lanes.activeOn(day);
    final m = active.length;
    if (m == 0) return null;
    final scale = _YScale(range.min, range.max, layout.plot);
    final h = _laneHeight(lanes, layout);
    final top0 = laneTop(scale.yOf(steps[si].$2), 0, m, h);
    if (pos.dy < top0 - slop || pos.dy > top0 + m * h + slop) return null;
    final slot = ((pos.dy - top0) / h).floor().clamp(0, m - 1);
    final lane = lanes.lanes[active[slot]];
    // The step: the last occurrence day on or before [day] (each balance
    // change is one), never before the lane's own first day.
    final gi = _lastOnOrBefore(groups, (g) => g.day, day);
    var stepDay = gi < 0 ? lane.start : groups[gi].day;
    var occ = gi < 0 ? const <Occurrence>[] : groups[gi].all;
    if (stepDay.isBefore(lane.start)) {
      stepDay = lane.start;
      occ = const [];
    }
    final ci = _lastOnOrBefore(steps, (s) => s.$1, stepDay);
    if (ci < 0) return null;
    final close = steps[ci].$2;
    final balanceY = scale.yOf(close);
    final dots = laneDotsForDay(
      lanes: lanes,
      group: DayGroup(stepDay, occ),
      balanceY: balanceY,
      thickness: h,
    ).dots;
    final d = dots.where((d) => d.txId == lane.id).firstOrNull;
    if (d == null) return null;
    final base = dayPx > 28
        ? 4.5
        : dayPx > 12
        ? 3.4
        : 2.2;
    final x = layout.xOf(stepDay, widget.viewStart, widget.visibleDays);
    return _Dot(
      Offset(x, d.y),
      laneDotRadius(base, h),
      d.own,
      close,
      balanceY: balanceY,
      day: stepDay,
      txId: lane.id,
      idle: d.idle,
    );
  }

  /// A lane tip whose dot scrolled off the left edge still points into the
  /// plot.
  Offset _tipAnchor(ChartLayout layout, _Dot d) => Offset(
    d.center.dx.clamp(layout.plot.left, layout.plot.right).toDouble(),
    d.center.dy,
  );

  /// Two lane dots are the same target (same event, same step).
  static bool _sameLaneDot(_Dot a, _Dot b) =>
      a.txId != null && a.txId == b.txId && a.day == b.day;

  /// Touch scrub: tooltip follows the dot nearest the finger; far from all
  /// dots it keeps the last one (still following the finger).
  void _updateScrub(Offset pos) {
    final layout = _layout;
    final lane = _laneDotAt(layout, pos, slop: 6);
    final current = _hoverDots.value;
    if (lane != null) {
      _hoverDots.value = _DotTip([lane], _tipAnchor(layout, lane), finger: pos);
      return;
    }
    final nearest = _nearestDot(layout, pos, scrubMaxDistance);
    if (nearest == null) {
      if (current != null) {
        _hoverDots.value = _DotTip(current.dots, current.anchor, finger: pos);
      }
      return;
    }
    final group = _overlapping(layout, nearest);
    _hoverDots.value = _DotTip(group, nearest.center, finger: pos);
  }

  /// Mouse hover: same nearest-dot logic and popup as touch, at the 18px
  /// mouse hit radius; same-day grouped dots list all their events.
  ///
  /// Lane dots are hidden: hovering anywhere on an event's lane shows that
  /// lane's dot for the step under the pointer and opens its popup, as if
  /// the dot itself were hovered. A net chip (whole day) wins inside its
  /// rect; the always-drawn dots (opening diamond, lane-less occurrences)
  /// next. Leaving for the popup (to reach Edit) keeps it: a move heading
  /// into the card ([_headingForCard]) waits a moment before switching.
  void _updateDotHover(ChartLayout layout, Offset pos) {
    _touchUi = false;
    try {
      _updateDotHoverInner(layout, pos);
    } finally {
      _syncOverDot(layout, pos);
    }
  }

  /// The click cursor: anywhere on an event's lane (a click opens its
  /// menu), or on any other hovered target (net chip, opening diamond).
  void _syncOverDot(ChartLayout layout, Offset pos) {
    final tip = _hoverDots.value;
    final over =
        tip != null &&
        (_isLaneTip(tip)
            ? layout.plot.contains(pos) &&
                  (_onRevealedDot(
                        layout,
                        tip.dots.first,
                        pos,
                        mouseDotHitRadius,
                      ) ||
                      _laneDotAt(layout, pos) != null)
            : !_tapTip);
    if (over != _overDot) setState(() => _overDot = over);
  }

  /// [pos] is within [r] of lane dot [d] (its clickable target).
  bool _onRevealedDot(ChartLayout layout, _Dot d, Offset pos, double r) {
    final a = _tipAnchor(layout, d);
    return (a - pos).distance <= r;
  }

  void _updateDotHoverInner(ChartLayout layout, Offset pos) {
    // On the revealed dot (its generous target reaches into the previous
    // step and the lanes beside it): keep it, so it can be clicked.
    final shown = _hoverDots.value;
    if (shown != null && _isLaneTip(shown) && !_tapTip) {
      final d = shown.dots.first;
      final a = _tipAnchor(layout, d);
      final lanes = _laneSet();
      final half = lanes.isEmpty ? 4.0 : _laneHeight(lanes, layout) / 2;
      if ((a.dx - pos.dx).abs() <= mouseDotHitRadius &&
          (a.dy - pos.dy).abs() <= math.max(half, 4) &&
          layout.plot.contains(pos)) {
        _aimFrom = pos;
        return;
      }
    }
    final chip = _laneSet().isEmpty ? null : _labelDotAt(layout, pos, slop: 0);
    final lane = chip == null ? _laneDotAt(layout, pos) : null;
    final nearest =
        chip ??
        lane ??
        _nearestDot(layout, pos, vertexHitRadius(PointerDeviceKind.mouse)) ??
        _labelDotAt(layout, pos);
    final overlapping = nearest == null
        ? const <_Dot>[]
        : lane != null
        ? [lane]
        : _overlapping(layout, nearest);
    final current = _hoverDots.value;
    final same =
        current != null &&
        overlapping.isNotEmpty &&
        (listEquals(current.dots, overlapping) ||
            (current.dots.length == 1 &&
                _sameLaneDot(current.dots.first, overlapping.first)));
    if (same) {
      _switchTimer?.cancel();
      _switchTimer = null;
      _aimFrom = pos;
      return;
    }
    // Heading for the open popup's card (to reach its Edit): hold the
    // current tip briefly instead of switching on the way.
    if (current != null && !_tapTip && _headingForCard(pos)) {
      _switchTimer ??= Timer(_switchGrace, () {
        _switchTimer = null;
        if (!mounted || _overTipCard) return;
        final p = _lastHover;
        if (p != null) _applyDotHover(_layout, p, force: true);
      });
      return;
    }
    _applyDotHover(layout, pos, overlapping: overlapping);
  }

  void _applyDotHover(
    ChartLayout layout,
    Offset pos, {
    List<_Dot>? overlapping,
    bool force = false,
  }) {
    _switchTimer?.cancel();
    _switchTimer = null;
    if (overlapping == null) {
      final chip = _laneSet().isEmpty
          ? null
          : _labelDotAt(layout, pos, slop: 0);
      final lane = chip == null ? _laneDotAt(layout, pos) : null;
      final nearest =
          chip ??
          lane ??
          _nearestDot(layout, pos, vertexHitRadius(PointerDeviceKind.mouse)) ??
          _labelDotAt(layout, pos);
      overlapping = nearest == null
          ? const <_Dot>[]
          : lane != null
          ? [lane]
          : _overlapping(layout, nearest);
    }
    _aimFrom = pos;
    if (overlapping.isEmpty) {
      // A tooltip pinned by a click stays until its timeout or next click.
      if (_hoverDots.value != null && !_tapTip) _hoverDots.value = null;
      return;
    }
    final current = _hoverDots.value;
    if (!force && current != null && listEquals(current.dots, overlapping)) {
      return;
    }
    final first = overlapping.first;
    _hoverDots.value = _DotTip(
      overlapping,
      first.txId != null ? _tipAnchor(layout, first) : first.center,
    );
  }

  /// Where the pointer was when it last settled on the shown tip's target:
  /// the apex of the "aim" triangle towards the popup card.
  Offset? _aimFrom;
  Offset? _lastHover;
  Timer? _switchTimer;
  static const Duration _switchGrace = Duration(milliseconds: 350);

  /// Whether the move from [_aimFrom] to [pos] heads into the popup card:
  /// [pos] is inside the triangle from [_aimFrom] to the card's near edge
  /// (grown a little), so crossing other lanes on the way keeps the tip.
  bool _headingForCard(Offset pos) {
    final from = _aimFrom;
    final card = _keyRect(_tipCardKey)?.inflate(10);
    if (from == null || card == null) return false;
    if (card.contains(pos)) return true;
    final nearX = from.dx < card.left
        ? card.left
        : from.dx > card.right
        ? card.right
        : null;
    final List<Offset> tri;
    if (nearX != null) {
      tri = [from, Offset(nearX, card.top), Offset(nearX, card.bottom)];
    } else {
      final nearY = from.dy < card.top ? card.top : card.bottom;
      tri = [from, Offset(card.left, nearY), Offset(card.right, nearY)];
    }
    return _inTriangle(pos, tri[0], tri[1], tri[2]);
  }

  static bool _inTriangle(Offset p, Offset a, Offset b, Offset c) {
    double cross(Offset o, Offset u, Offset v) =>
        (u.dx - o.dx) * (v.dy - o.dy) - (u.dy - o.dy) * (v.dx - o.dx);
    final d1 = cross(p, a, b), d2 = cross(p, b, c), d3 = cross(p, c, a);
    final neg = d1 < 0 || d2 < 0 || d3 < 0;
    final pos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(neg && pos);
  }

  /// [key]'s widget rect in chart coordinates (null: not laid out).
  Rect? _keyRect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    final me = context.findRenderObject();
    if (box is! RenderBox || me is! RenderBox || !box.attached) return null;
    return me.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
  }

  /// Last press was touch (44px popup targets) or a mouse.
  bool _touchUi = false;

  /// A row's ⋮ menu is open: the popup stays up behind it.
  bool _rowMenuOpen = false;

  /// The day a popup row is about: its occurrence's (or the seed's).
  DateTime _rowDay(Occurrence? o) => dateOnly(o?.date ?? widget.seedDate);

  /// A lone lane dot: revealed by hover / tap, with no popup card.
  static bool _isLaneTip(_DotTip tip) =>
      tip.dots.length == 1 &&
      tip.dots.first.txId != null &&
      !tip.dots.first.wholeDay &&
      tip.dots.first.day != null;

  /// The lane dot a mouse click at [pos] hits: the hover-revealed one,
  /// within its generous target (32px mouse, 44px touch), so a click on a
  /// dot just left of its step's edge still means that step. Any other
  /// tap / click on a lane opens the menu for the step under it
  /// ([_laneDotAt]); touch has no reveal-then-tap step.
  _Dot? _laneDotHit(ChartLayout layout, Offset pos, {required bool touch}) {
    final r = touch ? touchDotHitRadius : mouseDotHitRadius;
    final shown = _hoverDots.value;
    if (shown != null && _isLaneTip(shown)) {
      final d = shown.dots.first;
      if ((_tipAnchor(layout, d) - pos).distance <= r) return d;
    }
    if (touch) return null;
    // Just left of a step's edge is the previous step's lane: try the
    // next step's dot too.
    for (final probe in [pos, pos + Offset(r, 0)]) {
      final d = _laneDotAt(layout, probe, slop: 2);
      if (d != null && (_tipAnchor(layout, d) - pos).distance <= r) return d;
    }
    return null;
  }

  /// Opens lane dot [d]'s action menu at chart-local [at] (the tap; the
  /// dot when null): a header with the event's name and signed amount,
  /// a divider, then New Event From Here, Trim From Here and Edit Event /
  /// Edit Series, all for [d]'s day. Kept fully inside the chart (and the
  /// screen's safe area) by [placeTapMenu]. Items the user cannot use (a
  /// viewer, another stream they cannot edit, nothing left to trim) show
  /// disabled. Only a picked item acts.
  Future<void> _openDotMenu(_Dot d, {Offset? at}) async {
    final layout = _layout;
    final day = d.day!, id = d.txId!;
    _tapTipTimer?.cancel();
    _tapTip = true;
    final anchor = _tipAnchor(layout, d);
    _hoverDots.value = _DotTip([d], anchor);
    final own = widget.events[id];
    final other = own == null ? widget.otherEvents[id] : null;
    final event = own ?? other;
    final otherStream = other == null
        ? null
        : widget.combinedStreams[other.streamId];
    final VoidCallback? newHere = widget.onNewOnDay == null
        ? null
        : () => widget.onNewOnDay?.call(day);
    final VoidCallback? trim =
        own != null &&
            widget.onTrimOccurrence != null &&
            trimFromHere(own, day) != null
        ? () => widget.onTrimOccurrence?.call(own, day)
        : null;
    final VoidCallback? edit = own != null
        ? (widget.onEditEvent == null
              ? null
              : () => widget.onEditEvent?.call(own, day))
        : other != null &&
              otherStream != null &&
              otherStream.canEdit &&
              widget.onOpenOtherEvent != null
        ? () => widget.onOpenOtherEvent?.call(otherStream, other, day)
        : null;
    final VoidCallback? hide = own != null && widget.onHideEvent != null
        ? () => widget.onHideEvent?.call(own)
        : null;
    final hasHide = widget.onHideEvent != null;
    final once = event?.recurrenceMode == RecurrenceMode.once;
    final lane = _laneSet().lanes.where((l) => l.id == id).firstOrNull;
    final name = lane?.name ?? event?.name ?? '';
    final amount = lane?.amount ?? event?.signedAmount.toDouble() ?? 0;
    final me = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final itemH = _touchDown ? 44.0 : 36.0;
    const dividerH = 9.0, padV = 4.0;
    // The view (the chart, inset a little) within the screen's safe area
    // (and the menu's own 8px screen margin), in overlay coordinates.
    final safe = MediaQuery.paddingOf(context);
    final screen = Rect.fromLTRB(
      safe.left + 8,
      safe.top + 8,
      overlay.size.width - safe.right - 8,
      overlay.size.height - safe.bottom - 8,
    );
    final chart = (me.localToGlobal(Offset.zero, ancestor: overlay) & me.size)
        .deflate(4);
    final bounds = chart.intersect(screen);
    final width = math.max(
      math.min(_touchDown ? 264.0 : 248.0, bounds.width),
      140.0,
    );
    final menuSize = Size(
      width,
      2 * padV + (hasHide ? 5 : 4) * itemH + dividerH,
    );
    final tap = me.localToGlobal(at ?? anchor, ancestor: overlay);
    final topLeft = bounds.width > 0 && bounds.height > 0
        ? placeTapMenu(tap, menuSize, bounds)
        : tap;
    // The header wears the event's lane colour (a solid fill, as on the
    // chart), flush with the menu's rounded top; the name in the lane's
    // near-white text and the green / red amount on the lane's dark pill,
    // so it reads on every lane colour exactly as the lane's own label.
    final laneFill = lane == null ? AppTheme.raised : lane.color;
    final headerH = itemH + padV;
    final header = PopupMenuItem<int>(
      key: const ValueKey('dot-menu-header'),
      enabled: false,
      height: headerH,
      padding: EdgeInsets.zero,
      mouseCursor: SystemMouseCursors.basic,
      child: Container(
        key: const ValueKey('dot-menu-header-bg'),
        width: double.infinity,
        height: headerH,
        padding: const EdgeInsets.fromLTRB(12, padV, 8, 0),
        decoration: BoxDecoration(
          color: laneFill,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(dotMenuRadius - 1),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                key: const ValueKey('dot-menu-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: laneTextColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(color: Color(0x8C000000), blurRadius: 2)],
                ),
              ),
            ),
            const SizedBox(width: 10),
            DecoratedBox(
              key: const ValueKey('dot-menu-amount-pill'),
              decoration: BoxDecoration(
                color: laneAmountPillColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  formatSignedAmount(amount),
                  key: const ValueKey('dot-menu-amount'),
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: amount < 0
                        ? AppTheme.debitColor
                        : AppTheme.creditColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    PopupMenuItem<int> item(
      String key,
      IconData icon,
      String label,
      int v,
      VoidCallback? run,
    ) => PopupMenuItem<int>(
      key: ValueKey(key),
      value: v,
      enabled: run != null,
      height: itemH,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 18,
            color: run != null ? AppTheme.accent : AppTheme.textMuted,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
    _rowMenuOpen = true;
    final actions = [newHere, trim, edit, hide];
    final picked = await showMenu<int>(
      context: context,
      // At the tap, placed (flipped / shifted) inside the view; a fixed
      // width so the placement knows the menu's exact size.
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        topLeft.dy,
        overlay.size.width - topLeft.dx - width,
        overlay.size.height - topLeft.dy,
      ),
      constraints: BoxConstraints.tightFor(width: width),
      color: AppTheme.overlay,
      // No top padding: the lane-coloured header sits flush with the
      // menu's rounded top (its own height adds the padding back).
      menuPadding: const EdgeInsets.only(bottom: padV),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(dotMenuRadius),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      // No staggered fade-in: Safari can leave the canvas on a mid-fade
      // frame (a dimmed last row) until the next input.
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        header,
        const PopupMenuDivider(height: dividerH),
        item(
          'dot-menu-new',
          Icons.add_rounded,
          'New Event From Here',
          0,
          newHere,
        ),
        item(
          'dot-menu-trim',
          Icons.content_cut_rounded,
          'Trim From Here',
          1,
          trim,
        ),
        item(
          'dot-menu-edit',
          Icons.edit_outlined,
          once ? 'Edit Event' : 'Edit Series',
          2,
          edit,
        ),
        if (hasHide)
          item(
            'dot-menu-hide',
            hideActionIcon,
            once ? 'Hide Event' : 'Hide Series',
            3,
            hide,
          ),
      ],
    );
    if (!mounted) return;
    _rowMenuOpen = false;
    if (picked == null) {
      // Dismissed: the dot stays revealed (touch) / follows the mouse.
      if (!_touchDown) _armTapTipTimer();
      return;
    }
    _hideTip();
    actions[picked]?.call();
  }

  /// A row's ⋮ menu entries, in order: New (an event on that day), Trim
  /// series here (own recurring series, when trimmable), Edit (own) or
  /// "Edit in stream" (another stream's row I can edit). Empty: no ⋮.
  List<_RowAction> _rowActions(Occurrence? o, {DateTime? onDay}) {
    // A lane's dot at a step it does not occur on: [o] is its previous
    // occurrence (Trim ends the series there), [onDay] the step itself.
    final trimDay = _rowDay(o);
    final day = onDay ?? trimDay;
    final id = o?.eventId ?? 'seed';
    final actions = <_RowAction>[];
    if (widget.onNewOnDay != null) {
      actions.add(
        _RowAction(
          'tip-menu-new-$id',
          Icons.add_rounded,
          'New',
          () => widget.onNewOnDay?.call(day),
        ),
      );
    }
    if (o == null) return actions;
    final own = widget.events[o.eventId];
    if (own != null) {
      if (widget.onTrimOccurrence != null &&
          trimFromHere(own, trimDay) != null) {
        actions.add(
          _RowAction(
            'tip-menu-trim-${own.id}',
            Icons.content_cut_rounded,
            'Trim From Here',
            () => widget.onTrimOccurrence?.call(own, trimDay),
          ),
        );
      }
      if (widget.onEditEvent != null) {
        actions.add(
          _RowAction(
            'tip-menu-edit-${own.id}',
            Icons.edit_outlined,
            'Edit',
            () => widget.onEditEvent?.call(own, day),
          ),
        );
      }
      return actions;
    }
    final stream = widget.combinedStreams[o.streamId];
    final other = widget.otherEvents[o.eventId];
    if (stream != null &&
        other != null &&
        stream.canEdit &&
        widget.onOpenOtherEvent != null) {
      actions.add(
        _RowAction(
          'tip-menu-open-other-${other.id}',
          Icons.open_in_new_rounded,
          'Edit in ${stream.name}',
          () => widget.onOpenOtherEvent?.call(stream, other, day),
        ),
      );
    }
    return actions;
  }

  /// Width of the ⋮ button: a 44px touch target, a compact one for mice.
  double get _menuButtonWidth => _touchUi ? 44 : 28;

  /// The row's ⋮: opens its menu; only a picked item acts.
  Widget _rowMenuButton(String id, String name, List<_RowAction> actions) {
    return Builder(
      builder: (context) => SizedBox(
        width: _menuButtonWidth,
        height: _touchUi ? 44 : 28,
        child: InkResponse(
          key: ValueKey('tip-menu-$id'),
          radius: 18,
          containedInkWell: false,
          onTap: () => _openRowMenu(context, actions),
          child: Semantics(
            button: true,
            label: 'Actions for $name',
            child: const Center(
              child: Icon(
                Icons.more_vert_rounded,
                size: 18,
                color: AppTheme.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openRowMenu(
    BuildContext context,
    List<_RowAction> actions,
  ) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final r = Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    // Keep the popup up while its menu is open (mouse leaving for the
    // menu, the tap-tip timeout).
    _rowMenuOpen = true;
    _tapTipTimer?.cancel();
    final picked = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(r, Offset.zero & overlay.size),
      color: AppTheme.overlay,
      items: [
        for (final (i, a) in actions.indexed)
          PopupMenuItem<int>(
            key: ValueKey(a.key),
            value: i,
            height: _touchUi ? 44 : 36,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(a.icon, size: 18, color: AppTheme.accent),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    a.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (!mounted) return;
    _rowMenuOpen = false;
    if (picked == null) {
      // Dismissed: the popup stays; a mouse-pinned one times out as usual.
      if (_tapTip && !_touchDown) _armTapTipTimer();
      return;
    }
    _hideTip();
    actions[picked].run();
  }

  double _textWidth(String text, TextStyle? style) {
    final p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final w = p.width;
    p.dispose();
    return w;
  }

  /// "Fri 1 Jan" (with a ’yy year when it is not [ref]'s), or [none].
  String _shortDay(DateTime? d, DateTime ref, {String none = '–'}) => d == null
      ? none
      : d.year == ref.year
      ? DateFormat('EEE d MMM').format(d)
      : DateFormat("EEE d MMM ’yy").format(d);

  /// An event's occurrences just before and just after [day] in the
  /// series (null: none), for the popup of a lane dot on a step it skips.
  (Occurrence?, Occurrence?) _idleNeighbours(String txId, DateTime day) {
    Occurrence? prev, next;
    for (final o in widget.series.occurrences) {
      if (o.eventId != txId) continue;
      final d = dateOnly(o.date);
      if (d.isBefore(day)) {
        if (prev == null || d.isAfter(dateOnly(prev.date))) prev = o;
      } else if (d.isAfter(day)) {
        if (next == null || d.isBefore(dateOnly(next.date))) next = o;
      }
    }
    return (prev, next);
  }

  Widget _tooltip(ThemeData theme, _DotTip tip) {
    final maxWidth = math.min(280.0, _size.width - 8);
    // One row per event on the vertex's day (seed: one row).
    final entries = <(_Dot, Occurrence?)>[
      for (final d in tip.dots)
        if (d.isSeed || d.idle)
          (d, null)
        else
          for (final o in d.occurrences) (d, o),
    ];
    const maxRows = 12;
    final shown = entries.take(maxRows).toList();
    final more = entries.length - shown.length;
    final small = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      height: 1.2,
    );
    final meta = small.copyWith(color: AppTheme.textMuted, fontSize: 11);
    final nameStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.2,
    );
    final amountStyle = nameStyle?.copyWith(fontWeight: FontWeight.w800);
    // Same-day rows (the usual case) share one date header; dots of
    // different days merged at a far zoom date each row instead.
    final days = {
      for (final (d, o) in shown) d.idle ? dateOnly(d.day!) : _rowDay(o),
    };
    final oneDay = days.length == 1;
    final rowMin = _touchUi ? 44.0 : 28.0;
    final rows = <Widget>[];
    var rowsHeight = 0.0;
    var contentWidth = 0.0;
    var anyActions = false;
    final seen = <String, int>{};
    for (final (dot, o) in shown) {
      final idle = dot.idle;
      final (idlePrev, idleNext) = idle
          ? _idleNeighbours(dot.txId!, dot.day!)
          : (null, null);
      final actions = idle
          ? _rowActions(idlePrev, onDay: dot.day)
          : _rowActions(o);
      // Unique per row: one series can show twice in a merged far-zoom dot.
      final baseId = o?.eventId ?? (idle ? dot.txId! : 'seed');
      final n = seen[baseId] = (seen[baseId] ?? 0) + 1;
      final rowId = n == 1 ? baseId : '$baseId@$n';
      anyActions |= actions.isNotEmpty;
      final t = idle
          ? _txOf(dot.txId!)
          : o == null
          ? null
          : _txOf(o.eventId);
      final streamOf = idle ? idlePrev?.streamId : o?.streamId;
      final otherStream = streamOf == null
          ? null
          : widget.combinedStreams[streamOf];
      final String name;
      final String amountText;
      final Color amountColor;
      final skipped = o?.skipped ?? false;
      if (idle) {
        final raw = widget.eventNames[dot.txId] ?? t?.name;
        name = raw == null || raw.trim().isEmpty ? 'Event' : raw.trim();
        final amount = (t?.signedAmount ?? idlePrev?.signedDelta)?.toDouble();
        amountText = amount == null ? '' : formatSignedAmount(amount);
        amountColor = amount == null || amount < 0
            ? AppTheme.debitColor
            : AppTheme.creditColor;
      } else if (o == null) {
        name = 'Opening balance';
        amountText = formatMoneyAmount(dot.balanceAfter);
        amountColor = AppTheme.accent;
      } else {
        final raw = widget.eventNames[o.eventId] ?? t?.name;
        name = raw == null || raw.trim().isEmpty ? 'Event' : raw.trim();
        final amount = o.signedDelta.toDouble();
        amountText = formatSignedAmount(amount);
        amountColor = skipped
            ? AppTheme.textFaint
            : (amount < 0 ? AppTheme.debitColor : AppTheme.creditColor);
      }
      // Secondary line only when it says something: the other stream,
      // a repeat (not "One-off"), a status, or the date of a mixed popup.
      final metaSpans = <TextSpan>[
        if (!oneDay)
          TextSpan(
            text: formatSelectedDate(idle ? dateOnly(dot.day!) : _rowDay(o)),
          ),
        if (otherStream != null)
          TextSpan(
            text: otherStream.canEdit
                ? otherStream.name
                : '${otherStream.name} · view only',
            style: TextStyle(
              color: otherStream.color,
              fontWeight: FontWeight.w700,
            ),
          ),
        if (idle)
          TextSpan(
            text:
                'Ring dot: not occurring on this day\n'
                'Prev ${_shortDay(idlePrev?.date, dot.day!)}'
                ' · Next ${_shortDay(idleNext?.date, dot.day!, none: 'none ahead')}',
          ),
        if (!idle &&
            o != null &&
            t != null &&
            t.recurrenceMode != RecurrenceMode.once)
          TextSpan(
            text: [
              describeRecurrence(t),
              ?occurrenceOrdinal(t, o.date),
            ].join(' · '),
          ),
        if (o != null)
          for (final s in [
            if (o.netted) 'Transfer between combined streams: nets out',
            if (o.skipped) 'Skipped',
            if (t != null && !t.enabled) 'Disabled',
            if (t != null && t.overrideOn(o.date) != null)
              'Once-off (series ${formatSignedAmount(t.signedAmount.toDouble())})',
          ])
            TextSpan(
              text: s,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppTheme.warning,
              ),
            ),
      ];
      final metaParts = <InlineSpan>[];
      for (final (i, s) in metaSpans.indexed) {
        if (i > 0) metaParts.add(const TextSpan(text: ' · '));
        metaParts.add(s);
      }
      final menuW = actions.isEmpty ? 0.0 : _menuButtonWidth;
      final dotW = otherStream == null ? 0.0 : 14.0;
      contentWidth = math.max(
        contentWidth,
        dotW +
            _textWidth(name, nameStyle) +
            12 +
            _textWidth(amountText, amountStyle) +
            menuW,
      );
      if (metaParts.isNotEmpty) {
        for (final line in TextSpan(
          children: metaParts,
        ).toPlainText().split('\n')) {
          contentWidth = math.max(contentWidth, _textWidth(line, meta) + menuW);
        }
      }
      final lineH = metaParts.isEmpty
          ? 18.0
          : idle
          ? 46.0
          : 32.0;
      rowsHeight += math.max(rowMin, lineH + 6);
      rows.add(
        ConstrainedBox(
          key: ValueKey(o == null && !idle ? 'seed-tooltip' : 'tip-row-$rowId'),
          constraints: BoxConstraints(minHeight: rowMin),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Name (ellipsis) · amount, then the row's ⋮.
                      Row(
                        children: [
                          if (otherStream != null)
                            Padding(
                              key: ValueKey('tip-stream-${otherStream.id}'),
                              padding: const EdgeInsets.only(right: 6),
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: otherStream.color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: nameStyle,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            amountText,
                            style: amountStyle?.copyWith(
                              color: amountColor,
                              decoration: skipped
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ],
                      ),
                      if (metaParts.isNotEmpty)
                        Text.rich(
                          TextSpan(children: metaParts),
                          key: oneDay ? null : const ValueKey('tip-date'),
                          style: meta,
                          maxLines: idle ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ),
              if (actions.isNotEmpty) _rowMenuButton(rowId, name, actions),
            ],
          ),
        ),
      );
    }
    if (more > 0) {
      rowsHeight += 18;
      rows.add(Text('+$more more on this day', style: meta));
    }
    final children = <Widget>[];
    var extra = 0.0;
    if (oneDay) {
      final header = formatSelectedDate(days.single);
      final headerStyle = meta.copyWith(fontWeight: FontWeight.w700);
      contentWidth = math.max(contentWidth, _textWidth(header, headerStyle));
      extra += 18;
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            header,
            key: const ValueKey('tip-date'),
            style: headerStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    // Many rows scroll inside the card instead of running off the chart.
    final maxRowsHeight = math.max(
      2 * rowMin,
      math.min(_touchUi ? 300.0 : 260.0, _size.height * 0.5),
    );
    final scrolls = rowsHeight > maxRowsHeight + 1;
    final rowsColumn = Column(
      key: const ValueKey('tip-rows'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
    children.add(
      scrolls
          ? ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxRowsHeight),
              child: Scrollbar(
                thumbVisibility: true,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(right: 8),
                  child: rowsColumn,
                ),
              ),
            )
          : rowsColumn,
    );
    // One footer line: the day's net (2+ counted) and the end-of-day
    // balance.
    final day = tip.dots.firstWhere(
      (d) => !d.isSeed,
      orElse: () => tip.dots.first,
    );
    if (!day.isSeed) {
      final g = DayGroup(
        dateOnly(day.day ?? day.occurrences.first.date),
        day.occurrences,
      );
      final low = belowAlert(day.balanceAfter, widget.lossThreshold);
      final netLabel = 'Net · ${g.count}';
      final netText = formatSignedAmount(g.net);
      final balLabel = 'End of day ';
      final balText = formatMoneyAmount(day.balanceAfter);
      final footBold = small.copyWith(fontWeight: FontWeight.w800);
      contentWidth = math.max(
        contentWidth,
        (day.occurrences.length >= 2
                ? _textWidth('$netLabel ', small) +
                      _textWidth(netText, footBold) +
                      12
                : 0) +
            _textWidth(balLabel, small) +
            _textWidth(balText, footBold),
      );
      extra += 25;
      children.add(const Divider(height: 7, color: AppTheme.border));
      children.add(
        Row(
          children: [
            if (day.occurrences.length >= 2) ...[
              Row(
                key: const ValueKey('day-net'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$netLabel ',
                    style: small.copyWith(color: AppTheme.textFaint),
                  ),
                  Text(
                    netText,
                    style: footBold.copyWith(
                      color: g.allSkipped
                          ? AppTheme.textFaint
                          : (g.net < 0
                                ? AppTheme.debitColor
                                : AppTheme.creditColor),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
            ],
            // Balance after the day's events: bold, green at or
            // above the alert threshold (0 when none), red below it.
            // Takes all the room left (a Spacer would halve it).
            Expanded(
              child: Text.rich(
                textAlign: TextAlign.end,
                key: const ValueKey('tip-balance'),
                TextSpan(
                  text: balLabel,
                  style: small.copyWith(color: AppTheme.textFaint),
                  children: [
                    TextSpan(
                      text: balText,
                      style: footBold.copyWith(
                        color: low ? AppTheme.debitColor : AppTheme.creditColor,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    // The card hugs its content, up to [maxWidth].
    final width = (contentWidth + 20 + (scrolls ? 10 : 0) + 2)
        .clamp(math.min(150.0, maxWidth), maxWidth)
        .toDouble();
    final estHeight = 14.0 + math.min(rowsHeight, maxRowsHeight) + extra;
    // Right of the dot, flipping left / up near the edges. A lane dot's
    // card opens on its left: the pointer is on the lane to the dot's right
    // (anywhere along its step), so the card never covers the lanes being
    // hovered.
    final laneTip = tip.dots.length == 1 && tip.dots.first.txId != null;
    var left = laneTip ? tip.anchor.dx - 14 - width : tip.anchor.dx + 14;
    if (laneTip && left < 4) {
      left = tip.anchor.dx + 14;
    } else if (!laneTip && left + width > _size.width - 4) {
      left = tip.anchor.dx - 14 - width;
    }
    left = _clampEdge(left, 4, _size.width - width - 4);
    var top = tip.anchor.dy - 20;
    if (left < tip.anchor.dx || laneTip) {
      // Flipped left of the dot (or a lane dot's): keep the card off the dot's row so the
      // y-axis guide line and balance pill stay readable.
      final above = tip.anchor.dy - 18 - estHeight;
      top = above >= 4 ? above : tip.anchor.dy + 18;
    }
    if (top + estHeight > _size.height - 4) top = _size.height - estHeight - 4;
    top = _clampEdge(top, 4, _size.height - 40);
    final finger = tip.finger;
    if (finger != null) {
      final o = touchTooltipOrigin(
        finger: finger,
        size: Size(width, estHeight),
        bounds: _size,
        lift: 48,
      );
      left = o.dx;
      top = o.dy;
    }
    final ringAt = _tipRing(tip);
    debugTipRing?.call(ringAt?.center, ringAt?.radius);
    // With actions (or rows to scroll) the card takes taps, so they are
    // reachable on touch and a tap on the card never falls through to the
    // chart; otherwise the whole popup stays pointer-transparent.
    final tappable = anyActions || scrolls;
    return Positioned.fill(
      child: Stack(
        children: [
          // Highlight ring on the hovered dot (centred on the drawn dot).
          if (ringAt != null)
            Positioned(
              left: ringAt.center.dx - ringAt.radius - 5,
              top: ringAt.center.dy - ringAt.radius - 5,
              width: (ringAt.radius + 5) * 2,
              height: (ringAt.radius + 5) * 2,
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('dot-tip-ring'),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.accent.withValues(alpha: 0.18),
                    border: Border.all(color: AppTheme.accent, width: 1.5),
                  ),
                ),
              ),
            ),
          Positioned(
            left: left,
            top: top,
            width: width,
            child: IgnorePointer(
              ignoring: !tappable,
              child: Listener(
                onPointerSignal: _onPointerSignal,
                child: KeyedSubtree(
                  key: _tipCardKey,
                  child: _tooltipCard(theme, children),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tooltipCard(ThemeData theme, List<Widget> children) {
    return Material(
      key: const ValueKey('occurrence-tooltip'),
      elevation: 10,
      color: AppTheme.overlay,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.borderStrong),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [...children],
        ),
      ),
    );
  }

  Widget _addButton(ThemeData theme, DateTime day) {
    final rect = _dayButtonRect(_layout, day);
    if (rect == null) return const SizedBox.shrink();
    final label = 'New event on ${formatDate(day)}';
    // Purely visual: clicks, drags and wheel events fall through to the
    // chart's Listener, which treats a click inside this rect as "create".
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: _addButtonSize,
      height: _addButtonSize,
      child: IgnorePointer(
        child: Semantics(
          button: true,
          label: label,
          child: Material(
            elevation: 4,
            color: theme.colorScheme.primary,
            shape: const CircleBorder(),
            child: const Center(
              child: Icon(Icons.add, color: AppTheme.onAccent, size: 18),
            ),
          ),
        ),
      ),
    );
  }

  double _clampEdge(double value, double min, double max) {
    if (max < min) return min;
    return value.clamp(min, max).toDouble();
  }
}

/// A stacked lane's thickness in [layout] (phones get slimmer lanes).
double _laneHeight(LaneSet lanes, ChartLayout layout) => laneThickness(
  maxActive: lanes.maxActive,
  plotHeight: layout.plot.height,
  phone: layout.size.width < 600,
);

/// Test hook: called for every stacked-lane dot's place in view (shown or
/// not), with its event (null: no lane) and centre in chart coordinates.
@visibleForTesting
/// Test hook: the tooltip's highlight ring (chart-local centre and the
/// ringed dot's radius), or nulls when the tip has no ring (a lane tip).
void Function(Offset? center, double? radius)? debugTipRing;

void Function(String? txId, Offset center)? debugLaneDot;

/// Tests: the balance fill as split at the alert line, each paint.
void Function(AlertFill fill, double alertY)? debugAlertFill;

/// Test hook: called for every lane dot actually painted (only lane-less
/// occurrences, on the line itself: event lanes draw no dots); [idle] is a
/// ring.
@visibleForTesting
void Function(String? txId, Offset center, bool idle)? debugLaneDotPainted;

/// Test hook: called for every balance step dot painted, with its step,
/// centre and radius (the hovered / tapped one with active true).
@visibleForTesting
void Function(BalanceStep step, Offset center, double radius, bool active)?
debugStepDotPainted;

/// Test hook: a lane's dot place at a step its event does not occur on
/// (shown or not).
@visibleForTesting
void Function(String? txId, Offset center)? debugLaneIdleDot;

/// Test hook: called for every stretch of ribbon painted, with its day,
/// the ribbon's rect in chart coordinates and the balance's own y.
@visibleForTesting
void Function(DateTime day, Rect ribbon, double balanceY)? debugRibbon;

/// Test hook: the riser joining the opening diamond to the seed day's
/// ribbon, in chart coordinates.
@visibleForTesting
void Function(Rect riser)? debugRiser;

/// Test hook: called for every piece of the true-balance line drawn through
/// a stack of two or more lanes (a level, or its step at a day edge).
@visibleForTesting
void Function(Rect piece)? debugTrueLine;

class ChartLayout {
  const ChartLayout({
    required this.size,
    required this.plot,
    required this.yearBand,
    required this.monthBand,
    required this.weekBand,
    required this.dayBand,
    required this.showWeekLane,
    required this.showDayLane,
    required this.showDayLabels,
    required this.showDayText,
  });

  final Rect plot;

  /// Footer rows, top to bottom: year, month, week, day. All four always
  /// show; segments too narrow for a label stay blank.
  final Rect yearBand;
  final Rect monthBand;
  final Rect? weekBand;
  final Rect? dayBand;
  final bool showWeekLane;
  final bool showDayLane;
  final bool showDayLabels;

  /// Whether the day lane carries text (see [dayLabelPlan]).
  final bool showDayText;

  /// The plot spans the full width: y labels and lane names float over it
  /// instead of sitting in a reserved gutter.
  static const double gutter = 0;
  static const double right = 0;

  static const double top = 8;

  /// The chart's full size (the plot spans its width).
  final Size size;

  /// Width of the lane-name chips (Year / Month / Week / Day) floating over
  /// the plot's left edge; the y labels float over the same strip.
  static double laneNameWidth(double chartWidth) => chartWidth < 600 ? 38 : 44;

  static ChartLayout of(Size size, double visibleDays) {
    final plotWidth = math.max(1.0, size.width - gutter - right);
    final dayPx = plotWidth / math.max(visibleDays, 0.001);
    final showDayLabels = dayPx >= 12;
    // Day text (thinned when narrow) shows from 6px/day.
    final showDayText = dayPx >= 6;
    final showDayLane = dayPx >= 3;
    final showWeekLane = dayPx * 7 >= 14;
    final phone = size.width < 600;
    final yearH = phone ? 17.0 : 18.0;
    final monthH = phone ? 19.0 : 20.0;
    final weekH = phone ? 17.0 : 18.0;
    final dayH = showDayText ? dayLaneLabelHeight : 14.0;
    final axisH = yearH + monthH + weekH + dayH;
    final plot = Rect.fromLTWH(
      gutter,
      top,
      plotWidth,
      math.max(1, size.height - top - axisH),
    );
    var y = plot.bottom;
    final yearBand = Rect.fromLTWH(plot.left, y, plot.width, yearH);
    y += yearH;
    final monthBand = Rect.fromLTWH(plot.left, y, plot.width, monthH);
    y += monthH;
    final weekBand = Rect.fromLTWH(plot.left, y, plot.width, weekH);
    y += weekH;
    final dayBand = Rect.fromLTWH(plot.left, y, plot.width, dayH);
    return ChartLayout(
      size: size,
      plot: plot,
      yearBand: yearBand,
      monthBand: monthBand,
      weekBand: weekBand,
      dayBand: dayBand,
      showWeekLane: showWeekLane,
      showDayLane: showDayLane,
      showDayLabels: showDayLabels,
      showDayText: showDayText,
    );
  }

  double xOf(DateTime date, DateTime viewStart, double visibleDays) {
    final days = dayCoord(date) - dayCoord(viewStart);
    return plot.left + days / visibleDays * plot.width;
  }

  /// The date axis (all lanes) under the plot, where a press picks a date.
  Rect get axis => Rect.fromLTRB(
    plot.left,
    plot.bottom,
    plot.right,
    (dayBand ?? weekBand ?? monthBand).bottom,
  );

  DateTime dateAt(double localDx, DateTime viewStart, double visibleDays) {
    final fraction = ((localDx - plot.left) / plot.width).clamp(0.0, 1.0);
    return dateOnly(addDays(viewStart, fraction * visibleDays));
  }
}

// Muted, dark-tuned hues for month lanes (white text stays readable).
const _monthColors = <Color>[
  Color(0xFF24476B),
  Color(0xFF1D5A55),
  Color(0xFF2C5A3E),
  Color(0xFF6A4B26),
  Color(0xFF6E3532),
  Color(0xFF5E3253),
  Color(0xFF34477A),
  Color(0xFF1F5866),
  Color(0xFF4C5626),
  Color(0xFF7A5020),
  Color(0xFF543A30),
  Color(0xFF36435A),
];

/// Alternating week lane fills.
const _weekColors = <Color>[
  Color(0xFF1A222D),
  Color(0xFF151C25),
  Color(0xFF1A222D),
  Color(0xFF151C25),
];

/// Day columns: weekdays sit on the plot colour, weekends a touch lighter.
const _dayColors = <Color>[
  Color(0xFF131921),
  Color(0xFF131921),
  Color(0xFF131921),
  Color(0xFF131921),
  Color(0xFF131921),
  Color(0xFF19212B),
  Color(0xFF19212B),
];

const _plotBg = Color(0xFF131921);
const _laneText = Color(0xFFC6CEDA);
const _lineColor = AppTheme.accent;

/// The active dot's crosshair (guides to both axes and their pills): a
/// clear cyan, distinct from the mint today line and the balance line.
@visibleForTesting
const Color guideColor = Color(0xFF22D3EE);
const _gridColor = Color(0xFF243040);

Color _yearColor(int index) =>
    index.isEven ? const Color(0xFF24476B) : const Color(0xFF1D5A55);

Color _monthColor(int month) => _monthColors[(month - 1).clamp(0, 11)];

Color _weekColor(int index) => _weekColors[index.clamp(0, 3)];

Color _dayColor(int weekday) => _dayColors[(weekday - 1).clamp(0, 6)];

class _BalanceChartPainter extends CustomPainter {
  _BalanceChartPainter({
    required this.labelMemory,
    required this.labelHits,
    required this.series,
    required this.seedDate,
    DateTime? lineStart,
    this.streamColors = const {},
    this.seedBalance,
    required this.lossThreshold,
    required this.viewStart,
    required this.visibleDays,
    required this.labelStyle,
    required this.strongStyle,
    required this.laneStyle,
    required this.eventNames,
    this.eventOrder = const [],
    required this.lanes,
    required this.textScaler,
    this.dataFrom,
    this.dataThrough,
    this.yRange,
    this.highlightY,
    this.stepDots = const [],
    this.activeStep,
  }) : lineStart = dateOnly(lineStart ?? seedDate);

  /// Balance range shown top to bottom. Null falls back to fitting the view.
  final BalanceExtents? yRange;

  /// Y of the active dot's highlighted balance; regular axis labels that
  /// would collide with its pill are skipped.
  final double? highlightY;

  /// The balance line's step dots in view (stacked lanes only), as
  /// [visibleStepDots] placed and thinned them.
  final List<StepDot> stepDots;

  /// The day of the hovered / tapped step dot (drawn larger, white ring).
  final DateTime? activeStep;
  final DateTime? dataFrom;
  final DateTime? dataThrough;
  final BalanceSeries series;
  final DateTime seedDate;

  /// Where the line starts (the earliest combined seed; else [seedDate]).
  final DateTime lineStart;

  /// Combined view: tint per other stream id (their dots get a ring).
  final Map<String, Color> streamColors;

  /// Opening balance on [seedDate]; drawn as the initial vertex. Null: none.
  final double? seedBalance;
  final double lossThreshold;
  final DateTime viewStart;
  final double visibleDays;
  final TextStyle labelStyle;

  /// Vertices labelled on the previous paint. They are placed first so a
  /// shown label keeps its spot while the view moves (hysteresis), instead
  /// of a dot entering at the edge reshuffling the greedy placement.
  final Map<int, _LabelSpot> labelMemory;

  /// Output: the labels painted this frame, for hit-testing taps on them.
  final List<_LabelHit> labelHits;
  final TextStyle strongStyle;
  final TextStyle laneStyle;
  final Map<String, String> eventNames;

  /// Event ids in the order they were added (labels list a day's
  /// names in this order). Ids not in it follow, by [eventNames].
  final List<String> eventOrder;

  /// The stacked lanes the balance line is drawn as (none: a plain line).
  final LaneSet lanes;
  final TextScaler textScaler;

  DateTime get _viewEnd => addDays(viewStart, visibleDays);

  @override
  void paint(Canvas canvas, Size size) {
    final layout = ChartLayout.of(size, visibleDays);
    final seed = lineStart;
    final viewEnd = _viewEnd;
    final visible = visibleBalance(
      points: series.points,
      viewStart: viewStart,
      viewEnd: viewEnd,
      seedDate: seed,
    );

    _paintPlotBands(canvas, layout, viewEnd);
    _paintAxes(canvas, layout, viewEnd);

    if (visible == null) {
      _paintCentered(
        canvas,
        layout.plot,
        viewEnd.isBefore(seed)
            ? 'Before seed date'
            : 'No balance in this range',
        labelStyle,
      );
      return;
    }

    final range =
        yRange ?? paddedRange(visible.extents.min, visible.extents.max);
    final scale = _YScale(range.min, range.max, layout.plot);
    // Axis label precision follows the whole loaded series (from the
    // seed), not just what is in view, so labels don't reformat on pan.
    final global = balanceExtentsFrom(series.points, seed) ?? visible.extents;
    final gridLabels = _paintGrid(canvas, layout, scale, global);
    _paintMarkers(canvas, layout, viewEnd, dateOnly(seedDate));
    _paintSeries(canvas, layout, scale, visible, seed, viewEnd);
    _paintOccurrences(canvas, layout, scale, viewEnd, seed);
    if (!lanes.isEmpty) _paintStepDots(canvas, layout, scale);
    // Axis values float over the plot: drawn after the line and dots.
    for (final (y, text) in gridLabels) {
      _paintYText(canvas, layout, y, text, labelStyle);
    }
    _paintOffscreenHints(canvas, layout, scale, visible.extents);
  }

  void _paintPlotBands(Canvas canvas, ChartLayout layout, DateTime viewEnd) {
    canvas.save();
    canvas.clipRect(layout.plot);
    final years = useYearLane(layout.plot.width, visibleDays);
    final segments = layout.showDayLabels
        ? daySegments(viewStart, viewEnd)
        : layout.showWeekLane
        ? weekSegments(viewStart, viewEnd)
        : years
        ? yearSegments(viewStart, viewEnd)
        : monthSegments(viewStart, viewEnd);
    for (final segment in segments) {
      final color = switch (segment.lane) {
        AxisLane.year => Color.alphaBlend(
          _yearColor(segment.colorIndex).withValues(alpha: 0.10),
          _plotBg,
        ),
        AxisLane.day => _dayColor(segment.colorIndex),
        AxisLane.week =>
          segment.colorIndex.isEven ? _plotBg : const Color(0xFF161D26),
        AxisLane.month => Color.alphaBlend(
          _monthColor(segment.colorIndex).withValues(alpha: 0.10),
          _plotBg,
        ),
      };
      _fillSegment(
        canvas,
        layout,
        segment,
        layout.plot.top,
        layout.plot.bottom,
        color,
      );
    }
    _paintBoundaryLines(canvas, layout, viewEnd);
    canvas.restore();
  }

  void _paintBoundaryLines(
    Canvas canvas,
    ChartLayout layout,
    DateTime viewEnd,
  ) {
    // Faint day separators, under the week / month lines; hidden when
    // columns are narrower than 10px and faded in up to 16px.
    final dayPx = layout.plot.width / visibleDays;
    final dayStrength = dayLineOpacity(dayPx);
    if (dayStrength > 0) {
      final dayPaint = Paint()
        ..color = const Color(0xFF1F2833).withValues(alpha: dayStrength)
        ..strokeWidth = 1;
      for (final segment in daySegments(viewStart, viewEnd)) {
        final x = layout.xOf(segment.start, viewStart, visibleDays);
        if (x <= layout.plot.left + 0.5 || x >= layout.plot.right) continue;
        canvas.drawLine(
          Offset(x, layout.plot.top),
          Offset(x, layout.plot.bottom),
          dayPaint,
        );
      }
    }
    final monthPaint = Paint()
      ..color = const Color(0xFF3A4757)
      ..strokeWidth = 1;
    final boundaries = useYearLane(layout.plot.width, visibleDays)
        ? yearSegments(viewStart, viewEnd)
        : monthSegments(viewStart, viewEnd);
    for (final segment in boundaries) {
      final x = layout.xOf(segment.start, viewStart, visibleDays);
      if (x <= layout.plot.left + 0.5 || x >= layout.plot.right) continue;
      canvas.drawLine(
        Offset(x, layout.plot.top),
        Offset(x, layout.plot.bottom),
        monthPaint,
      );
    }
    if (!layout.showWeekLane) return;
    final weekPaint = Paint()
      ..color = const Color(0xFF222C38)
      ..strokeWidth = 1;
    for (final segment in weekSegments(viewStart, viewEnd)) {
      final x = layout.xOf(segment.start, viewStart, visibleDays);
      if (x <= layout.plot.left + 0.5 || x >= layout.plot.right) continue;
      if (segment.start.day == 1) continue;
      canvas.drawLine(
        Offset(x, layout.plot.top),
        Offset(x, layout.plot.bottom),
        weekPaint,
      );
    }
  }

  void _paintAxes(Canvas canvas, ChartLayout layout, DateTime viewEnd) {
    _paintLane(
      canvas,
      layout,
      layout.yearBand,
      yearSegments(viewStart, viewEnd),
      viewEnd,
      (segment, width) => yearLabel(segment.start.year, width),
      (segment) => _yearColor(segment.colorIndex),
      Colors.white,
      'Year',
    );
    _paintLane(
      canvas,
      layout,
      layout.monthBand,
      monthSegments(viewStart, viewEnd),
      viewEnd,
      (segment, width) => monthLabel(segment.start, width),
      (segment) => _monthColor(segment.colorIndex),
      Colors.white,
      'Month',
    );
    _paintRestOfAxes(canvas, layout, viewEnd);
  }

  void _paintRestOfAxes(Canvas canvas, ChartLayout layout, DateTime viewEnd) {
    final weekBand = layout.weekBand;
    if (weekBand != null) {
      _paintLane(
        canvas,
        layout,
        weekBand,
        layout.plot.width / visibleDays * 7 >= 2
            ? weekSegments(viewStart, viewEnd)
            : const [],
        viewEnd,
        (segment, width) => weekLabel(
          segment.start,
          // _paintCentered lays out in the deflated rect, less 2px.
          width - 4,
          measure: (t) => _laneTextWidth(t),
        ),
        (segment) => _weekColor(segment.colorIndex),
        _laneText,
        'Week',
      );
    }
    final dayBand = layout.dayBand;
    if (dayBand != null) {
      _paintLane(
        canvas,
        layout,
        dayBand,
        layout.plot.width / visibleDays >= 2
            ? daySegments(viewStart, viewEnd)
            : const [],
        viewEnd,
        (segment, width) => '',
        (segment) => _dayColor(segment.colorIndex),
        _laneText,
        'Day',
      );
      if (layout.showDayText) _paintDayLabels(canvas, layout, dayBand);
    }
  }

  /// Two centred lines per day: weekday (muted accent) over the numeral.
  /// Full "Wed / 23rd", compact "W / 23", or sparse numerals when narrow.
  void _paintDayLabels(Canvas canvas, ChartLayout layout, Rect band) {
    final numStyle = laneStyle.copyWith(
      color: _laneText,
      height: 1.1,
      fontWeight: FontWeight.w400,
    );
    final dowStyle = laneStyle.copyWith(
      color: AppTheme.accent.withValues(alpha: 0.75),
      fontSize: (laneStyle.fontSize ?? 11) - 1.5,
      height: 1.1,
      fontWeight: FontWeight.w700,
    );
    double w(String t, TextStyle st) =>
        _axisText.get(t, st, scaler: textScaler).width;

    final cell = layout.plot.width / visibleDays;
    final plan = dayLabelPlan(
      cellWidth: cell,
      fullWidth: math.max(w('Wed', dowStyle), w('28th', numStyle)),
      compactWidth: math.max(w('W', dowStyle), w('28', numStyle)),
      numeralWidth: w('28', numStyle),
    );
    final nameW = _laneNameWidth(layout);
    canvas.save();
    canvas.clipRect(band);
    for (final segment in daySegments(viewStart, _viewEnd)) {
      final day = segment.start;
      if (!dayLabelled(day, plan.every)) continue;
      final left = layout.xOf(day, viewStart, visibleDays);
      final cx = left + cell / 2;
      final full = plan.form == DayLabelForm.full;
      final weekday = switch (plan.form) {
        DayLabelForm.full => DateFormat.E().format(day),
        DayLabelForm.compact => DateFormat.E().format(day).substring(0, 1),
        DayLabelForm.sparse => null,
      };
      final numeral = full ? ordinalDay(day.day) : '${day.day}';
      final lines = [
        if (weekday != null) (weekday, dowStyle),
        (numeral, numStyle),
      ];
      // Cached across frames: never disposed here.
      final painters = [
        for (final (t, st) in lines)
          _axisText.get(t, st, scaler: textScaler, maxLines: 1),
      ];
      // Keep the text wholly inside the Day row: drop the weekday line when
      // both don't fit its height, and skip a label that would run under
      // the row-name chip or past the plot edge rather than clip it.
      if (painters.length > 1 &&
          painters.fold<double>(0, (a, p) => a + p.height) > band.height) {
        painters.removeAt(0);
      }
      final total = painters.fold<double>(0, (a, p) => a + p.height);
      final textW = painters.fold<double>(0, (a, p) => math.max(a, p.width));
      final fits =
          total <= band.height &&
          cx - textW / 2 >= band.left + nameW &&
          cx + textW / 2 <= band.right;
      var y = band.top + (band.height - total) / 2;
      for (final p in painters) {
        if (fits) {
          final at = Offset(cx - p.width / 2, y);
          p.paint(canvas, at);
          debugAxisLabel?.call('Day', p.plainText, at & p.size);
        }
        y += p.height;
      }
    }
    canvas.restore();
  }

  void _paintLane(
    Canvas canvas,
    ChartLayout layout,
    Rect band,
    List<AxisSegment> segments,
    DateTime viewEnd,
    String Function(AxisSegment segment, double width) labelFor,
    Color Function(AxisSegment segment) colorFor,
    Color textColor,
    String laneName,
  ) {
    canvas.drawRect(band, Paint()..color = const Color(0xFF10151C));
    canvas.save();
    canvas.clipRect(band);
    // Segments under 2px can't show a fill or separator; leave the row as a
    // plain band rather than smearing hundreds of slivers.
    final span = segments.isEmpty
        ? 0.0
        : layout.xOf(segments.first.end, viewStart, visibleDays) -
              layout.xOf(segments.first.start, viewStart, visibleDays);
    final nameW = _laneNameWidth(layout);
    if (span >= 2) {
      final style = laneStyle.copyWith(color: textColor, height: 1.05);
      for (final segment in segments) {
        final left = layout.xOf(segment.start, viewStart, visibleDays);
        final right = layout.xOf(segment.end, viewStart, visibleDays);
        if (right < band.left || left > band.right) continue;
        final rect = Rect.fromLTRB(
          math.max(left, band.left),
          band.top,
          math.min(right, band.right) - 1,
          band.bottom,
        );
        if (rect.width <= 0) continue;
        canvas.drawRect(rect, Paint()..color = colorFor(segment));
        // Label the part of the segment not covered by the row name.
        final open = Rect.fromLTRB(
          math.max(rect.left, band.left + nameW),
          rect.top,
          rect.right,
          rect.bottom,
        );
        if (open.width <= 0) continue;
        final label = labelFor(segment, open.width);
        if (label.isEmpty) continue;
        _paintCentered(canvas, open.deflate(1), label, style, row: laneName);
      }
    }
    // Row name, right-aligned in a small chip at the left edge.
    final namePainter = _axisText.get(
      laneName,
      laneStyle.copyWith(
        color: const Color(0xFF8592A3),
        fontSize: (laneStyle.fontSize ?? 11) - 2,
        fontWeight: FontWeight.w600,
        height: 1,
      ),
      scaler: textScaler,
      maxLines: 1,
    );
    canvas.drawRect(
      Rect.fromLTWH(band.left, band.top, nameW, band.height - 1),
      Paint()..color = const Color(0xE610151C),
    );
    namePainter.paint(
      canvas,
      Offset(
        band.left + nameW - 4 - namePainter.width,
        band.center.dy - namePainter.height / 2,
      ),
    );
    canvas.restore();
  }

  /// Width of [text] in the lane label style, as _paintCentered lays it out.
  double _laneTextWidth(String text) =>
      _axisText.get(text, laneStyle.copyWith(height: 1.05), maxLines: 1).width;

  double _laneNameWidth(ChartLayout layout) =>
      ChartLayout.laneNameWidth(layout.size.width);

  void _fillSegment(
    Canvas canvas,
    ChartLayout layout,
    AxisSegment segment,
    double top,
    double bottom,
    Color color,
  ) {
    final left = layout.xOf(segment.start, viewStart, visibleDays);
    final right = layout.xOf(segment.end, viewStart, visibleDays);
    if (right < layout.plot.left || left > layout.plot.right) return;
    canvas.drawRect(
      Rect.fromLTRB(
        math.max(left, layout.plot.left),
        top,
        math.min(right, layout.plot.right),
        bottom,
      ),
      Paint()..color = color,
    );
  }

  /// Draws gridlines; returns the axis value labels (y, text) to paint
  /// later, over the series.
  List<(double, String)> _paintGrid(
    Canvas canvas,
    ChartLayout layout,
    _YScale scale,
    BalanceExtents extents,
  ) {
    final labels = <(double, String)>[];
    final grid = Paint()
      ..color = _gridColor
      ..strokeWidth = 1;
    final digits = moneyDigitsForSpan(extents.min, extents.max);
    for (final value in niceGridlines(scale.yMin, scale.yMax)) {
      if (value.abs() < 1e-9) continue;
      final y = scale.yOf(value);
      canvas.drawLine(
        Offset(layout.plot.left, y),
        Offset(layout.plot.right, y),
        grid,
      );
      labels.add((y, _axisMoney(value, digits, _absMax(extents))));
    }

    if (scale.yMin < 0 && scale.yMax > 0) {
      final y = scale.yOf(0);
      debugZeroLine?.call(y, layout.plot);
      canvas.drawLine(
        Offset(layout.plot.left, y),
        Offset(layout.plot.right, y),
        Paint()
          ..color = const Color(0xFF4A5868)
          ..strokeWidth = 1,
      );
      labels.add((y, _axisMoney(0, digits, _absMax(extents))));
    }
    return labels;
  }

  void _paintYText(
    Canvas canvas,
    ChartLayout layout,
    double y,
    String text,
    TextStyle style,
  ) {
    final hy = highlightY;
    if (hy != null && (y - hy).abs() < 18) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(40, layout.plot.width * 0.45));
    final minTop = layout.plot.top + 1;
    final maxTop = math.max(minTop, layout.plot.bottom - painter.height - 1);
    final top = (y - painter.height / 2).clamp(minTop, maxTop).toDouble();
    // Overlay at the plot's left edge.
    final left = layout.plot.left + 6;
    final bg = RRect.fromRectAndRadius(
      Rect.fromLTWH(left - 3, top - 1, painter.width + 6, painter.height + 2),
      const Radius.circular(4),
    );
    canvas.drawRRect(bg, Paint()..color = _plotBg.withValues(alpha: 0.72));
    painter.paint(canvas, Offset(left, top));
    painter.dispose();
  }

  void _paintMarkers(
    Canvas canvas,
    ChartLayout layout,
    DateTime viewEnd,
    DateTime seed,
  ) {
    // Rule: both markers sit on their day's start edge (the same edge
    // the day's step uses). Today is the calendar date, not "now", so it
    // never drifts into tomorrow late in the day. On the same day today is
    // nudged [markerGap] px right so both lines show.
    final today = dateOnly(DateTime.now());
    final sameDay = today == seed;
    // Labels point away from each other: the earlier marker's label goes
    // left, the later one's right (seed left when they coincide).
    final todayFirst = today.isBefore(seed);
    _paintVertical(
      canvas,
      layout,
      today,
      viewEnd,
      color: AppTheme.mint.withValues(alpha: 0.9),
      label: 'Today',
      labelColor: AppTheme.mint,
      // Solid, unlike the dashed dot crosshair and seed marker.
      dashed: false,
      alignLeft: todayFirst,
      offset: sameDay ? markerGap : 0,
    );
    _paintVertical(
      canvas,
      layout,
      seed,
      viewEnd,
      color: AppTheme.violet.withValues(alpha: 0.7),
      label: 'Seed',
      labelColor: AppTheme.violet,
      dashed: true,
      alignLeft: !todayFirst,
    );
  }

  void _paintVertical(
    Canvas canvas,
    ChartLayout layout,
    DateTime date,
    DateTime viewEnd, {
    required Color color,
    required String label,
    required Color labelColor,
    bool dashed = false,
    bool alignLeft = false,
    double offset = 0,
  }) {
    final next = addCalendarDays(date, 1);
    if (!next.isAfter(viewStart) || dateOnly(date).isAfter(viewEnd)) return;
    final x = layout.xOf(date, viewStart, visibleDays) + offset;
    if (x < layout.plot.left || x > layout.plot.right) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4;
    if (!dashed) {
      canvas.drawLine(
        Offset(x, layout.plot.top),
        Offset(x, layout.plot.bottom),
        paint,
      );
    } else {
      var y = layout.plot.top;
      while (y < layout.plot.bottom) {
        final y2 = math.min(y + 4, layout.plot.bottom);
        canvas.drawLine(Offset(x, y), Offset(x, y2), paint);
        y += 7;
      }
    }
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: laneStyle.copyWith(color: labelColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = alignLeft ? x - painter.width - 4 : x + 4;
    painter.paint(
      canvas,
      Offset(
        dx.clamp(layout.plot.left, layout.plot.right - painter.width),
        layout.plot.top + 2,
      ),
    );
    painter.dispose();
  }

  void _paintSeries(
    Canvas canvas,
    ChartLayout layout,
    _YScale scale,
    VisibleBalance visible,
    DateTime seed,
    DateTime viewEnd,
  ) {
    var drawStart = viewStart.isBefore(seed) ? seed : viewStart;
    final from = dataFrom;
    if (from != null && drawStart.isBefore(from) && !from.isBefore(seed)) {
      drawStart = from;
    }
    var drawEnd = viewEnd;
    final through = dataThrough;
    if (through != null) {
      final coverEnd = addCalendarDays(through, 1);
      if (coverEnd.isBefore(drawEnd)) drawEnd = coverEnd;
    }
    if (!drawStart.isBefore(drawEnd)) return;

    BalancePoint? carry;
    final jumps = <BalancePoint>[];
    for (final sample in visible.samples) {
      if (!dateOnly(sample.date).isAfter(drawStart)) {
        carry = sample;
      } else {
        jumps.add(sample);
      }
    }
    if (carry == null && jumps.isEmpty) return;

    final startX = layout
        .xOf(drawStart, viewStart, visibleDays)
        .clamp(layout.plot.left, layout.plot.right)
        .toDouble();
    final endX = layout
        .xOf(drawEnd, viewStart, visibleDays)
        .clamp(layout.plot.left, layout.plot.right)
        .toDouble();

    final plateaus = <({double x0, double x1, double value})>[];
    final strokes = <({Offset from, Offset to, bool loss})>[];
    double? current = carry?.closingBalance.toDouble();
    var cursor = startX;
    for (final jump in jumps) {
      final jx = layout
          .xOf(_stepAt(jump.date), viewStart, visibleDays)
          .clamp(layout.plot.left, layout.plot.right)
          .toDouble();
      final next = jump.closingBalance.toDouble();
      if (current != null) {
        final y = scale.yOf(current);
        plateaus.add((x0: cursor, x1: jx, value: current));
        strokes.add((
          from: Offset(cursor, y),
          to: Offset(jx, y),
          loss: _isLoss(current),
        ));
        strokes.add((
          from: Offset(jx, y),
          to: Offset(jx, scale.yOf(next)),
          loss: _isLoss(next),
        ));
      }
      current = next;
      cursor = jx;
    }
    if (current == null) return;
    final endY = scale.yOf(current);
    plateaus.add((x0: cursor, x1: endX, value: current));
    strokes.add((
      from: Offset(cursor, endY),
      to: Offset(endX, endY),
      loss: _isLoss(current),
    ));

    canvas.save();
    canvas.clipRect(layout.plot);
    // Gradient area under the line: strong near the top of the plot,
    // fading out towards the bottom.
    Paint gradientFill(Color c) => Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [c.withValues(alpha: 0.30), c.withValues(alpha: 0.03)],
      ).createShader(layout.plot);
    final areaFill = gradientFill(_lineColor);
    final thresholdY = scale.yOf(lossThreshold);
    final split = alertFillOf(
      [
        for (final p in plateaus)
          (x0: p.x0, x1: p.x1, y: scale.yOf(p.value), low: _isLoss(p.value)),
      ],
      alertY: thresholdY,
      plot: layout.plot,
    );
    debugAlertFill?.call(split, thresholdY);
    for (final r in split.safe) {
      canvas.drawRect(r, areaFill);
    }
    if (split.deficit.isNotEmpty || split.under.isNotEmpty) {
      // Under the alert line, a low run is red: the band between the alert
      // and the balance line deepens over its first stretch (a shallow dip
      // reads lighter than a deep one), and its column under the line
      // fades out towards the bottom like the green fill does.
      final plot = layout.plot;
      final top = thresholdY.clamp(plot.top, plot.bottom).toDouble();
      final deep = math.max(24.0, (plot.bottom - top) * 0.35);
      final deficitFill = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppTheme.debitColor.withValues(alpha: 0.20),
            AppTheme.debitColor.withValues(alpha: 0.52),
          ],
        ).createShader(Rect.fromLTRB(plot.left, top, plot.right, top + deep));
      final underFill = Paint()
        ..shader =
            LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppTheme.debitColor.withValues(alpha: 0.30),
                AppTheme.debitColor.withValues(alpha: 0.04),
              ],
            ).createShader(
              Rect.fromLTRB(
                plot.left,
                top,
                plot.right,
                math.max(plot.bottom, top + 1),
              ),
            );
      for (final r in split.deficit) {
        canvas.drawRect(r, deficitFill);
      }
      for (final r in split.under) {
        canvas.drawRect(r, underFill);
      }
    }

    if (thresholdY >= layout.plot.top && thresholdY <= layout.plot.bottom) {
      canvas.drawLine(
        Offset(layout.plot.left, thresholdY),
        Offset(layout.plot.right, thresholdY),
        Paint()
          ..color = AppTheme.debitColor.withValues(alpha: 0.55)
          ..strokeWidth = 1,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: 'Alert < ${formatMoneyAmount(lossThreshold)}',
          style: TextStyle(
            color: AppTheme.debitColor.withValues(alpha: 0.9),
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final above = thresholdY - tp.height - 3 >= layout.plot.top;
      tp.paint(
        canvas,
        Offset(
          layout.plot.right - tp.width - 8,
          above ? thresholdY - tp.height - 3 : thresholdY + 3,
        ),
      );
    }

    if (!lanes.isEmpty) {
      _paintStack(canvas, layout, scale, visible.samples, drawStart, drawEnd);
      canvas.restore();
      return;
    }

    Path? stroke;
    bool? strokeLoss;
    void flushStroke() {
      final path = stroke;
      final loss = strokeLoss;
      if (path == null || loss == null) return;
      canvas.drawPath(
        path,
        Paint()
          ..color = loss ? AppTheme.debitColor : _lineColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.6
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    for (final segment in strokes) {
      if ((segment.to - segment.from).distance < 0.01) continue;
      if (stroke == null || strokeLoss != segment.loss) {
        flushStroke();
        stroke = Path()..moveTo(segment.from.dx, segment.from.dy);
        strokeLoss = segment.loss;
      }
      stroke.lineTo(segment.to.dx, segment.to.dy);
    }
    flushStroke();
    canvas.restore();
  }

  /// The ribbon [_paintStack] drew last (for the day totals to steer clear
  /// of).
  List<StackPlateau> _plateaus = const [];
  double _laneH = 0;

  /// The balance line as stacked lanes: a ribbon one lane per active
  /// event (list order, top first) hanging just under the balance line and
  /// stepping with it at each day's left edge; a thin line where no lane is active.
  /// Lane names are written inside their lanes.
  void _paintStack(
    Canvas canvas,
    ChartLayout layout,
    _YScale scale,
    List<BalancePoint> samples,
    DateTime drawStart,
    DateTime drawEnd,
  ) {
    final plot = layout.plot;
    final h = _laneHeight(lanes, layout);
    _laneH = h;
    final plateaus = [
      for (final p in stackPlateaus(
        lanes: lanes,
        samples: samples,
        drawStart: drawStart,
        drawEnd: drawEnd,
        xOf: (d) => layout.xOf(d, viewStart, visibleDays),
        minX: plot.left,
        maxX: plot.right,
      ))
        if (p.x1 - p.x0 > 0.01) p,
    ];
    _plateaus = plateaus;
    if (plateaus.isEmpty) return;

    final thin = Path(); // the plain line where no lane is active
    final loss = Path(); // a red rim on the ribbon below the alert
    var cost = 0;
    for (final p in plateaus) {
      cost += p.active.length;
    }
    // A heavy stream zoomed far out: one band, no per-lane shapes.
    final collapse = cost > 9000;
    final paths = collapse
        ? null
        : List<Path?>.filled(lanes.lanes.length, null);
    final openX = List<double>.filled(lanes.lanes.length, 0);
    final openTop = List<double>.filled(lanes.lanes.length, double.nan);
    // A label's amount right-aligns where its lane's run ends, clear of the
    // next step's dots / connector, so every lane of that stack shares it.
    final texts =
        <({int lane, double x0, double x1, double top, double edge})>[];
    final dayPx = plot.width / math.max(visibleDays, 0.001);
    final dotR = dayPx >= laneDotsMinDayPx
        ? laneDotRadius(
            dayPx > 28
                ? 4.5
                : dayPx > 12
                ? 3.4
                : 2.2,
            h,
          )
        : 0.0;
    final band = Path();
    // The line starts at the opening balance: on the seed day a plain riser
    // joins the opening diamond to the ribbon (whose level is the day's
    // closing balance, i.e. the opening plus the day's net).
    final riser = Path();
    final seedBal = seedBalance;
    if (seedBal != null) {
      final seedDay = dateOnly(seedDate);
      for (final p in plateaus) {
        if (p.day != seedDay) continue;
        final y0 = scale.yOf(seedBal), y1 = scale.yOf(p.balance);
        if ((y0 - y1).abs() > 0.5) {
          final r = Rect.fromLTRB(
            p.x0 - 1.8,
            math.min(y0, y1) - 1.8,
            p.x0 + 1.8,
            math.max(y0, y1) + 1.8,
          );
          riser.addRect(r);
          debugRiser?.call(r);
        }
        break;
      }
    }
    final showText = !collapse && h >= laneTextMinHeight;
    const rim = 2.4;
    final truth = <Rect>[];

    for (var pi = 0; pi < plateaus.length; pi++) {
      final p = plateaus[pi];
      final next =
          pi + 1 < plateaus.length && (plateaus[pi + 1].x0 - p.x1).abs() < 0.5
          ? plateaus[pi + 1]
          : null;
      final yb = scale.yOf(p.balance);
      final m = p.active.length;
      final yn = next == null ? 0.0 : scale.yOf(next.balance);
      final mn = next?.active.length ?? 0;
      final w = stackConnectorWidth(p.x1 - p.x0);
      if (m == 0 || (next != null && mn == 0)) {
        // The plain line: this level, and the rise or fall into the next.
        if (m == 0) {
          thin.addRect(Rect.fromLTRB(p.x0, yb - 1.8, p.x1, yb + 1.8));
        }
        if (next != null && (m == 0 || mn == 0)) {
          thin.addRect(
            Rect.fromLTRB(
              p.x1 - 1.8,
              math.min(yb, yn) - 1.8,
              p.x1 + 1.8,
              math.max(yb, yn) + 1.8,
            ),
          );
        }
      }
      if (m == 0) continue;
      // The balance line itself, drawn over the lanes so it can be traced
      // end to end: this level (just over the stack), and its step into the
      // next stack at the day edge.
      truth.add(Rect.fromLTRB(p.x0, yb - 1.5, p.x1, yb + 1.5));
      if (next != null && mn > 0 && (yn - yb).abs() > 0.5) {
        truth.add(
          Rect.fromLTRB(
            p.x1 - 1.5,
            math.min(yb, yn) - 1.5,
            p.x1 + 1.5,
            math.max(yb, yn) + 1.5,
          ),
        );
      }
      final top0 = laneTop(yb, 0, m, h);
      debugRibbon?.call(
        p.day,
        Rect.fromLTRB(p.x0, top0, p.x1, top0 + m * h),
        yb,
      );
      if (_isLoss(p.balance)) {
        // Under the stack: the gap over it belongs to the line's outline.
        loss.addRect(
          Rect.fromLTRB(p.x0, top0 + m * h, p.x1, top0 + m * h + rim),
        );
      }
      if (collapse) {
        band.addRect(Rect.fromLTRB(p.x0, top0, p.x1, top0 + m * h));
        continue;
      }
      var j = 0;
      for (var k = 0; k < m; k++) {
        final li = p.active[k];
        final top = laneTop(yb, k, m, h);
        int? nk;
        if (next != null) {
          while (j < mn && next.active[j] < li) {
            j++;
          }
          if (j < mn && next.active[j] == li) nk = j;
        }
        final topN = nk == null ? null : laneTop(yn, nk, mn, h);
        final continues = topN != null && (topN - top).abs() < 0.01;
        final xEnd = topN == null || continues ? p.x1 : p.x1 - w;
        final path = paths![li] ??= Path();
        path.addRect(Rect.fromLTRB(p.x0, top, xEnd, top + h));
        if (topN != null && !continues) {
          path.addPolygon([
            Offset(xEnd, top),
            Offset(p.x1, topN),
            Offset(p.x1, topN + h),
            Offset(xEnd, top + h),
          ], true);
        }
        if (showText) {
          if (openTop[li].isNaN) {
            openX[li] = p.x0;
            openTop[li] = top;
          }
          if (topN == null || !continues) {
            texts.add((
              lane: li,
              x0: openX[li],
              x1: xEnd,
              top: openTop[li],
              edge: next == null ? p.x1 : p.x1 - math.max(w, dotR + 2) - 2,
            ));
            openTop[li] = double.nan;
          }
        }
      }
    }

    if (collapse) {
      canvas.drawPath(band, Paint()..color = const Color(0xFF4A6285));
    } else {
      for (final (li, path) in paths!.indexed) {
        if (path == null) continue;
        canvas.drawPath(path, Paint()..color = lanes.lanes[li].color);
      }
    }
    canvas.drawPath(loss, Paint()..color = AppTheme.debitColor);

    // Lane names and amount pills first: the balance line goes over them.
    final drawText = <void Function()>[];
    if (showText) {
      _layoutLaneTexts(canvas, layout, texts, h, drawText);
    }
    for (final d in drawText) {
      d();
    }

    // The balance line on top of every lane and its text (and the opening
    // riser, and the plain line where no lane is active), with a dark outline
    // so it can be traced on any lane colour. Only the dots and chips, drawn
    // later, sit above it.
    final halo = Path(), core = Path()..addPath(riser, Offset.zero);
    for (final r in truth) {
      halo.addRect(r.inflate(2.1));
      core.addRect(r);
      debugTrueLine?.call(r);
    }
    const outline = Color(0xF00B1017);
    canvas.drawPath(
      riser,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.2,
    );
    canvas.drawPath(halo, Paint()..color = outline);
    canvas.drawPath(core, Paint()..color = _lineColor);
    canvas.drawPath(thin, Paint()..color = _lineColor);
  }

  void _layoutLaneTexts(
    Canvas canvas,
    ChartLayout layout,
    List<({int lane, double x0, double x1, double top, double edge})> texts,
    double h,
    List<void Function()> draws,
  ) {
    final plot = layout.plot;
    final fontSize = (h - 4).clamp(8.0, 11.0).toDouble();
    final style = TextStyle(
      fontSize: fontSize,
      height: 1.0,
      fontWeight: FontWeight.w600,
      color: const Color(0xF2FFFFFF),
    );
    final amountStyle = style.copyWith(fontWeight: FontWeight.w800);
    final strip = ChartLayout.laneNameWidth(layout.size.width);
    for (final t in texts) {
      // Names stay in view as the lane's left end scrolls off: they start
      // after the y-axis labels' strip, else just right of the dot.
      final clipped = t.x0 <= plot.left + 0.5;
      final startX = clipped ? plot.left + strip + 4 : t.x0 + 10;
      if (startX > plot.right) continue;
      final lane = lanes.lanes[t.lane];
      // The amount, signed and coloured on a small dark pill (readable on
      // every lane colour), right-aligned at the segment's shared edge (or
      // the chart's right edge when the segment runs off it), so a stack's
      // amounts form a column; the name, left, gives way first.
      final amountPainter = _axisText.get(
        formatSignedAmount(lane.amount),
        amountStyle.copyWith(
          color: lane.amount < 0 ? AppTheme.debitColor : AppTheme.creditColor,
        ),
        maxLines: 1,
      );
      final pillW = amountPainter.width + 8;
      final right = math.min(t.edge, plot.right - 4);
      final avail = right - startX;
      if (avail < pillW) continue;
      final nameMax = avail - pillW - 6;
      final cy = t.top + h / 2;
      if (nameMax >= 24) {
        // Widths in steps, so a panning (growing) segment reuses its text.
        final maxW = (nameMax / 6).floorToDouble() * 6;
        final painter = _axisText.get(
          lane.label,
          style,
          maxLines: 1,
          ellipsis: '…',
          maxWidth: maxW,
        );
        final at = Offset(startX, cy - painter.height / 2);
        draws.add(() {
          painter.paint(canvas, at);
          debugLaneName?.call(lane.name, at & painter.size);
        });
      }
      final pill = RRect.fromRectAndRadius(
        Rect.fromLTWH(right - pillW, cy - (h - 3) / 2, pillW, h - 3),
        const Radius.circular(3),
      );
      draws.add(() {
        canvas.drawRRect(pill, Paint()..color = laneAmountPillColor);
        debugLaneAmount?.call(
          lane.name,
          amountPainter.text!.toPlainText(),
          lane.amount < 0 ? AppTheme.debitColor : AppTheme.creditColor,
          pill.outerRect,
        );
        amountPainter.paint(
          canvas,
          Offset(pill.left + 4, cy - amountPainter.height / 2),
        );
      });
    }
  }

  /// Day dots and day totals for the stacked lanes: a dot per event on
  /// the left edge of its day, in that event's lane; the day's net
  /// total above (else below) the ribbon, flush left with the day.
  void _paintLaneOccurrences(
    Canvas canvas,
    ChartLayout layout,
    _YScale scale,
    DateTime viewEnd,
    DateTime seed,
    Map<int, double> closes,
  ) {
    final plot = layout.plot;
    final h = _laneH > 0 ? _laneH : _laneHeight(lanes, layout);
    final dayPx = plot.width / math.max(visibleDays, 0.001);
    final base = dayPx > 28
        ? 4.5
        : dayPx > 12
        ? 3.4
        : 2.2;
    final r = laneDotRadius(base, h);
    final dots = dayPx >= laneDotsMinDayPx;
    final simple = dayPx < 8;

    final chips = <({Rect rect, Offset dot, String text, Color? color})>[];
    // Thin leaders from a chip pushed off its stack back to its step.
    final leaders = <(Offset, Offset)>[];
    final dayStyle = labelStyle.copyWith(
      fontSize: dayPx >= 32 ? 11.5 : 10.5,
      height: 1.0,
      fontWeight: FontWeight.w800,
    );
    // Day totals: the ribbon's rects, then earlier totals, are kept clear.
    final placed = <Rect>[..._markerLabelRects(layout)];
    for (final p in _plateaus) {
      final m = p.active.length;
      if (m == 0) continue;
      final yb = scale.yOf(p.balance);
      // The line (and its outline) over the stack, then the lanes.
      placed.add(Rect.fromLTRB(p.x0, yb - 4, p.x1, stackBottomOf(yb, m, h)));
    }
    void chip(
      double x,
      double above,
      double below,
      Offset dot,
      String text,
      Color? color,
    ) {
      final painter = _axisText.get(
        text,
        dayStyle.copyWith(color: color),
        maxLines: 1,
      );
      final w = painter.width + 8, hh = painter.height + 4;
      // Closest to the stack first: above it, then below; when a neighbour's
      // chip is in the way, the next row out, so no step goes without its
      // net while the view is narrow enough to have room at all.
      for (final top in [
        for (var k = 0; k < 8; k++) ...[
          above - 3 - hh - k * (hh + 2),
          below + 3 + k * (hh + 2),
        ],
      ]) {
        if (top < plot.top + 1 || top + hh > plot.bottom - 1) continue;
        // A step near the right edge keeps its net on screen: the chip
        // slides left of its dot rather than being cut off.
        final left = x < plot.right - 2
            ? math.max(plot.left + 1, math.min(x, plot.right - w - 2))
            : x;
        final rect = Rect.fromLTWH(left, top, w, hh);
        if (placed.any((q) => q.overlaps(rect))) continue;
        placed.add(rect.inflate(1));
        chips.add((rect: rect, dot: dot, text: text, color: color));
        if (top + hh < above - 0.5) {
          leaders.add((Offset(x + 0.5, top + hh), Offset(x + 0.5, above)));
        } else if (top > below + 0.5) {
          leaders.add((Offset(x + 0.5, below), Offset(x + 0.5, top)));
        }
        return;
      }
    }

    canvas.save();
    canvas.clipRect(plot);
    if (dots) {
      final ring = Paint()
        ..color = _plotBg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      final marginDays = 80 / math.max(dayPx, 0.001);
      for (final g in groupByDay(series.occurrences)) {
        final day = g.day;
        if (day.isBefore(seed) ||
            !addCalendarDays(day, 1).isAfter(addDays(viewStart, -marginDays)) ||
            day.isAfter(addDays(viewEnd, marginDays))) {
          continue;
        }
        final yValue = closes[day.millisecondsSinceEpoch];
        if (yValue == null) continue;
        final x = layout.xOf(day, viewStart, visibleDays);
        final balanceY = scale.yOf(yValue);
        final laneDots = laneDotsForDay(
          lanes: lanes,
          group: g,
          balanceY: balanceY,
          thickness: h,
        );
        final inView = x >= plot.left - r - 4 && x <= plot.right + r + 4;
        if (inView) {
          for (final d in laneDots.dots) {
            final center = Offset(x, d.y);
            if (d.idle) {
              debugLaneIdleDot?.call(d.txId, center);
            } else {
              debugLaneDot?.call(d.txId, center);
            }
            // Event lanes draw no dots (the line's step dots carry the
            // day's net); a lane-less occurrence, on the line, shows.
            if (d.txId != null) continue;
            debugLaneDotPainted?.call(d.txId, center, d.idle);
            if (d.idle) {
              // The lane has no event on this step: a small dimmed
              // ring, so the occurring dots still stand out.
              final ir = math.max(1.7, r * 0.62);
              canvas.drawCircle(
                center,
                ir,
                Paint()..color = _plotBg.withValues(alpha: 0.6),
              );
              canvas.drawCircle(
                center,
                ir,
                Paint()
                  ..color = Colors.white.withValues(alpha: 0.8)
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.2,
              );
              continue;
            }
            final own = DayGroup(day, d.own);
            final net = own.net;
            if (own.allSkipped) {
              canvas.drawCircle(center, r, Paint()..color = _plotBg);
              canvas.drawCircle(
                center,
                r,
                Paint()
                  ..color = AppTheme.textFaint
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.4,
              );
            } else {
              canvas.drawCircle(
                center,
                r,
                Paint()
                  ..color = net < 0
                      ? AppTheme.debitColor
                      : AppTheme.creditColor,
              );
              if (!simple) canvas.drawCircle(center, r, ring);
            }
            // Combined view: another stream's money gets its tint as a ring.
            if (!simple) {
              final stream = d.own.first.streamId;
              final c = stream == null ? null : streamColors[stream];
              if (c != null) {
                canvas.drawCircle(
                  center,
                  r + 2.2,
                  Paint()
                    ..color = c
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 2,
                );
              }
            }
          }
        }
        if (laneDots.dots.isEmpty || x < plot.left - 80 || x > plot.right) {
          continue;
        }
        final net = g.net;
        // Just over the line first (the lanes hang under it), else under
        // the stack.
        chip(
          x,
          balanceY - 4,
          laneDots.stackBottom,
          Offset(x, laneDots.dots.first.y),
          formatSignedAmount(net),
          g.allSkipped
              ? AppTheme.textFaint
              : net < 0
              ? AppTheme.debitColor
              : AppTheme.creditColor,
        );
      }
    }
    final seedBal = seedBalance;
    if (seedBal != null) {
      final c = Offset(
        layout.xOf(dateOnly(seedDate), viewStart, visibleDays),
        scale.yOf(seedBal),
      );
      if (plot.inflate(2).contains(c)) {
        _paintSeedVertex(canvas, c, seedVertexRadius(base));
        chip(
          c.dx,
          c.dy - 4,
          c.dy + 4,
          c,
          'Opening ${formatMoneyAmount(seedBal)}',
          AppTheme.accent,
        );
      }
    }
    final leaderPaint = Paint()
      ..color = AppTheme.textFaint
      ..strokeWidth = 1;
    for (final (a, b) in leaders) {
      canvas.drawLine(a, b, leaderPaint);
    }
    for (final c in chips) {
      final rrect = RRect.fromRectAndRadius(c.rect, const Radius.circular(4));
      canvas.drawRRect(
        rrect,
        Paint()..color = AppTheme.raised.withValues(alpha: 0.94),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppTheme.border,
      );
      _axisText
          .get(c.text, dayStyle.copyWith(color: c.color), maxLines: 1)
          .paint(canvas, Offset(c.rect.left + 4, c.rect.top + 2));
    }
    canvas.restore();
    final rectHook = debugVertexLabelRect, linesHook = debugVertexLabelLines;
    for (final c in chips) {
      if (!plot.contains(c.rect.center)) continue;
      rectHook?.call(c.text, c.dot, r, c.rect);
      linesHook?.call(c.rect, [c.text]);
    }
    labelHits
      ..clear()
      ..addAll([
        for (final c in chips)
          if (plot.contains(c.rect.center)) (rect: c.rect, dot: c.dot),
      ]);
    labelMemory.clear();
  }

  bool _isLoss(double value) => belowAlert(value, lossThreshold);

  /// A dot on the balance line wherever it steps: the line's colour (red
  /// below the alert, like the line) with a dark ring, over the line and
  /// the lanes. The hovered / tapped one is larger with a white ring.
  void _paintStepDots(Canvas canvas, ChartLayout layout, _YScale scale) {
    if (stepDots.isEmpty) return;
    canvas.save();
    canvas.clipRect(layout.plot.inflate(1));
    final ring = Paint()
      ..color = _plotBg
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    StepDot? active;
    for (final d in stepDots) {
      if (d.step.day == activeStep) {
        active = d;
        continue;
      }
      final fill = _isLoss(d.step.balance) ? AppTheme.debitColor : _lineColor;
      canvas.drawCircle(d.center, d.radius, Paint()..color = fill);
      canvas.drawCircle(d.center, d.radius, ring);
      debugStepDotPainted?.call(d.step, d.center, d.radius, false);
    }
    if (active != null) {
      final r = active.radius + 2;
      final fill = _isLoss(active.step.balance)
          ? AppTheme.debitColor
          : _lineColor;
      canvas.drawCircle(active.center, r + 2, Paint()..color = _plotBg);
      canvas.drawCircle(active.center, r, Paint()..color = fill);
      canvas.drawCircle(
        active.center,
        r,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      debugStepDotPainted?.call(active.step, active.center, r, true);
    }
    canvas.restore();
  }

  /// A chip at the bottom edge when balances in view dip below the
  /// vertical range, so a clipped low (or overdraft) is noticed (drag or
  /// wheel to it). Clipped highs get no chip (removed with the
  /// "max" / "min" axis labels).
  void _paintOffscreenHints(
    Canvas canvas,
    ChartLayout layout,
    _YScale scale,
    BalanceExtents extents,
  ) {
    final text = offscreenHint(extents, scale.yMin);
    if (text == null) return;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: strongStyle.copyWith(fontSize: 11, color: AppTheme.onAccent),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = painter.width + 16;
    final h = painter.height + 6;
    final left = layout.plot.center.dx - w / 2;
    final y = layout.plot.bottom - h - 4;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, y, w, h),
        Radius.circular(h / 2),
      ),
      Paint()..color = AppTheme.accent.withValues(alpha: 0.9),
    );
    painter.paint(canvas, Offset(left + 8, y + 3));
    painter.dispose();
  }

  double _absMax(BalanceExtents extents) =>
      math.max(extents.min.abs(), extents.max.abs());

  /// Where a day's balance change is drawn: the left edge of its day cell,
  /// where its lanes begin and its dots sit.
  DateTime _stepAt(DateTime date) => dateOnly(date);

  void _paintOccurrences(
    Canvas canvas,
    ChartLayout layout,
    _YScale scale,
    DateTime viewEnd,
    DateTime seed,
  ) {
    // Days before the seed are skipped below, so no seed filter here.
    final closes = pointIndexOf(series.points).closeByDayMs;
    final dayPx = layout.plot.width / math.max(visibleDays, 0.001);
    if (!lanes.isEmpty) {
      _paintLaneOccurrences(canvas, layout, scale, viewEnd, seed, closes);
      return;
    }
    final radius = dayPx > 28
        ? 4.5
        : dayPx > 12
        ? 3.4
        : 2.2;
    final vertices = <_ChartVertex>[];

    canvas.save();
    canvas.clipRect(layout.plot);
    for (final g in groupByDay(series.occurrences)) {
      final day = g.day;
      final nextDay = addCalendarDays(day, 1);
      // A view-width margin each side feeds the label layout (see
      // _paintVertexLabels); those dots fall outside the clip.
      if (day.isBefore(seed) ||
          !nextDay.isAfter(addDays(viewStart, -visibleDays)) ||
          day.isAfter(addDays(viewEnd, visibleDays))) {
        continue;
      }
      final yValue = closes[day.millisecondsSinceEpoch];
      if (yValue == null) continue;
      final x = layout.xOf(_stepAt(day), viewStart, visibleDays);
      final center = Offset(x, scale.yOf(yValue));
      final net = g.net;
      if (g.allSkipped) {
        canvas.drawCircle(center, radius, Paint()..color = _plotBg);
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = AppTheme.textFaint
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      } else {
        final color = net < 0 ? AppTheme.debitColor : AppTheme.creditColor;
        canvas.drawCircle(center, radius, Paint()..color = color);
        if (g.mixed) {
          // Money in and out that day: half-and-half dot.
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            -math.pi / 2,
            math.pi,
            true,
            Paint()
              ..color = net < 0 ? AppTheme.creditColor : AppTheme.debitColor,
          );
        }
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = _plotBg
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      // Combined view: another stream's money that day gets its tint as a
      // ring (split into arcs when several other streams share the day).
      final others = [for (final id in g.otherStreams) ?streamColors[id]];
      for (final (i, c) in others.indexed) {
        final sweep = 2 * math.pi / others.length;
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius + 2.2),
          -math.pi / 2 + i * sweep,
          sweep,
          false,
          Paint()
            ..color = c
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      vertices.add(
        _ChartVertex(
          center: center,
          radius: radius,
          names: _dayNames(g),
          amount: net,
          skipped: g.allSkipped,
          debit: net < 0,
          key: day.millisecondsSinceEpoch,
        ),
      );
    }
    final seedBal = seedBalance;
    if (seedBal != null) {
      final c = Offset(
        layout.xOf(dateOnly(seedDate), viewStart, visibleDays),
        scale.yOf(seedBal),
      );
      if (layout.plot.inflate(2).contains(c) ||
          (c.dx - layout.plot.center.dx).abs() < layout.plot.width * 1.5) {
        _paintSeedVertex(canvas, c, seedVertexRadius(radius));
        vertices.add(
          _ChartVertex(
            center: c,
            radius: seedVertexRadius(radius),
            names: const ['Opening'],
            amount: seedBal,
            skipped: false,
            debit: false,
            seed: true,
            key: -1,
          ),
        );
      }
    }
    canvas.restore();
    _paintVertexLabels(canvas, layout, vertices);
  }

  /// Opening-balance vertex: a hollow accent diamond, unlike the round
  /// event dots.
  void _paintSeedVertex(Canvas canvas, Offset c, double r) {
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..lineTo(c.dx + r, c.dy)
      ..lineTo(c.dx, c.dy + r)
      ..lineTo(c.dx - r, c.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = _plotBg);
    canvas.drawPath(
      path,
      Paint()
        ..color = AppTheme.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  /// Names of the events counted on day [g] (the skipped ones only
  /// when every one is skipped), once each, in the order they were added
  /// (as the dot popup's Edit menu lists them).
  List<String> _dayNames(DayGroup g) {
    final ids = <String>{
      for (final o in g.allSkipped ? g.all : g.active) o.eventId,
    }.toList();
    final order = {for (final (i, id) in eventOrder.indexed) id: i};
    final fallback = {for (final (i, id) in eventNames.keys.indexed) id: i};
    int rank(String id) =>
        order[id] ?? (order.length + (fallback[id] ?? fallback.length));
    final sorted = [...ids]
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        return byRank != 0 ? byRank : ids.indexOf(a).compareTo(ids.indexOf(b));
      });
    return [
      for (final id in sorted)
        if (eventNames[id] case final raw?)
          raw.trim().isEmpty ? 'Event' : raw.trim(),
    ];
  }

  /// Event labels for each occurrence dot, flush left with the dot and
  /// directly above it (or below, when above runs off the plot or collides).
  /// Width follows the free room and the zoom, and a label is omitted when
  /// neither spot is free.
  void _paintVertexLabels(
    Canvas canvas,
    ChartLayout layout,
    List<_ChartVertex> vertices,
  ) {
    if (vertices.isEmpty) return;
    // Labels are laid out on a strip one view wider on each side, so the
    // plot's left/right edges never take part in the decision: what is
    // placed mid-plot depends only on the dots, and labels slide off at the
    // edges (clipped) instead of hopping sides or blinking during a pan.
    final view = layout.plot;
    final plot = Rect.fromLTRB(
      view.left - view.width,
      view.top,
      view.right + view.width,
      view.bottom,
    );
    final dayPx = view.width / math.max(visibleDays, 0.001);
    final fontSize = textScaler.scale(
      dayPx >= 32
          ? 12
          : dayPx >= 14
          ? 11
          : 10,
    );
    final densityCap = dayPx >= 28
        ? 160.0
        : dayPx >= 12
        ? 120.0
        : 84.0;
    final maxText = math.min(densityCap, view.width * 0.34);
    const minText = 18.0;
    const pad = 10.0;
    if (maxText < minText) return;

    vertices.sort((a, b) {
      final byX = a.center.dx.compareTo(b.center.dx);
      if (byX != 0) return byX;
      return b.center.dy.compareTo(a.center.dy);
    });
    final anchors = [for (final vertex in vertices) vertex.center];
    // Previously labelled vertices first, then the rest, each left to right.
    final order = [
      ...vertices.where((v) => labelMemory.containsKey(v.key)),
      ...vertices.where((v) => !labelMemory.containsKey(v.key)),
    ];
    final shown = <int, _LabelSpot>{};
    final style = labelStyle.copyWith(
      fontSize: fontSize,
      height: 1.0,
      fontWeight: FontWeight.w600,
      color: AppTheme.text,
    );
    final lineHeight = _axisText.get('Mg', style).height;
    // Total + one name: the typical label, for the neighbour check below.
    final labelHeight = lineHeight * 2 + 4;

    canvas.save();
    canvas.clipRect(view);
    final placed = <Rect>[..._markerLabelRects(layout)];
    final labeledAt = <Offset>[];
    final neighborGap = dayPx >= 4.5 ? 10.0 : 30.0;
    for (final vertex in order) {
      if (!plot.contains(vertex.center)) continue;
      final crowded = labeledAt.any((at) {
        final dx = (vertex.center.dx - at.dx).abs();
        final dy = (vertex.center.dy - at.dy).abs();
        return dx < neighborGap && dy < labelHeight + 18;
      });
      if (crowded) continue;
      final vertexStyle = vertex.skipped
          ? style.copyWith(color: AppTheme.textFaint)
          : style;
      // Main line: the day's net event total (never the balance).
      final amount = TextPainter(
        text: TextSpan(
          text: vertex.seed
              ? formatMoneyAmount(vertex.amount)
              : formatSignedAmount(vertex.amount),
          style: vertexStyle.copyWith(
            fontWeight: FontWeight.w800,
            color: vertex.skipped
                ? null
                : vertex.seed
                ? AppTheme.accent
                : vertex.debit
                ? AppTheme.debitColor
                : AppTheme.creditColor,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final names = vertex.names;
      final moreStyle = vertexStyle.copyWith(
        color: AppTheme.textMuted,
        fontWeight: FontWeight.w500,
      );
      // A name is shortened with "…" down to about three letters, no less.
      final minName = fontSize * 2.4;
      final widths = <String, double>{};
      double widthOf(String text, TextStyle st) => widths.putIfAbsent(
        '${identical(st, moreStyle) ? 'm' : 'n'}$text',
        // Shortening probes many stubs per name; they recur every frame.
        () => _axisText.get(text, st, maxLines: 1).width,
      );

      // [text] within [maxWidth], shortened with "…" if need be; null when
      // not even a readable stub fits.
      String? fitName(String text, double maxWidth) {
        if (widthOf(text, vertexStyle) <= maxWidth) return text;
        final chars = text.characters.toList();
        if (chars.length < 3 || maxWidth < minName) return null;
        String stub(int n) => '${chars.take(n).join().trimRight()}…';
        var lo = 2, hi = chars.length - 1;
        if (widthOf(stub(lo), vertexStyle) > maxWidth) return null;
        while (lo < hi) {
          final mid = (lo + hi + 1) ~/ 2;
          if (widthOf(stub(mid), vertexStyle) <= maxWidth) {
            lo = mid;
          } else {
            hi = mid - 1;
          }
        }
        return stub(lo);
      }

      // The lines under the total: [shown] names, then "+N more" for the
      // rest; [compact]: one line, the first name then "+N more". Always at
      // least one name, so a label is never the amount alone.
      List<_LabelLine> linesFor(int shown, {bool compact = false}) {
        final rest = names.length - shown;
        if (compact) {
          return [(name: names.first, more: rest > 0 ? '+$rest more' : null)];
        }
        return [
          for (final n in names.take(shown)) (name: n, more: null),
          if (rest > 0) (name: null, more: '+$rest more'),
        ];
      }

      final laidOut = <String, List<TextPainter>?>{};
      // Painters for [spec] at most [maxWidth] wide (names shortened to
      // fit), or null when a line can't be made readable. Cached: the
      // painters are disposed after this vertex.
      List<TextPainter>? layoutLines(
        String key,
        List<_LabelLine> spec,
        double maxWidth,
      ) => laidOut.putIfAbsent('$key@${maxWidth.floor()}', () {
        final out = <TextPainter>[];
        for (final (:name, :more) in spec) {
          final suffix = more == null ? '' : (name == null ? more : ' $more');
          final suffixWidth = suffix.isEmpty ? 0.0 : widthOf(suffix, moreStyle);
          String? text;
          if (name != null) {
            text = fitName(name, maxWidth - suffixWidth);
            if (text == null) return null;
          } else if (suffixWidth > maxWidth) {
            return null;
          }
          out.add(
            TextPainter(
              text: TextSpan(
                children: [
                  if (text != null) TextSpan(text: text, style: vertexStyle),
                  if (suffix.isNotEmpty)
                    TextSpan(text: suffix, style: moreStyle),
                ],
              ),
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout(),
          );
        }
        return out;
      });

      double heightOf(List<TextPainter> lines) =>
          lines.fold(amount.height, (h, p) => h + p.height) + 4;
      double boxWidth(List<TextPainter> lines) =>
          lines.fold(amount.width, (w, p) => math.max(w, p.width)) + pad;
      void draw(
        Rect rect,
        List<TextPainter> lines,
        int shownNames,
        bool compact,
      ) {
        final leader = vertexLabelLeader(
          center: vertex.center,
          radius: vertex.radius,
          rect: rect,
        );
        if (leader != null) {
          canvas.drawLine(
            leader.topCenter,
            leader.bottomCenter,
            Paint()
              ..color = AppTheme.border
              ..strokeWidth = 1,
          );
        }
        _drawVertexLabel(canvas, amount, lines, rect);
        debugVertexLabelLines?.call(rect, [
          amount.plainText,
          for (final l in lines) l.plainText,
        ]);
        placed.add(rect);
        if (leader != null) placed.add(leader);
        labeledAt.add(vertex.center);
        shown[vertex.key] = (
          rect: rect.shift(-vertex.center),
          names: shownNames,
          compact: compact,
        );
      }

      var drawn = false;
      // Hysteresis: a label shown last frame first tries the same box
      // relative to its dot (same lines, same width), so it neither hops
      // sides nor blinks while the view moves. It only gives way when that
      // spot now truly overlaps.
      final last = labelMemory[vertex.key];
      if (last != null &&
          last.names >= 1 &&
          last.names <= names.length &&
          (!last.compact || names.length > 1)) {
        final lines = layoutLines(
          'last',
          linesFor(last.names, compact: last.compact),
          math.max(amount.width, last.rect.width - pad + 0.5),
        );
        if (lines != null) {
          final rect = last.rect.shift(vertex.center);
          if ((heightOf(lines) - rect.height).abs() < 0.5 &&
              vertexLabelFits(
                rect: rect,
                plot: plot,
                anchor: vertex.center,
                radius: vertex.radius,
                occupied: placed,
                anchors: anchors,
                attachReach: 96,
              )) {
            draw(rect, lines, last.names, last.compact);
            drawn = true;
          }
        }
      }
      // Fresh layout. Every option names at least one event: as many
      // names as fit (most first), then, on a busy day, "Name +N more" on a
      // single line. Each is tried above, then below the dot, flush left
      // with it, names shortened with "…" to fit the room. Only when none
      // fits right against the dot is the label pushed a little further
      // away (with a leader line) before the dot goes unlabelled — never
      // amount-only.
      final specs = [
        for (var k = math.min(names.length, maxLabelNames); k >= 1; k--)
          (k, false, linesFor(k)),
        if (names.length > 1) (1, true, linesFor(1, compact: true)),
      ];
      search:
      for (final offset in const [0.0, 6.0, 12.0, 18.0, maxVertexLabelOffset]) {
        if (drawn) break;
        for (final (k, compact, spec) in specs) {
          final height = amount.height + spec.length * lineHeight + 4;
          for (final side in VertexLabelSide.values) {
            final budget = vertexLabelTextBudget(
              plot: plot,
              center: vertex.center,
              radius: vertex.radius,
              side: side,
              labelHeight: height,
              maxText: maxText,
              minText: minText,
              pad: pad,
              occupied: placed,
              anchors: anchors,
              offset: offset,
            );
            if (budget <= 0 || budget < amount.width) continue;
            final lines = layoutLines('$k$compact', spec, budget);
            if (lines == null) continue;
            final rect = vertexLabelRect(
              center: vertex.center,
              radius: vertex.radius,
              side: side,
              width: boxWidth(lines),
              height: heightOf(lines),
              offset: offset,
            );
            if (vertexLabelFits(
              rect: rect,
              plot: plot,
              anchor: vertex.center,
              radius: vertex.radius,
              occupied: placed,
              anchors: anchors,
              attachReach: offset + 10,
            )) {
              draw(rect, lines, k, compact);
              drawn = true;
              break search;
            }
          }
        }
      }
      for (final ps in laidOut.values) {
        for (final p in ps ?? const <TextPainter>[]) {
          p.dispose();
        }
      }
      amount.dispose();
    }
    canvas.restore();
    labelMemory
      ..clear()
      ..addAll(shown);
    labelHits
      ..clear()
      ..addAll([
        for (final v in vertices)
          if (shown[v.key] case final spot? when view.contains(v.center))
            (rect: spot.rect.shift(v.center), dot: v.center),
      ]);
    final rectHook = debugVertexLabelRect;
    if (rectHook != null) {
      for (final v in vertices) {
        final rel = shown[v.key]?.rect;
        if (rel == null || !view.contains(v.center)) continue;
        rectHook(v.label, v.center, v.radius, rel.shift(v.center));
      }
    }
    final hook = debugVertexLabel;
    if (hook != null) {
      for (final v in vertices) {
        if (!view.contains(v.center)) continue;
        hook(v.label, v.center.dx, shown.containsKey(v.key));
      }
    }
  }

  List<Rect> _markerLabelRects(ChartLayout layout) {
    final rects = <Rect>[];
    void add(DateTime date, String label, {bool alignLeft = false}) {
      final day = dateOnly(date);
      final next = addCalendarDays(day, 1);
      if (!next.isAfter(viewStart) || day.isAfter(_viewEnd)) return;
      final x = layout.xOf(day, viewStart, visibleDays);
      if (x < layout.plot.left || x > layout.plot.right) return;
      final painter = TextPainter(
        text: TextSpan(text: label, style: laneStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final rawLeft = alignLeft ? x - painter.width - 4 : x + 4;
      final left = rawLeft
          .clamp(layout.plot.left, layout.plot.right - painter.width)
          .toDouble();
      rects.add(
        Rect.fromLTWH(
          left,
          layout.plot.top + 2,
          painter.width,
          painter.height,
        ).inflate(4),
      );
      painter.dispose();
    }

    final today = dateOnly(DateTime.now());
    final seedDay = dateOnly(seedDate);
    final todayFirst = today.isBefore(seedDay);
    add(today, 'Today', alignLeft: todayFirst);
    add(seedDay, 'Seed', alignLeft: !todayFirst);
    return rects;
  }

  /// Label box: the day total on top, then each line (names / "+N more")
  /// under it, left-aligned at the box's inset.
  void _drawVertexLabel(
    Canvas canvas,
    TextPainter amount,
    List<TextPainter> lines,
    Rect rect,
  ) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(
      rrect,
      Paint()..color = AppTheme.raised.withValues(alpha: 0.94),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = AppTheme.border,
    );
    final textLeft = rect.left + 5;
    var y = rect.top + 2;
    amount.paint(canvas, Offset(textLeft, y));
    y += amount.height;
    for (final line in lines) {
      line.paint(canvas, Offset(textLeft, y));
      y += line.height;
    }
  }

  /// Paints [text] centred in [rect]; returns where it went, or null when
  /// it didn't fit and nothing was painted. With [row], reports the label to
  /// [debugAxisLabel].
  Rect? _paintCentered(
    Canvas canvas,
    Rect rect,
    String text,
    TextStyle style, {
    String? row,
  }) {
    if (rect.width < 8 || rect.height < 8 || text.isEmpty) return null;
    final maxLines = text.contains('\n') ? 2 : 1;
    // Cached across frames: never disposed here.
    final painter = _axisText.get(
      text,
      style,
      align: TextAlign.center,
      maxLines: maxLines,
      ellipsis: maxLines == 1 ? '…' : null,
      maxWidth: math.max(1, rect.width - 2),
    );
    if (painter.height > rect.height + 1) return null;
    final at = Offset(
      rect.center.dx - painter.width / 2,
      rect.center.dy - painter.height / 2,
    );
    final painted = at & painter.size;
    if (row != null) {
      // Report what is actually shown: an ellipsised label ends in "…".
      debugAxisLabel?.call(
        row,
        painter.didExceedMaxLines ? '$text…' : text,
        painted,
      );
    }
    painter.paint(canvas, at);
    return painted;
  }

  @override
  bool shouldRepaint(covariant _BalanceChartPainter oldDelegate) {
    return oldDelegate.series != series ||
        oldDelegate.seedDate != seedDate ||
        oldDelegate.lineStart != lineStart ||
        !mapEquals(oldDelegate.streamColors, streamColors) ||
        oldDelegate.seedBalance != seedBalance ||
        oldDelegate.lossThreshold != lossThreshold ||
        oldDelegate.viewStart != viewStart ||
        oldDelegate.visibleDays != visibleDays ||
        oldDelegate.labelStyle != labelStyle ||
        oldDelegate.strongStyle != strongStyle ||
        oldDelegate.laneStyle != laneStyle ||
        oldDelegate.textScaler != textScaler ||
        oldDelegate.dataFrom != dataFrom ||
        oldDelegate.yRange?.min != yRange?.min ||
        oldDelegate.highlightY != highlightY ||
        !identical(oldDelegate.stepDots, stepDots) ||
        oldDelegate.activeStep != activeStep ||
        oldDelegate.yRange?.max != yRange?.max ||
        oldDelegate.dataThrough != dataThrough ||
        !mapEquals(oldDelegate.eventNames, eventNames) ||
        !identical(oldDelegate.lanes, lanes) ||
        !listEquals(oldDelegate.eventOrder, eventOrder);
  }
}

/// Y-axis money: compact (\$1.5M) once values reach millions so labels
/// fit the gutter instead of being cut off.
String _axisMoney(double value, int digits, double scaleMax) {
  // Six-figure labels no longer fit the axis gutter ("max $556,123"):
  // switch to compact ($556.1K, $1.25M).
  if (scaleMax >= 1e5 && value.abs() >= 1e5) {
    return NumberFormat.compactCurrency(
      symbol: moneySymbol,
      decimalDigits: value.abs() >= 1e6 ? 2 : 1,
    ).format(value);
  }
  return formatMoneyAmount(value, decimalDigits: scaleMax >= 1e6 ? 0 : digits);
}

class _ChartVertex {
  const _ChartVertex({
    required this.center,
    required this.radius,
    required this.names,
    required this.amount,
    required this.skipped,
    required this.debit,
    this.seed = false,
    this.key = 0,
  });

  /// Stable identity across frames (day, or -1 for the opening vertex).
  final int key;

  /// The opening-balance vertex: amount unsigned, in the accent colour.
  final bool seed;

  /// Event names listed under the total, in the order added. Empty
  /// when none are known; the total is still shown.
  final List<String> names;

  /// For test hooks: the names joined.
  String get label => names.join(' · ');

  final Offset center;
  final double radius;

  /// The day's net event total (+ credit, − debit) over its counted
  /// occurrences (overrides included). Shown even when every one is
  /// skipped (greyed); the running balance is read off the axis.
  final double amount;
  final bool skipped;
  final bool debit;
}

class _YScale {
  _YScale(this.yMin, this.yMax, this.plot);

  final double yMin;
  final double yMax;
  final Rect plot;

  double yOf(double value) {
    final span = yMax - yMin;
    if (span.abs() < 1e-9) return plot.center.dy;
    final t = (value - yMin) / span;
    return plot.bottom - t * plot.height;
  }
}

class _Dot {
  _Dot(
    this.center,
    this.radius,
    this.occurrences,
    this.balanceAfter, {
    double? balanceY,
    this.day,
    this.txId,
    this.wholeDay = false,
    this.idle = false,
  }) : balanceY = balanceY ?? center.dy;

  /// Stacked lanes: this event has a lane at this step but does not
  /// occur on it ([occurrences] is empty; [txId] and [day] say which).
  final bool idle;

  /// Stacked lanes: stands for the whole day (the net chip), not one lane.
  final bool wholeDay;

  /// The day this dot is on (null: the opening-balance diamond).
  final DateTime? day;

  /// Stacked lanes: the event whose lane this dot sits in (null: none).
  final String? txId;

  /// Where the balance is on the y axis at this dot: the ribbon's centre.
  /// The dot itself sits in its lane, [center].dy; the y pill and guide
  /// follow the balance.
  final double balanceY;
  final Offset center;
  final double radius;

  /// Every occurrence on this vertex's day; empty for the opening-balance
  /// (seed) vertex.
  final List<Occurrence> occurrences;

  Occurrence? get occurrence => occurrences.isEmpty ? null : occurrences.first;

  bool get isSeed => occurrences.isEmpty && !idle;

  /// Stream balance right after this occurrence applied.
  final double balanceAfter;
}

/// One entry of a popup row's ⋮ menu.
class _RowAction {
  const _RowAction(this.key, this.icon, this.label, this.run);
  final String key;
  final IconData icon;
  final String label;
  final VoidCallback run;
}

/// The hovered / tapped balance step; [bumpSoon] re-notifies so Safari
/// presents a freshly tapped tooltip (see `_repaintSoon`).
class _StepTip extends ValueNotifier<BalanceStep?> {
  _StepTip() : super(null);

  void bumpSoon(bool Function() still) {
    if (!kIsWeb) return;
    for (final ms in const [50, 200]) {
      Timer(Duration(milliseconds: ms), () {
        if (still() && value != null) notifyListeners();
      });
    }
  }
}

/// Places a step tooltip over its dot, inside the plot ([placeStepTip]).
class _StepTipLayout extends SingleChildLayoutDelegate {
  _StepTipLayout(this.anchor, this.gap, this.bounds);

  final Offset anchor;
  final double gap;
  final Rect bounds;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(math.max(0.0, bounds.width - 8), math.max(0.0, bounds.height - 8)),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      placeStepTip(childSize, anchor, gap, bounds);

  @override
  bool shouldRelayout(_StepTipLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.gap != gap ||
      oldDelegate.bounds != bounds;
}

class _DotTip {
  const _DotTip(this.dots, this.anchor, {this.finger});
  final List<_Dot> dots;
  final Offset anchor;

  /// Touch scrub: where the finger is, so the card sits clear of it.
  final Offset? finger;
}

/// Hold tolerance around the balance line: holds closer than this never
/// start a selection.
const double touchLineHitTolerance = 16;
const double mouseLineHitTolerance = 8;

/// Distance from [p] to the segment [a]–[b].
double distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.distanceSquared;
  if (len2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

enum _Gesture { none, pan, pick, pinch, scrub, select }

/// First and last days a date-lane pick can select in a view: the first
/// day whose start is clear of the lane-name strip ([nameWidth] px over the
/// plot's left edge) to the last day whose start is on screen.
(DateTime, DateTime) pickableDays(
  ChartLayout layout,
  DateTime viewStart,
  double visibleDays,
  double nameWidth,
) {
  final plot = layout.plot;
  final width = math.max(plot.width, 1.0);
  final last = layout.dateAt(plot.right - 0.5, viewStart, visibleDays);
  final inset = nameWidth / width * visibleDays;
  var first = dateFromDayCoord(
    (dayCoord(viewStart) + inset - 1e-6).ceilToDouble(),
  );
  if (first.isAfter(last)) first = last;
  return (first, last);
}

/// View after a two-finger pinch: zooms time by the change in finger
/// distance, keeping the date under the starting focus under the current
/// focus (so the pinch also pans).
(DateTime, double) pinchView({
  required ChartLayout layout,
  required DateTime originStart,
  required double originDays,
  required double startDistance,
  required double distance,
  required double startFocusX,
  required double focusX,
}) {
  final width = layout.plot.width;
  final days = (originDays * startDistance / math.max(1.0, distance))
      .clamp(minVisibleDays, maxVisibleDays)
      .toDouble();
  final f0 = ((startFocusX - layout.plot.left) / width).clamp(0.0, 1.0);
  final f1 = ((focusX - layout.plot.left) / width).clamp(0.0, 1.0);
  final anchor = addDays(originStart, f0 * originDays);
  return (addDays(anchor, -f1 * days), days);
}

/// Dashed guide from an axis to the active dot (horizontal to the y axis,
/// vertical down to the date lanes).
class _GuideLinePainter extends CustomPainter {
  _GuideLinePainter({
    required this.from,
    required this.to,
    required this.color,
  });
  final Offset from;
  final Offset to;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    const dash = 5.0, gap = 4.0;
    final v = to - from;
    final len = v.distance;
    if (len <= 0) return;
    final dir = v / len;
    for (var d = 0.0; d < len; d += dash + gap) {
      canvas.drawLine(
        from + dir * d,
        from + dir * math.min(len, d + dash),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GuideLinePainter old) =>
      old.from != from || old.to != to || old.color != color;
}

/// A footer day's totals: [gains] and [losses] are positive magnitudes.
class PickDayStats {
  const PickDayStats({required this.gains, required this.losses, this.balance});

  final double gains;
  final double losses;
  final double? balance;
}

/// The off-range chip under the plot: only when balances in view go below
/// the vertical range. Balances above it get none (the old "▲ up to … above"
/// chip was removed).
@visibleForTesting
String? offscreenHint(BalanceExtents extents, double yMin) => extents.min < yMin
    ? '▼ down to ${formatMoneyAmount(extents.min)} below'
    : null;

/// Laid-out chart axis text reused across frames: pan and zoom repaint the
/// chart every frame and the same labels (days, months, row names) recur,
/// so laying each out again dominated paint. The cache owns its painters
/// (callers must not dispose them); least recently used ones are dropped
/// past [capacity], and everything is dropped when fonts change (a web
/// font finishing loading changes metrics).
class _TextCache {
  _TextCache(this.capacity);

  final int capacity;
  final _painters = <Object, TextPainter>{};
  bool _listening = false;

  TextPainter get(
    String text,
    TextStyle style, {
    TextScaler scaler = TextScaler.noScaling,
    int? maxLines,
    String? ellipsis,
    TextAlign align = TextAlign.start,
    double maxWidth = double.infinity,
  }) {
    if (!_listening) {
      _listening = true;
      PaintingBinding.instance.systemFonts.addListener(clear);
    }
    final key = (text, style, scaler, maxLines, ellipsis, align, maxWidth);
    final hit = _painters.remove(key);
    if (hit != null) return _painters[key] = hit;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      textAlign: align,
      maxLines: maxLines,
      ellipsis: ellipsis,
    )..layout(maxWidth: maxWidth);
    _painters[key] = painter;
    if (_painters.length > capacity) {
      _painters.remove(_painters.keys.first)!.dispose();
    }
    return painter;
  }

  void clear() {
    for (final p in _painters.values) {
      p.dispose();
    }
    _painters.clear();
  }

  @visibleForTesting
  int get length => _painters.length;
}

final _axisText = _TextCache(1500);

/// Test hook: how many axis labels are cached.
@visibleForTesting
int get debugAxisTextCacheLength => _axisText.length;
