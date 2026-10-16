import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../data/models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/money_text.dart';
import 'chart_geometry.dart';
import 'fit_ranges.dart';
import 'occurrence_info.dart';
import 'zoom_level.dart';

typedef ViewportChanged = void Function(DateTime viewStart, double visibleDays);
typedef CreateOnDay = void Function(DateTime day);

/// Step chart of closing balance with a calendar axis.
///
/// The balance (Y) range is explicit view state: fitted once when the chart
/// first shows data (or on [fitToken] change), then changed only by the
/// user. Panning or zooming time never rescales it, so a balance level keeps
/// its height on screen.
///
/// Click-drag pans time and balance. The mouse wheel and trackpad pinch zoom
/// time around the pointer; Alt+wheel zooms balance; Shift+wheel pans
/// balance. Touch: drag pans, pinch zooms time at the pinch focus.
///
/// Pressing on the date axis (month/week/day lanes) picks a date instead:
/// a bubble, guide line and day highlight follow the pointer, the view
/// auto-scrolls near the plot edges, and releasing calls [onCreateOnDay]
/// for that day. Dragging well above the axis, or Esc, cancels.
/// With focus: arrow keys pan, +/- zoom time, F fits balances.
class BalanceChart extends StatefulWidget {
  const BalanceChart({
    super.key,
    required this.series,
    required this.currency,
    required this.seedDate,
    this.seedBalance,
    this.lossThreshold = 0,
    this.fitIncludesThreshold = false,
    required this.viewStart,
    required this.visibleDays,
    required this.onViewportChanged,
    required this.onCreateOnDay,
    this.transactionNames = const {},
    this.dataFrom,
    this.dataThrough,
    this.fitToken = 0,
    this.zeroToken = 0,
    this.onFitRequested,
    this.onZoomStep,
    this.onShift,
    this.transactions = const {},
  });

  /// Transactions by id, for the occurrence hover tooltip.
  final Map<String, Transaction> transactions;

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

  /// Bumped to widen the current balance range to include 0 without a full
  /// vertical refit (Fit horizontal).
  final int zeroToken;

  /// First and last day [series] was computed for. The line is not drawn
  /// past them, so a stale series never shows a flat, made-up balance while
  /// a wider window is still loading.
  final DateTime? dataFrom;
  final DateTime? dataThrough;
  final String currency;
  final DateTime seedDate;

  /// Opening balance on [seedDate]; drawn as the initial vertex. Null: none.
  final double? seedBalance;

  /// Closing balances at or below this value are drawn as a loss.
  final double lossThreshold;

  /// Whether balance fits stretch to include the loss threshold line.
  final bool fitIncludesThreshold;
  final DateTime viewStart;
  final double visibleDays;
  final ViewportChanged onViewportChanged;
  final CreateOnDay onCreateOnDay;

  /// Occurrence transaction id to display name. Missing ids are left unlabeled.
  final Map<String, String> transactionNames;

  @override
  State<BalanceChart> createState() => _BalanceChartState();
}

class _BalanceChartState extends State<BalanceChart> {
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

  /// Date picking on the axis: the picked day, where the pointer is, and
  /// whether it was dragged far enough off the axis to cancel.
  DateTime? _pickDay;
  Offset? _pickPos;
  bool _pickCancelled = false;
  bool _pickTouch = false;
  Timer? _autoScroll;

  /// A long-press on a dot (touch) shows its tooltip instead of opening it.
  bool _longPressTip = false;

  /// Touch drag started near a dot: dragging scrubs tooltips, not the view.
  bool _scrubCandidate = false;
  double _lastScale = 1;
  final ValueNotifier<DateTime?> _hoverDay = ValueNotifier(null);

  /// Dots under the mouse (several when they overlap) and where it is.
  final ValueNotifier<_DotTip?> _hoverDots = ValueNotifier(null);

  /// Day of the hover "+" button the current press started on, if any.
  DateTime? _downOnAdd;

  /// Visible balance range; null until fitted to the first data shown.
  BalanceExtents? _yRange;

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
  static const Duration _holdDelay = Duration(milliseconds: 450);

  /// How far above the axis a pick drag goes before it counts as cancelled.
  static const double pickCancelMargin = 56;
  bool _overAdd = false;

  /// Pointer is over an occurrence dot (click opens its series).
  bool _overDot = false;
  final FocusNode _focus = FocusNode(debugLabel: 'BalanceChart');

  static const double _addButtonSize = 28;

  @override
  void didUpdateWidget(covariant BalanceChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final y = _yRange;
    if (oldWidget.zeroToken != widget.zeroToken && y != null) {
      _yRange = includeZero(y);
    }
    if (oldWidget.fitToken != widget.fitToken) {
      _yRange = null;
      _fitAwaitingData = !_dataCoversView;
    } else if (_fitAwaitingData && _dataCoversView) {
      _yRange = null;
      _fitAwaitingData = false;
    }
  }

  /// Current balance range, fitting it to the data in view the first time.
  BalanceExtents? _ensureYRange() {
    if (_yRange != null) return _yRange;
    final visible = _visible();
    if (visible == null) return null;
    // Fits always include the origin, so the zero line is in view.
    return _yRange = paddedRange(
      visible.extents.min,
      visible.extents.max,
      include: [
        0,
        if (widget.fitIncludesThreshold) widget.lossThreshold,
        if (widget.seedBalance != null && _seedInView) widget.seedBalance!,
      ],
    );
  }

  bool get _seedInView {
    final seed = dateOnly(widget.seedDate);
    final end = addDays(widget.viewStart, widget.visibleDays);
    return !seed.isBefore(dateOnly(widget.viewStart)) && seed.isBefore(end);
  }

  void _setYRange(BalanceExtents range) {
    if (!range.min.isFinite || !range.max.isFinite) return;
    setState(() => _yRange = range);
  }

  void _fitY() => setState(() => _yRange = null);

  @override
  void dispose() {
    _holdTimer?.cancel();
    _autoScroll?.cancel();
    _tapTipTimer?.cancel();
    _hoverDay.dispose();
    _hoverDots.dispose();
    _focus.dispose();
    super.dispose();
  }

  ChartLayout get _layout => ChartLayout.of(_size, widget.visibleDays);

  DateTime _dayAt(double localDx) {
    return _layout.dateAt(localDx, widget.viewStart, widget.visibleDays);
  }

  void _onPointerDown(PointerDownEvent event) {
    final touch = event.kind != PointerDeviceKind.mouse;
    if (!touch && (event.buttons & kPrimaryButton) == 0) return;
    _down[event.pointer] = event.localPosition;
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
    _hoverDots.value = null;
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
        _pickCancelled = false;
        _pickPos = event.localPosition;
        _pickDay = _dayAt(event.localPosition.dx);
      });
      return;
    }
    _mode = _Gesture.pan;
    _scrubCandidate =
        touch &&
        _nearestDot(layout, event.localPosition, touchVertexHitRadius) != null;
    if (touch) {
      // Long-press on a dot shows its tooltip (there is no hover on touch).
      _holdTimer = Timer(_holdDelay, () {
        if (!mounted || _pointer != event.pointer || _dragged || _multiTouch) {
          return;
        }
        final pos = _downPos;
        if (pos == null) return;
        final hits = _dotsAt(_layout, pos);
        if (hits.isEmpty) return;
        _longPressTip = true;
        _hoverDots.value = _DotTip(hits, hits.first.center);
      });
    }
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
    _longPressTip = false;
    _scrubCandidate = false;
    setState(() {
      _mode = _Gesture.pinch;
      _dragged = true;
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_down.containsKey(event.pointer)) return;
    _down[event.pointer] = event.localPosition;
    if (_mode == _Gesture.pinch) {
      _updatePinch();
      return;
    }
    if (event.pointer != _pointer) return;
    final origin = _downPos;
    final originStart = _originStart;
    if (origin == null || originStart == null) return;

    final dx = event.localPosition.dx - origin.dx;
    final dy = event.localPosition.dy - origin.dy;
    final slop = event.kind == PointerDeviceKind.mouse ? 4.0 : 10.0;
    if (!_dragged && dx * dx + dy * dy > slop * slop) {
      _dragged = true;
      _holdTimer?.cancel();
      if (_longPressTip) {
        _longPressTip = false;
        _hoverDots.value = null;
      }
      if (_mode == _Gesture.pan && _scrubCandidate) {
        setState(() => _mode = _Gesture.scrub);
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
    final layout = _layout;
    final cancelled = pos.dy < layout.axis.top - pickCancelMargin;
    setState(() {
      _pickPos = pos;
      _pickCancelled = cancelled;
      _pickDay = layout.dateAt(pos.dx, widget.viewStart, widget.visibleDays);
    });
    final depth = cancelled ? 0.0 : layout.edgeDepth(pos.dx);
    if (depth == 0) {
      _autoScroll?.cancel();
      _autoScroll = null;
    } else {
      _autoScroll ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _autoScrollTick(),
      );
    }
  }

  /// One auto-scroll frame while picking near (or past) a plot edge.
  void _autoScrollTick() {
    final pos = _pickPos;
    if (!mounted || _mode != _Gesture.pick || pos == null || _pickCancelled) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    final layout = _layout;
    final depth = layout.edgeDepth(pos.dx);
    if (depth == 0) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    final delta = autoScrollDays(depth, widget.visibleDays) * 0.016;
    final start = addDays(widget.viewStart, delta);
    widget.onViewportChanged(start, widget.visibleDays);
    setState(() {
      _pickDay = layout.dateAt(pos.dx, start, widget.visibleDays);
    });
  }

  void _endPick({required bool commit}) {
    _autoScroll?.cancel();
    _autoScroll = null;
    final day = _pickDay;
    final ok = commit && !_pickCancelled && day != null;
    setState(() {
      _mode = _Gesture.none;
      _pickDay = null;
      _pickPos = null;
      _pickCancelled = false;
    });
    if (ok) widget.onCreateOnDay(day);
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
    _reset();
  }

  void _reset() {
    _holdTimer?.cancel();
    _pointer = null;
    _downPos = null;
    _downOnAdd = null;
    _lastScale = 1;
    if (_longPressTip || _mode == _Gesture.scrub) _hoverDots.value = null;
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
    if (longPress) return;

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
  Timer? _tapTipTimer;
  static const Duration _tapTipDuration = Duration(seconds: 5);

  void _showTapTip(Offset pos, double hitRadius) {
    _tapTipTimer?.cancel();
    final layout = _layout;
    final nearest = layout.plot.contains(pos)
        ? _nearestDot(layout, pos, hitRadius)
        : null;
    if (nearest == null) {
      _tapTip = false;
      _hoverDots.value = null;
      return;
    }
    final group = [
      nearest,
      for (final d in _dots(layout))
        if (!identical(d, nearest) && (d.center - nearest.center).distance < 2)
          d,
    ];
    _tapTip = true;
    _hoverDots.value = _DotTip(group, nearest.center);
    _tapTipTimer = Timer(_tapTipDuration, () {
      if (!mounted || !_tapTip) return;
      _tapTip = false;
      _hoverDots.value = null;
    });
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

  void _handleScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _pointer != null) return;
    final dx = event.scrollDelta.dx;
    final dy = event.scrollDelta.dy;
    final width = _layout.plot.width;
    if (width <= 0) return;
    final keys = HardwareKeyboard.instance;
    final range = _ensureYRange();
    if (range != null && keys.isShiftPressed) {
      // Browsers often turn Shift+wheel into a horizontal delta.
      final delta = dy != 0 ? dy : dx;
      if (delta != 0) {
        _setYRange(panBalanceRange(range, -delta, _layout.plot.height));
      }
      return;
    }
    if (range != null && keys.isAltPressed && dy != 0) {
      final plot = _layout.plot;
      final fraction = plot.height <= 0
          ? 0.5
          : (plot.bottom - event.localPosition.dy) / plot.height;
      _setYRange(
        zoomBalanceRange(
          range,
          math.exp(dy.clamp(-400.0, 400.0) * 0.0016),
          fraction,
        ),
      );
      return;
    }
    if (dx.abs() > dy.abs() && dx != 0) {
      final days = dx / width * widget.visibleDays;
      widget.onViewportChanged(
        addDays(widget.viewStart, days),
        widget.visibleDays,
      );
      return;
    }
    if (dy == 0) return;
    final factor = math.exp(dy.clamp(-400.0, 400.0) * 0.0016);
    _zoomAt(event.localPosition.dx, factor);
  }

  void _handleScale(PointerSignalEvent event) {
    if (event is! PointerScaleEvent || _pointer != null) return;
    final scale = event.scale;
    if (scale <= 0) return;
    if ((scale - 1).abs() < 0.02) {
      _lastScale = 1;
      return;
    }
    final factor = _lastScale / scale;
    _lastScale = scale;
    if ((factor - 1).abs() < 0.01) return;
    _zoomAt(event.localPosition.dx, factor);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && _mode == _Gesture.pick) {
      _endPick(commit: false);
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
    final fraction = ((localDx - layout.plot.left) / width).clamp(0.0, 1.0);
    final anchor = addDays(widget.viewStart, fraction * widget.visibleDays);
    final nextDays = (widget.visibleDays * factor)
        .clamp(minVisibleDays, maxVisibleDays)
        .toDouble();
    widget.onViewportChanged(addDays(anchor, -fraction * nextDays), nextDays);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cursor = _mode == _Gesture.pick
        ? SystemMouseCursors.resizeColumn
        : _pointer != null && _dragged
        ? SystemMouseCursors.grabbing
        : _overAdd
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
          _hoverDots.value = null;
          if (_overAdd) setState(() => _overAdd = false);
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            _size = Size(constraints.maxWidth, constraints.maxHeight);
            final yRange = _ensureYRange();
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
                    child: CustomPaint(
                      painter: _BalanceChartPainter(
                        series: widget.series,
                        currency: widget.currency,
                        seedDate: widget.seedDate,
                        seedBalance: widget.seedBalance,
                        lossThreshold: widget.lossThreshold,
                        fitIncludesThreshold: widget.fitIncludesThreshold,
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
                        transactionNames: widget.transactionNames,
                        textScaler: MediaQuery.textScalerOf(context),
                        dataFrom: widget.dataFrom,
                        dataThrough: widget.dataThrough,
                        yRange: yRange,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                if (yRange != null) _yScaleControls(theme),
                if (_mode == _Gesture.pick && _pickDay != null)
                  ..._pickOverlay(theme),
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
                    if (tip == null ||
                        (_pointer != null &&
                            !_longPressTip &&
                            _mode != _Gesture.scrub)) {
                      return const SizedBox.shrink();
                    }
                    return _tooltip(theme, tip);
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Scales the balance axis by [factor] around the view's vertical centre.
  void _scaleY(double factor) {
    final range = _ensureYRange();
    if (range == null) return;
    _setYRange(zoomBalanceRange(range, factor, 0.5));
  }

  /// Compact + / − for the balance axis, at the bottom-left of the y gutter.
  Widget _yScaleControls(ThemeData theme) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final size = compact ? 44.0 : 32.0;
    final plot = _layout.plot;
    Widget button(IconData icon, String tip, double factor, Key key) =>
        SizedBox(
          width: size,
          height: size,
          child: IconButton(
            key: key,
            tooltip: tip,
            padding: EdgeInsets.zero,
            iconSize: compact ? 20 : 16,
            color: AppTheme.textMuted,
            onPressed: () => _scaleY(factor),
            icon: Icon(icon),
          ),
        );
    return Positioned(
      left: 4,
      top: plot.top + plot.height / 2 - size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xCC10151C),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x22FFFFFF)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            button(
              Icons.unfold_more_rounded,
              'Stretch balance axis',
              1 / yScaleStep,
              const ValueKey('y-scale-in'),
            ),
            button(
              Icons.unfold_less_rounded,
              'Compress balance axis',
              yScaleStep,
              const ValueKey('y-scale-out'),
            ),
          ],
        ),
      ),
    );
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
    final cancelled = _pickCancelled;
    final color = cancelled ? AppTheme.textFaint : AppTheme.accent;
    const bubbleW = 168.0, bubbleH = 52.0;
    // Above the finger on touch so it stays visible; just above the cursor
    // otherwise. Clamped inside the chart.
    final lift = _pickTouch ? 84.0 : 56.0;
    final bx = (cx - bubbleW / 2)
        .clamp(4.0, math.max(4.0, _size.width - bubbleW - 4))
        .toDouble();
    final by = (pos.dy - lift - bubbleH / 2)
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
      Positioned(
        left: cx - 1,
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
        child: IgnorePointer(
          child: Material(
            key: const ValueKey('pick-bubble'),
            elevation: 10,
            color: cancelled ? AppTheme.overlay : AppTheme.accent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatOccurrenceDate(day),
                    key: const ValueKey('pick-date'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: cancelled ? AppTheme.textMuted : AppTheme.onAccent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    cancelled ? 'Release to cancel' : 'Release to add here',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cancelled
                          ? AppTheme.textFaint
                          : AppTheme.onAccent.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ];
  }

  void _onHover(PointerHoverEvent event) {
    // Touch has no hover (browsers may synthesise one on release).
    if (event.kind == PointerDeviceKind.touch) return;
    if (_pointer != null || _multiTouch || _size == Size.zero) return;
    final pos = event.localPosition;
    final layout = _layout;
    _updateDotHover(layout, pos);
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
      widget.seedDate,
    );
    if (_visibleMemoKey != key) {
      _visibleMemoKey = key;
      _visibleMemo = visibleBalance(
        points: widget.series.points,
        viewStart: widget.viewStart,
        viewEnd: addDays(widget.viewStart, widget.visibleDays),
        seedDate: widget.seedDate,
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
    );
    if (_dotsKey == key && _dotsMemo != null) return _dotsMemo!;
    _dotsKey = key;
    final dots = <_Dot>[];
    if (range == null) return _dotsMemo = dots;
    final scale = _YScale(range.min, range.max, layout.plot);
    final seed = dateOnly(widget.seedDate);
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
    for (final g in groupByDay(widget.series.occurrences)) {
      final day = g.day;
      if (day.isBefore(seed) ||
          !addCalendarDays(day, 1).isAfter(widget.viewStart) ||
          day.isAfter(viewEnd)) {
        continue;
      }
      final close = closes[day];
      if (close == null) continue;
      final x = layout.xOf(
        addDays(day, 0.5),
        widget.viewStart,
        widget.visibleDays,
      );
      dots.add(_Dot(Offset(x, scale.yOf(close)), radius, g.all, close));
    }
    return _dotsMemo = dots;
  }

  /// Dots under [pos]: the nearest one plus any drawn on top of it.
  List<_Dot> _dotsAt(ChartLayout layout, Offset pos) {
    if (!layout.plot.inflate(6).contains(pos)) return const [];
    final hits = <_Dot>[];
    for (final dot in _dots(layout)) {
      // Forgiving: at least 9px even for tiny zoomed-out dots.
      final r = math.max(dot.radius + 5, 9.0);
      if ((dot.center - pos).distanceSquared <= r * r) hits.add(dot);
    }
    if (hits.isEmpty) return const [];
    // Several dots under the pointer: list the overlapping ones; with
    // readable stacks, take only the nearest.
    final nearest = hits.reduce(
      (a, b) =>
          (a.center - pos).distanceSquared <= (b.center - pos).distanceSquared
          ? a
          : b,
    );
    return [
      nearest,
      for (final d in hits)
        if (!identical(d, nearest) && (d.center - nearest.center).distance < 2)
          d,
    ];
  }

  /// Nearest dot to [pos] within [maxDistance], by 2D distance.
  _Dot? _nearestDot(ChartLayout layout, Offset pos, double maxDistance) {
    if (!layout.plot.inflate(maxDistance).contains(pos)) return null;
    final dots = _dots(layout)
        .where((d) => layout.plot.inflate(8).contains(d.center))
        .toList();
    final i = nearestPointIndex(
      [for (final d in dots) d.center],
      pos,
      maxDistance: maxDistance,
    );
    return i == null ? null : dots[i];
  }

  /// Touch scrub: tooltip follows the dot nearest the finger; far from all
  /// dots it keeps the last one (still following the finger).
  void _updateScrub(Offset pos) {
    final layout = _layout;
    final nearest = _nearestDot(layout, pos, scrubMaxDistance);
    final current = _hoverDots.value;
    if (nearest == null) {
      if (current != null) {
        _hoverDots.value = _DotTip(current.dots, current.anchor, finger: pos);
      }
      return;
    }
    final group = [
      nearest,
      for (final d in _dots(layout))
        if (!identical(d, nearest) && (d.center - nearest.center).distance < 2)
          d,
    ];
    _hoverDots.value = _DotTip(group, nearest.center, finger: pos);
  }

  void _updateDotHover(ChartLayout layout, Offset pos) {
    final overlapping = _dotsAt(layout, pos);
    if (overlapping.isEmpty) {
      // A tooltip pinned by a click stays until its timeout or next click.
      if (_hoverDots.value != null && !_tapTip) _hoverDots.value = null;
      if (_overDot) setState(() => _overDot = false);
      return;
    }
    if (!_overDot) setState(() => _overDot = true);
    final current = _hoverDots.value;
    if (current != null && listEquals(current.dots, overlapping)) {
      return;
    }
    _hoverDots.value = _DotTip(overlapping, overlapping.first.center);
  }

  Widget _tooltip(ThemeData theme, _DotTip tip) {
    const width = 260.0;
    // One row per transaction on the vertex's day (seed: one row).
    final entries = <(_Dot, Occurrence?)>[
      for (final d in tip.dots)
        if (d.isSeed) (d, null) else for (final o in d.occurrences) (d, o),
    ];
    const maxRows = 6;
    final shown = entries.take(maxRows).toList();
    final more = entries.length - shown.length;
    final small = theme.textTheme.bodySmall ?? const TextStyle();
    final children = <Widget>[];
    for (final (dot, o) in shown) {
      if (o == null) {
        if (children.isNotEmpty) children.add(const Divider(height: 12));
        children.add(
          Column(
            key: const ValueKey('seed-tooltip'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Opening balance',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    formatMoneyAmount(dot.balanceAfter, widget.currency),
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppTheme.accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(formatOccurrenceDate(widget.seedDate), style: small),
            ],
          ),
        );
        continue;
      }
      final t = widget.transactions[o.transactionId];
      final rawName = t?.name ?? widget.transactionNames[o.transactionId];
      final name = rawName == null || rawName.trim().isEmpty
          ? 'Transaction'
          : rawName.trim();
      final amount = o.signedDelta.toDouble();
      final debit = amount < 0;
      final status = [
        if (o.skipped) 'Skipped',
        if (t != null && !t.enabled) 'Disabled',
      ];
      if (children.isNotEmpty) children.add(const Divider(height: 12));
      children.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatSignedAmount(amount, widget.currency),
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: o.skipped
                        ? AppTheme.textFaint
                        : (debit ? AppTheme.debitColor : AppTheme.creditColor),
                    decoration: o.skipped ? TextDecoration.lineThrough : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(formatOccurrenceDate(o.date), style: small),
            if (t != null)
              Text(
                [
                  describeRecurrence(t),
                  ?occurrenceOrdinal(t, o.date),
                ].join(' · '),
                style: small,
              ),
            if (status.isNotEmpty)
              Text(
                status.join(' · '),
                style: small.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.warning,
                ),
              ),
          ],
        ),
      );
    }
    if (more > 0) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('+$more more on this day', style: small),
        ),
      );
    }
    // Net for the day (2+ counted) and the end-of-day balance.
    final day = tip.dots.firstWhere(
      (d) => !d.isSeed,
      orElse: () => tip.dots.first,
    );
    var extra = 0.0;
    if (!day.isSeed) {
      final g = DayGroup(dateOnly(day.occurrences.first.date), day.occurrences);
      children.add(const Divider(height: 12));
      if (day.occurrences.length >= 2) {
        extra += 22;
        children.add(
          Row(
            key: const ValueKey('day-net'),
            children: [
              Expanded(
                child: Text(
                  'Net · ${g.count} transaction${g.count == 1 ? '' : 's'}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                formatSignedAmount(g.net, widget.currency),
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: g.allSkipped
                      ? AppTheme.textFaint
                      : (g.net < 0
                            ? AppTheme.debitColor
                            : AppTheme.creditColor),
                ),
              ),
            ],
          ),
        );
      }
      extra += 22;
      children.add(
        Text(
          'Balance end of day: ${formatMoneyAmount(day.balanceAfter, widget.currency)}',
          style: small.copyWith(color: AppTheme.textFaint),
        ),
      );
    }
    final estHeight = 30.0 + shown.length * 66.0 + (more > 0 ? 20 : 0) + extra;
    // Right of the dot, flipping left / up near the edges.
    var left = tip.anchor.dx + 14;
    if (left + width > _size.width - 4) left = tip.anchor.dx - 14 - width;
    left = _clampEdge(left, 4, _size.width - width - 4);
    var top = tip.anchor.dy - 20;
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
    final ring = tip.dots.first.radius + 5;
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            // Highlight ring on the hovered dot.
            Positioned(
              left: tip.anchor.dx - ring,
              top: tip.anchor.dy - ring,
              width: ring * 2,
              height: ring * 2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.accent.withValues(alpha: 0.18),
                  border: Border.all(color: AppTheme.accent, width: 1.5),
                ),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: width,
              child: _tooltipCard(theme, children),
            ),
          ],
        ),
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
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
    final label = 'New transaction on ${formatDate(day)}';
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

class ChartLayout {
  const ChartLayout({
    required this.plot,
    required this.monthBand,
    required this.weekBand,
    required this.dayBand,
    required this.showWeekLane,
    required this.showDayLane,
    required this.showDayLabels,
    required this.showDayText,
  });

  final Rect plot;
  final Rect monthBand;
  final Rect? weekBand;
  final Rect? dayBand;
  final bool showWeekLane;
  final bool showDayLane;
  final bool showDayLabels;

  /// Whether the day lane carries text (see [dayLabelPlan]).
  final bool showDayText;

  static const double gutter = 112;
  static const double right = 12;
  static const double top = 8;

  static ChartLayout of(Size size, double visibleDays) {
    final plotWidth = math.max(1.0, size.width - gutter - right);
    final dayPx = plotWidth / math.max(visibleDays, 0.001);
    final showDayLabels = dayPx >= 12;
    // Day text (thinned when narrow) shows from 6px/day.
    final showDayText = dayPx >= 6;
    final showDayLane = dayPx >= 3;
    final showWeekLane = dayPx * 7 >= 14;
    const monthH = 26.0;
    final weekH = showWeekLane ? 20.0 : 0.0;
    final dayH = !showDayLane ? 0.0 : (showDayText ? dayLaneLabelHeight : 14.0);
    final axisH = monthH + weekH + dayH;
    final plot = Rect.fromLTWH(
      gutter,
      top,
      plotWidth,
      math.max(1, size.height - top - axisH),
    );
    var y = plot.bottom;
    final monthBand = Rect.fromLTWH(plot.left, y, plot.width, monthH);
    y += monthH;
    final weekBand = showWeekLane
        ? Rect.fromLTWH(plot.left, y, plot.width, weekH)
        : null;
    y += weekH;
    final dayBand = showDayLane
        ? Rect.fromLTWH(plot.left, y, plot.width, dayH)
        : null;
    return ChartLayout(
      plot: plot,
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

  /// How far [x] is inside the auto-scroll zone at either plot edge:
  /// negative toward the left edge, positive toward the right, 0 inside.
  double edgeDepth(double x, {double zone = 40}) {
    if (x < plot.left + zone) return -(plot.left + zone - x);
    if (x > plot.right - zone) return x - (plot.right - zone);
    return 0;
  }

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
const _gridColor = Color(0xFF243040);

Color _yearColor(int index) =>
    index.isEven ? const Color(0xFF24476B) : const Color(0xFF1D5A55);

Color _monthColor(int month) => _monthColors[(month - 1).clamp(0, 11)];

Color _weekColor(int index) => _weekColors[index.clamp(0, 3)];

Color _dayColor(int weekday) => _dayColors[(weekday - 1).clamp(0, 6)];

class _BalanceChartPainter extends CustomPainter {
  _BalanceChartPainter({
    required this.series,
    required this.currency,
    required this.seedDate,
    this.seedBalance,
    required this.lossThreshold,
    this.fitIncludesThreshold = false,
    required this.viewStart,
    required this.visibleDays,
    required this.labelStyle,
    required this.strongStyle,
    required this.laneStyle,
    required this.transactionNames,
    required this.textScaler,
    this.dataFrom,
    this.dataThrough,
    this.yRange,
  });

  /// Balance range shown top to bottom. Null falls back to fitting the view.
  final BalanceExtents? yRange;
  final DateTime? dataFrom;
  final DateTime? dataThrough;
  final BalanceSeries series;
  final String currency;
  final DateTime seedDate;

  /// Opening balance on [seedDate]; drawn as the initial vertex. Null: none.
  final double? seedBalance;
  final bool fitIncludesThreshold;
  final double lossThreshold;
  final DateTime viewStart;
  final double visibleDays;
  final TextStyle labelStyle;
  final TextStyle strongStyle;
  final TextStyle laneStyle;
  final Map<String, String> transactionNames;
  final TextScaler textScaler;

  DateTime get _viewEnd => addDays(viewStart, visibleDays);

  @override
  void paint(Canvas canvas, Size size) {
    final layout = ChartLayout.of(size, visibleDays);
    final seed = dateOnly(seedDate);
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
        yRange ??
        paddedRange(
          visible.extents.min,
          visible.extents.max,
          include: fitIncludesThreshold ? [lossThreshold] : const [],
        );
    final scale = _YScale(range.min, range.max, layout.plot);
    // Min / max markers refer to the whole loaded series (from the seed),
    // drawn at their absolute heights; not just what is in view.
    final global = balanceExtentsFrom(series.points, seed) ?? visible.extents;
    _paintGrid(canvas, layout, scale, global);
    _paintMarkers(canvas, layout, viewEnd, seed);
    _paintSeries(canvas, layout, scale, visible, seed, viewEnd);
    _paintOccurrences(canvas, layout, scale, viewEnd, seed);
    _paintYLabels(canvas, layout, scale, global);
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
    if (useYearLane(layout.plot.width, visibleDays)) {
      _paintLane(
        canvas,
        layout,
        layout.monthBand,
        yearSegments(viewStart, viewEnd),
        viewEnd,
        (segment, width) => width >= 30
            ? '${segment.start.year}'
            : width >= 18
            ? "'${'${segment.start.year % 100}'.padLeft(2, '0')}"
            : '',
        (segment) => _yearColor(segment.colorIndex),
        Colors.white,
        'Year',
      );
    } else {
      _paintMonthLane(canvas, layout, viewEnd);
    }
    _paintRestOfAxes(canvas, layout, viewEnd);
  }

  void _paintMonthLane(Canvas canvas, ChartLayout layout, DateTime viewEnd) {
    final months = monthSegments(viewStart, viewEnd);
    final firstVisible = months.isEmpty ? null : months.first.start;
    // Year on January and on the first visible month, so the axis alone
    // says which year you are looking at.
    String withYear(AxisSegment segment, String text, String year) =>
        segment.start.month == 1 || segment.start == firstVisible
        ? '$text $year'
        : text;
    _paintLane(
      canvas,
      layout,
      layout.monthBand,
      months,
      viewEnd,
      (segment, width) {
        final year = '${segment.start.year}';
        if (width >= 130) {
          return withYear(
            segment,
            DateFormat.MMMM().format(segment.start),
            year,
          );
        }
        if (width >= 72) {
          return withYear(
            segment,
            DateFormat.MMM().format(segment.start),
            year,
          );
        }
        if (width >= 40) {
          final short = "'${'${segment.start.year % 100}'.padLeft(2, '0')}";
          return withYear(
            segment,
            DateFormat.MMM().format(segment.start),
            short,
          );
        }
        if (width >= 14) {
          return DateFormat.MMM().format(segment.start).substring(0, 1);
        }
        return '';
      },
      (segment) => _monthColor(segment.colorIndex),
      Colors.white,
      'Month',
    );
  }

  void _paintRestOfAxes(Canvas canvas, ChartLayout layout, DateTime viewEnd) {
    final weekBand = layout.weekBand;
    if (weekBand != null) {
      _paintLane(
        canvas,
        layout,
        weekBand,
        weekSegments(viewStart, viewEnd),
        viewEnd,
        (segment, width) {
          if (width >= 72) return DateFormat.MMMd().format(segment.start);
          if (width >= 28) return '${segment.start.day}';
          return '';
        },
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
        daySegments(viewStart, viewEnd),
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
    double w(String t, TextStyle st) {
      final tp = TextPainter(
        text: TextSpan(text: t, style: st),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      final width = tp.width;
      tp.dispose();
      return width;
    }

    final cell = layout.plot.width / visibleDays;
    final plan = dayLabelPlan(
      cellWidth: cell,
      fullWidth: math.max(w('Wed', dowStyle), w('28th', numStyle)),
      compactWidth: math.max(w('W', dowStyle), w('28', numStyle)),
      numeralWidth: w('28', numStyle),
    );
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
      final painters = [
        for (final (t, st) in lines)
          TextPainter(
            text: TextSpan(text: t, style: st),
            textDirection: TextDirection.ltr,
            textScaler: textScaler,
            maxLines: 1,
          )..layout(),
      ];
      final total = painters.fold<double>(0, (a, p) => a + p.height);
      var y = band.top + (band.height - total) / 2;
      for (final p in painters) {
        p.paint(canvas, Offset(cx - p.width / 2, y));
        y += p.height;
        p.dispose();
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
      final label = labelFor(segment, rect.width);
      if (label.isEmpty) continue;
      final style = laneStyle.copyWith(color: textColor, height: 1.05);
      _paintCentered(canvas, rect.deflate(1), label, style);
    }
    canvas.restore();
    final nameTp = TextPainter(
      text: TextSpan(
        text: laneName,
        style: labelStyle.copyWith(fontSize: 10, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout(maxWidth: math.max(0, layout.plot.left - 8));
    nameTp.paint(
      canvas,
      Offset(
        layout.plot.left - 6 - nameTp.width,
        band.top + (band.height - nameTp.height) / 2,
      ),
    );
  }

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

  void _paintGrid(
    Canvas canvas,
    ChartLayout layout,
    _YScale scale,
    BalanceExtents extents,
  ) {
    final grid = Paint()
      ..color = _gridColor
      ..strokeWidth = 1;
    final digits = moneyDigitsForSpan(extents.min, extents.max);
    // Off-plot extents are labelled pinned to the plot edge, so keep
    // gridline labels clear of where that pinned label sits.
    double pinned(double y) => y < layout.plot.top
        ? layout.plot.top + 7
        : y > layout.plot.bottom
        ? layout.plot.bottom - 7
        : y;
    final minY = pinned(scale.yOf(extents.min));
    final maxY = pinned(scale.yOf(extents.max));
    for (final value in niceGridlines(scale.yMin, scale.yMax)) {
      if (value.abs() < 1e-9) continue;
      final y = scale.yOf(value);
      if ((y - minY).abs() < 22 || (y - maxY).abs() < 22) continue;
      canvas.drawLine(
        Offset(layout.plot.left, y),
        Offset(layout.plot.right, y),
        grid,
      );
      _paintYText(
        canvas,
        layout,
        y,
        _axisMoney(value, currency, digits, _absMax(extents)),
        labelStyle,
      );
    }

    if (scale.yMin < 0 && scale.yMax > 0) {
      final y = scale.yOf(0);
      canvas.drawLine(
        Offset(layout.plot.left, y),
        Offset(layout.plot.right, y),
        Paint()
          ..color = const Color(0xFF4A5868)
          ..strokeWidth = 1,
      );
      if ((y - minY).abs() >= 22 && (y - maxY).abs() >= 22) {
        _paintYText(
          canvas,
          layout,
          y,
          _axisMoney(0, currency, digits, _absMax(extents)),
          labelStyle,
        );
      }
    }

    final extentPaint = Paint()
      ..color = AppTheme.accent.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    bool onPlot(double y) => y >= layout.plot.top && y <= layout.plot.bottom;
    final rawMaxY = scale.yOf(extents.max);
    final rawMinY = scale.yOf(extents.min);
    if (onPlot(rawMaxY)) {
      canvas.drawLine(
        Offset(layout.plot.left, rawMaxY),
        Offset(layout.plot.right, rawMaxY),
        extentPaint,
      );
    }
    if (!extents.isFlat && onPlot(rawMinY)) {
      canvas.drawLine(
        Offset(layout.plot.left, rawMinY),
        Offset(layout.plot.right, rawMinY),
        extentPaint,
      );
    }
  }

  void _paintYLabels(
    Canvas canvas,
    ChartLayout layout,
    _YScale scale,
    BalanceExtents extents,
  ) {
    final digits = moneyDigitsForSpan(extents.min, extents.max);
    final maxLabel =
        'max ${_axisMoney(extents.max, currency, digits, _absMax(extents))}';
    final maxY = scale.yOf(extents.max);
    bool onPlot(double y) => y >= layout.plot.top && y <= layout.plot.bottom;
    if (extents.isFlat) {
      if (onPlot(maxY)) {
        _paintYText(
          canvas,
          layout,
          maxY,
          maxLabel,
          strongStyle,
          emphasize: true,
        );
      }
      return;
    }
    final minLabel =
        'min ${_axisMoney(extents.min, currency, digits, _absMax(extents))}';
    final minY = scale.yOf(extents.min);
    // Off-plot extents get a faint label pinned to that edge with an arrow
    // (it points at the absolute height rather than claiming the edge).
    if (!onPlot(maxY) || !onPlot(minY)) {
      if (!onPlot(maxY)) {
        _paintYText(
          canvas,
          layout,
          maxY < layout.plot.top ? layout.plot.top : layout.plot.bottom,
          '${maxY < layout.plot.top ? '▲' : '▼'} $maxLabel',
          labelStyle,
        );
      }
      if (!onPlot(minY)) {
        _paintYText(
          canvas,
          layout,
          minY > layout.plot.bottom ? layout.plot.bottom : layout.plot.top,
          '${minY > layout.plot.bottom ? '▼' : '▲'} $minLabel',
          labelStyle,
        );
      }
      if (onPlot(maxY)) {
        _paintYText(
          canvas,
          layout,
          maxY,
          maxLabel,
          strongStyle,
          emphasize: true,
        );
      }
      if (onPlot(minY)) {
        _paintYText(
          canvas,
          layout,
          minY,
          minLabel,
          strongStyle,
          emphasize: true,
        );
      }
      return;
    }
    if ((maxY - minY).abs() < 28) {
      _paintYText(
        canvas,
        layout,
        layout.plot.top + 8,
        maxLabel,
        strongStyle,
        emphasize: true,
      );
      _paintYText(
        canvas,
        layout,
        layout.plot.bottom - 8,
        minLabel,
        strongStyle,
        emphasize: true,
      );
      return;
    }
    _paintYText(canvas, layout, maxY, maxLabel, strongStyle, emphasize: true);
    _paintYText(canvas, layout, minY, minLabel, strongStyle, emphasize: true);
  }

  void _paintYText(
    Canvas canvas,
    ChartLayout layout,
    double y,
    String text,
    TextStyle style, {
    bool emphasize = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: ChartLayout.gutter - 10);
    final minTop = layout.plot.top;
    final maxTop = math.max(minTop, layout.plot.bottom - painter.height);
    final top = (y - painter.height / 2).clamp(minTop, maxTop).toDouble();
    final left = ChartLayout.gutter - 8 - painter.width;
    if (emphasize) {
      final bg = RRect.fromRectAndRadius(
        Rect.fromLTWH(left - 3, top - 1, painter.width + 6, painter.height + 2),
        const Radius.circular(4),
      );
      canvas.drawRRect(bg, Paint()..color = AppTheme.raised);
    }
    painter.paint(canvas, Offset(left, top));
    painter.dispose();
  }

  void _paintMarkers(
    Canvas canvas,
    ChartLayout layout,
    DateTime viewEnd,
    DateTime seed,
  ) {
    _paintVertical(
      canvas,
      layout,
      DateTime.now(),
      viewEnd,
      color: AppTheme.mint.withValues(alpha: 0.9),
      label: 'Today',
      labelColor: AppTheme.mint,
      dashed: true,
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
      alignLeft: true,
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
  }) {
    final next = addCalendarDays(date, 1);
    if (!next.isAfter(viewStart) || dateOnly(date).isAfter(viewEnd)) return;
    final x = layout.xOf(date, viewStart, visibleDays);
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
    final lossFill = gradientFill(AppTheme.debitColor);
    for (final plateau in plateaus) {
      if (plateau.x1 <= plateau.x0) continue;
      final y = scale.yOf(plateau.value);
      final fill = Path()
        ..moveTo(plateau.x0, y)
        ..lineTo(plateau.x1, y)
        ..lineTo(plateau.x1, layout.plot.bottom)
        ..lineTo(plateau.x0, layout.plot.bottom)
        ..close();
      canvas.drawPath(fill, _isLoss(plateau.value) ? lossFill : areaFill);
    }

    final thresholdY = scale.yOf(lossThreshold);
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
          text: 'Alert ≤ ${formatMoneyAmount(lossThreshold, currency)}',
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
          ..strokeWidth = 2.4
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

  bool _isLoss(double value) => value <= lossThreshold;

  /// Chips at the top / bottom edge when balances in view lie beyond the
  /// vertical range, so clipped data is noticed (drag or Shift+wheel to it).
  void _paintOffscreenHints(
    Canvas canvas,
    ChartLayout layout,
    _YScale scale,
    BalanceExtents extents,
  ) {
    void chip(String text, bool top) {
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
      final y = top ? layout.plot.top + 4 : layout.plot.bottom - h - 4;
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

    if (extents.max > scale.yMax) {
      chip('▲ up to ${formatMoneyAmount(extents.max, currency)} above', true);
    }
    if (extents.min < scale.yMin) {
      chip(
        '▼ down to ${formatMoneyAmount(extents.min, currency)} below',
        false,
      );
    }
  }

  double _absMax(BalanceExtents extents) =>
      math.max(extents.min.abs(), extents.max.abs());

  /// Where a day's balance change is drawn: the middle of its day cell, so
  /// the step and its dots sit inside the labelled day instead of on the
  /// boundary shared with the previous day.
  DateTime _stepAt(DateTime date) => addDays(dateOnly(date), 0.5);

  void _paintOccurrences(
    Canvas canvas,
    ChartLayout layout,
    _YScale scale,
    DateTime viewEnd,
    DateTime seed,
  ) {
    final closes = <int, double>{};
    for (final point in series.points) {
      final day = dateOnly(point.date);
      if (day.isBefore(seed)) continue;
      closes[day.millisecondsSinceEpoch] = point.closingBalance.toDouble();
    }
    final dayPx = layout.plot.width / math.max(visibleDays, 0.001);
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
      if (day.isBefore(seed) ||
          !nextDay.isAfter(viewStart) ||
          day.isAfter(viewEnd)) {
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
      final String name;
      if (g.all.length == 1) {
        final rawName = transactionNames[g.all.first.transactionId];
        name = rawName == null
            ? ''
            : (rawName.trim().isEmpty ? 'Transaction' : rawName.trim());
      } else {
        name = '';
      }
      vertices.add(
        _ChartVertex(
          center: center,
          radius: radius + (g.count >= 2 ? 3 : 0),
          name: name,
          amount: net,
          skipped: g.allSkipped,
          debit: net < 0,
          count: g.count,
        ),
      );
    }
    final seedBal = seedBalance;
    if (seedBal != null) {
      final c = Offset(
        layout.xOf(seed, viewStart, visibleDays),
        scale.yOf(seedBal),
      );
      if (layout.plot.inflate(2).contains(c)) {
        _paintSeedVertex(canvas, c, seedVertexRadius(radius));
        vertices.add(
          _ChartVertex(
            center: c,
            radius: seedVertexRadius(radius),
            name: 'Opening',
            amount: seedBal,
            skipped: false,
            debit: false,
            seed: true,
          ),
        );
      }
    }
    canvas.restore();
    _paintVertexLabels(canvas, layout, vertices);
  }

  /// Opening-balance vertex: a hollow accent diamond, unlike the round
  /// transaction dots.
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

  /// Transaction names beside each occurrence dot. Width follows the free gap and
  /// the zoom, and a name is omitted when another readable label owns the spot.
  void _paintVertexLabels(
    Canvas canvas,
    ChartLayout layout,
    List<_ChartVertex> vertices,
  ) {
    if (vertices.isEmpty) return;
    final plot = layout.plot;
    final dayPx = plot.width / math.max(visibleDays, 0.001);
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
    final maxText = math.min(densityCap, plot.width * 0.34);
    const minText = 18.0;
    const pad = 10.0;
    if (maxText < minText) return;

    vertices.sort((a, b) {
      final byX = a.center.dx.compareTo(b.center.dx);
      if (byX != 0) return byX;
      return b.center.dy.compareTo(a.center.dy);
    });
    final anchors = [for (final vertex in vertices) vertex.center];
    final style = labelStyle.copyWith(
      fontSize: fontSize,
      height: 1.0,
      fontWeight: FontWeight.w600,
      color: AppTheme.text,
    );
    final probe = TextPainter(
      text: TextSpan(text: 'Mg', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelHeight = probe.height * 2 + 4;
    probe.dispose();

    final placed = <Rect>[..._markerLabelRects(layout)];
    final labeledAt = <Offset>[];
    final neighborGap = dayPx >= 4.5 ? 10.0 : 30.0;
    for (final vertex in vertices) {
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
      final amount = TextPainter(
        text: TextSpan(
          text: vertex.seed
              ? formatMoneyAmount(vertex.amount, currency)
              : formatSignedAmount(vertex.amount, currency),
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

      // Count chip (2+ on the day) sits left of the text, a touch larger
      // than the amount so it reads first.
      final count = vertex.count >= 2
          ? (TextPainter(
              text: TextSpan(
                text: vertex.count > 99 ? '99+' : '${vertex.count}',
                style: vertexStyle.copyWith(
                  fontSize: (vertexStyle.fontSize ?? 11) + 1.5,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  color: AppTheme.text,
                ),
              ),
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout())
          : null;
      final pillW = count == null ? 0.0 : countPillWidth(count.width) + 4;

      TextPainter? layoutName(double maxWidth) {
        if (vertex.name.isEmpty || maxWidth < 16) return null;
        final painter = TextPainter(
          text: TextSpan(text: vertex.name, style: vertexStyle),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: maxWidth);
        final readable = painter.didExceedMaxLines
            ? painter.width >= 16
            : painter.width >= 4;
        if (!readable) {
          painter.dispose();
          return null;
        }
        return painter;
      }

      double widthFor(TextPainter? name) =>
          math.max(amount.width, name?.width ?? 0) + pad + pillW;
      double heightFor(TextPainter? name) =>
          math.max(
            amount.height + (name?.height ?? 0),
            count == null ? 0.0 : count.height + 2,
          ) +
          4;

      // Prefer a label with the transaction name; fall back to the amount alone.
      var drawn = false;
      for (final withName in vertex.name.isEmpty ? [false] : [true, false]) {
        for (final side in VertexLabelSide.values) {
          final budget = vertexLabelTextBudget(
            plot: plot,
            center: vertex.center,
            radius: vertex.radius,
            side: side,
            labelHeight: labelHeight,
            maxText: maxText,
            minText: minText,
            pad: pad,
            occupied: placed,
            anchors: anchors,
          );
          if (budget <= 0 || budget - pillW < amount.width) continue;
          var name = withName ? layoutName(budget - pillW) : null;
          if (withName && name == null) continue;
          var rect = vertexLabelRect(
            center: vertex.center,
            radius: vertex.radius,
            side: side,
            width: widthFor(name),
            height: heightFor(name),
          );
          if (!vertexLabelFits(
            rect: rect,
            plot: plot,
            anchor: vertex.center,
            radius: vertex.radius,
            occupied: placed,
            anchors: anchors,
          )) {
            final nudged = nudgeVertexLabel(
              rect: rect,
              plot: plot,
              anchor: vertex.center,
              radius: vertex.radius,
              occupied: placed,
              anchors: anchors,
            );
            if (nudged == null) {
              name?.dispose();
              continue;
            }
            name?.dispose();
            name = withName
                ? layoutName(math.max(amount.width, nudged.width - pad - pillW))
                : null;
            if (withName && name == null) continue;
            rect = Rect.fromLTWH(
              nudged.left,
              nudged.top,
              widthFor(name),
              heightFor(name),
            );
            if (!vertexLabelFits(
              rect: rect,
              plot: plot,
              anchor: vertex.center,
              radius: vertex.radius,
              occupied: placed,
              anchors: anchors,
              attachReach: 96,
            )) {
              name?.dispose();
              continue;
            }
          }
          _drawVertexLabel(canvas, amount, name, rect, vertex, count);
          name?.dispose();
          placed.add(rect);
          labeledAt.add(vertex.center);
          drawn = true;
          break;
        }
        if (drawn) break;
      }
      amount.dispose();
      count?.dispose();
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

    add(DateTime.now(), 'Today');
    add(seedDate, 'Seed', alignLeft: true);
    return rects;
  }

  void _drawVertexLabel(
    Canvas canvas,
    TextPainter amount,
    TextPainter? name,
    Rect rect,
    _ChartVertex vertex, [
    TextPainter? count,
  ]) {
    final leader = labelLeader(rect, vertex.center, vertex.radius);
    if (leader != null) {
      final color = vertex.skipped
          ? AppTheme.textFaint
          : vertex.seed
          ? AppTheme.accent
          : vertex.debit
          ? AppTheme.debitColor
          : AppTheme.creditColor;
      canvas.drawLine(
        leader.$1,
        leader.$2,
        Paint()
          ..color = color.withValues(alpha: 0.7)
          ..strokeWidth =
              2.5 // matches the label's accent bar width
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
    }
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
    final accent = vertex.skipped
        ? AppTheme.textFaint
        : vertex.debit
        ? AppTheme.debitColor
        : AppTheme.creditColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(rect.left + 1.5, rect.top + 2, 2.5, rect.height - 4),
        const Radius.circular(1),
      ),
      Paint()..color = accent,
    );
    var textLeft = rect.left + 6;
    if (count != null) {
      final w = countPillWidth(count.width);
      final h = count.height + 2;
      final pill = Rect.fromLTWH(textLeft, rect.center.dy - h / 2, w, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(pill, Radius.circular(h / 2)),
        Paint()..color = accent.withValues(alpha: 0.28),
      );
      count.paint(
        canvas,
        Offset(
          pill.center.dx - count.width / 2,
          pill.center.dy - count.height / 2,
        ),
      );
      textLeft += w + 4;
    }
    final textTop = rect.center.dy - (amount.height + (name?.height ?? 0)) / 2;
    amount.paint(canvas, Offset(textLeft, textTop));
    name?.paint(canvas, Offset(textLeft, textTop + amount.height));
  }

  void _paintCentered(Canvas canvas, Rect rect, String text, TextStyle style) {
    if (rect.width < 8 || rect.height < 8 || text.isEmpty) return;
    final maxLines = text.contains('\n') ? 2 : 1;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: maxLines,
      ellipsis: maxLines == 1 ? '…' : null,
    )..layout(maxWidth: math.max(1, rect.width - 2));
    if (painter.height > rect.height + 1) {
      painter.dispose();
      return;
    }
    painter.paint(
      canvas,
      Offset(
        rect.center.dx - painter.width / 2,
        rect.center.dy - painter.height / 2,
      ),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant _BalanceChartPainter oldDelegate) {
    return oldDelegate.series != series ||
        oldDelegate.currency != currency ||
        oldDelegate.seedDate != seedDate ||
        oldDelegate.seedBalance != seedBalance ||
        oldDelegate.lossThreshold != lossThreshold ||
        oldDelegate.fitIncludesThreshold != fitIncludesThreshold ||
        oldDelegate.viewStart != viewStart ||
        oldDelegate.visibleDays != visibleDays ||
        oldDelegate.labelStyle != labelStyle ||
        oldDelegate.strongStyle != strongStyle ||
        oldDelegate.laneStyle != laneStyle ||
        oldDelegate.textScaler != textScaler ||
        oldDelegate.dataFrom != dataFrom ||
        oldDelegate.yRange?.min != yRange?.min ||
        oldDelegate.yRange?.max != yRange?.max ||
        oldDelegate.dataThrough != dataThrough ||
        !mapEquals(oldDelegate.transactionNames, transactionNames);
  }
}

/// Y-axis money: compact (A\$1.5M) once values reach millions so labels
/// fit the gutter instead of being cut off.
String _axisMoney(double value, String currency, int digits, double scaleMax) {
  // Six-figure labels no longer fit the axis gutter ("max A$556,123"):
  // switch to compact (A$556.1K, A$1.25M).
  if (scaleMax >= 1e5 && value.abs() >= 1e5) {
    return NumberFormat.compactCurrency(
      name: currency,
      symbol: MoneyText.symbolFor(currency),
      decimalDigits: value.abs() >= 1e6 ? 2 : 1,
    ).format(value);
  }
  return formatMoneyAmount(
    value,
    currency,
    decimalDigits: scaleMax >= 1e6 ? 0 : digits,
  );
}

class _ChartVertex {
  const _ChartVertex({
    required this.center,
    required this.radius,
    required this.name,
    required this.amount,
    required this.skipped,
    required this.debit,
    this.seed = false,
    this.count = 1,
  });

  /// Occurrences grouped on this vertex (label shows "· N" when 2+).
  final int count;

  /// The opening-balance vertex: amount unsigned, in the accent colour.
  final bool seed;

  final Offset center;
  final double radius;

  /// Empty when the transaction has no known name; the amount is still shown.
  final String name;

  /// This occurrence's own signed amount (+ credit, − debit). Shown even
  /// when skipped (greyed); the running balance is read off the axis.
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
  const _Dot(this.center, this.radius, this.occurrences, this.balanceAfter);
  final Offset center;
  final double radius;

  /// Every occurrence on this vertex's day; empty for the opening-balance
  /// (seed) vertex.
  final List<Occurrence> occurrences;

  Occurrence? get occurrence => occurrences.isEmpty ? null : occurrences.first;

  bool get isSeed => occurrences.isEmpty;

  /// Account balance right after this occurrence applied.
  final double balanceAfter;
}

class _DotTip {
  const _DotTip(this.dots, this.anchor, {this.finger});
  final List<_Dot> dots;
  final Offset anchor;

  /// Touch scrub: where the finger is, so the card sits clear of it.
  final Offset? finger;
}

enum _Gesture { none, pan, pick, pinch, scrub }

/// Auto-scroll speed in days per second for a pointer [depth] px into (or
/// past) an edge zone; negative scrolls back in time. Scales with depth and
/// the visible span, capped so it stays controllable.
double autoScrollDays(double depth, double visibleDays) {
  final strength = (depth.abs() / 40).clamp(0.0, 3.0);
  return depth.sign * visibleDays * 0.5 * strength;
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
