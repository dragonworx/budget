import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../data/models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/money_text.dart';
import 'chart_geometry.dart';
import 'zoom_level.dart';

typedef DayTap = void Function(DateTime day, List<Occurrence> onDay);
typedef RangeSelect = void Function(DateTime start, DateTime end);
typedef ViewportChanged = void Function(DateTime viewStart, double visibleDays);
typedef CreateOnDay = void Function(DateTime day);

/// Step chart of closing balance with a calendar axis.
///
/// Click-drag pans. The mouse wheel and trackpad pinch zoom around the
/// pointer. Long-press then drag selects a date range.
class BalanceChart extends StatefulWidget {
  const BalanceChart({
    super.key,
    required this.series,
    required this.currency,
    required this.seedDate,
    this.lossThreshold = 0,
    required this.viewStart,
    required this.visibleDays,
    required this.onViewportChanged,
    required this.onDayTap,
    required this.onRangeSelected,
    required this.onCreateOnDay,
    this.transactionNames = const {},
  });

  final BalanceSeries series;
  final String currency;
  final DateTime seedDate;

  /// Closing balances at or below this value are drawn as a loss.
  final double lossThreshold;
  final DateTime viewStart;
  final double visibleDays;
  final ViewportChanged onViewportChanged;
  final DayTap onDayTap;
  final RangeSelect onRangeSelected;
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
  bool _selecting = false;
  DateTime? _selectAnchor;
  DateTime? _selectEnd;
  Timer? _holdTimer;
  double _lastScale = 1;
  final ValueNotifier<DateTime?> _hoverDay = ValueNotifier(null);

  static const double _addButtonSize = 36;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _hoverDay.dispose();
    super.dispose();
  }

  ChartLayout get _layout => ChartLayout.of(_size, widget.visibleDays);

  DateTime _dayAt(double localDx) {
    return _layout.dateAt(localDx, widget.viewStart, widget.visibleDays);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null) return;
    if ((event.buttons & kPrimaryButton) == 0) return;
    _pointer = event.pointer;
    _downPos = event.localPosition;
    _hoverDay.value = null;
    _originStart = widget.viewStart;
    _originDays = widget.visibleDays;
    _dragged = false;
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted || _pointer != event.pointer || _downPos == null) return;
      final day = _dayAt(_downPos!.dx);
      setState(() {
        _selecting = true;
        _selectAnchor = day;
        _selectEnd = day;
      });
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final origin = _downPos;
    final originStart = _originStart;
    if (origin == null || originStart == null) return;

    final dx = event.localPosition.dx - origin.dx;
    final dy = event.localPosition.dy - origin.dy;
    if (!_dragged && dx * dx + dy * dy > 16) {
      _dragged = true;
      if (!_selecting) _holdTimer?.cancel();
    }

    if (_selecting) {
      setState(() => _selectEnd = _dayAt(event.localPosition.dx));
      return;
    }
    if (!_dragged) return;

    final width = _layout.plot.width;
    if (width <= 0) return;
    final days = -dx / width * _originDays;
    widget.onViewportChanged(addDays(originStart, days), _originDays);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _finishPointer(event.localPosition);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _holdTimer?.cancel();
    _pointer = null;
    _downPos = null;
    _lastScale = 1;
    if (_selecting || _dragged) {
      setState(() {
        _selecting = false;
        _selectAnchor = null;
        _selectEnd = null;
        _dragged = false;
      });
    }
  }

  void _finishPointer(Offset localPosition) {
    _holdTimer?.cancel();
    final selecting = _selecting;
    final dragged = _dragged;
    var anchor = _selectAnchor;
    var end = _selectEnd;
    _pointer = null;
    _downPos = null;
    _lastScale = 1;
    setState(() {
      _selecting = false;
      _selectAnchor = null;
      _selectEnd = null;
      _dragged = false;
    });

    if (selecting && anchor != null && end != null) {
      if (end.isBefore(anchor)) {
        final swap = anchor;
        anchor = end;
        end = swap;
      }
      widget.onRangeSelected(anchor, end);
      return;
    }
    if (!dragged) {
      final day = _dayAt(localPosition.dx);
      final onDay = widget.series.occurrences
          .where((occurrence) => dateOnly(occurrence.date) == day)
          .toList();
      widget.onDayTap(day, onDay);
    }
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
    final cursor = _selecting
        ? SystemMouseCursors.precise
        : _pointer != null && _dragged
        ? SystemMouseCursors.grabbing
        : SystemMouseCursors.grab;

    return MouseRegion(
      cursor: cursor,
      onHover: _onHover,
      onExit: (_) => _hoverDay.value = null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _size = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            children: [
              Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerCancel,
                onPointerSignal: _onPointerSignal,
                child: CustomPaint(
                  painter: _BalanceChartPainter(
                    series: widget.series,
                    currency: widget.currency,
                    seedDate: widget.seedDate,
                    lossThreshold: widget.lossThreshold,
                    viewStart: widget.viewStart,
                    visibleDays: widget.visibleDays,
                    selectAnchor: _selecting ? _selectAnchor : null,
                    selectEnd: _selecting ? _selectEnd : null,
                    labelStyle: theme.textTheme.bodySmall ?? const TextStyle(),
                    strongStyle:
                        (theme.textTheme.labelMedium ?? const TextStyle())
                            .copyWith(fontWeight: FontWeight.w700),
                    laneStyle: (theme.textTheme.labelSmall ?? const TextStyle())
                        .copyWith(fontWeight: FontWeight.w600),
                    transactionNames: widget.transactionNames,
                    textScaler: MediaQuery.textScalerOf(context),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              ValueListenableBuilder<DateTime?>(
                valueListenable: _hoverDay,
                builder: (context, day, _) {
                  if (day == null || _pointer != null || _selecting) {
                    return const SizedBox.shrink();
                  }
                  return _addButton(theme, day);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  void _onHover(PointerHoverEvent event) {
    if (_pointer != null || _size == Size.zero) return;
    final pos = event.localPosition;
    final layout = _layout;
    if (!layout.plot.contains(pos)) {
      if (_hoverDay.value != null) _hoverDay.value = null;
      return;
    }
    final under = layout.dateAt(pos.dx, widget.viewStart, widget.visibleDays);
    final current = _hoverDay.value;
    if (current == under) return;
    final rect = current == null ? null : _dayButtonRect(layout, current);
    if (rect != null && rect.contains(pos)) return;
    _hoverDay.value = under;
  }

  /// Y of the balance step drawn through [day], using the same scale as the line.
  double? _balanceLineY(ChartLayout layout, DateTime day) {
    final visible = visibleBalance(
      points: widget.series.points,
      viewStart: widget.viewStart,
      viewEnd: addDays(widget.viewStart, widget.visibleDays),
      seedDate: widget.seedDate,
    );
    if (visible == null) return null;
    double? value;
    for (final sample in visible.samples) {
      if (dateOnly(sample.date).isAfter(day)) break;
      value = sample.closingBalance.toDouble();
    }
    if (value == null) return null;
    final padded = paddedRange(visible.extents.min, visible.extents.max);
    return _YScale(padded.min, padded.max, layout.plot).yOf(value);
  }

  /// Centered across [day], on the balance line. Null when that day has no line.
  Rect? _dayButtonRect(ChartLayout layout, DateTime day) {
    final lineY = _balanceLineY(layout, day);
    if (lineY == null) return null;
    final leftEdge = layout.xOf(day, widget.viewStart, widget.visibleDays);
    final rightEdge = layout.xOf(
      addDays(day, 1),
      widget.viewStart,
      widget.visibleDays,
    );
    final left = _clampEdge(
      (leftEdge + rightEdge) / 2 - _addButtonSize / 2,
      layout.plot.left + 4,
      layout.plot.right - _addButtonSize - 4,
    );
    final top = lineY - _addButtonSize / 2;
    return Rect.fromLTWH(left, top, _addButtonSize, _addButtonSize);
  }

  Widget _addButton(ThemeData theme, DateTime day) {
    final rect = _dayButtonRect(_layout, day);
    if (rect == null) return const SizedBox.shrink();
    final label = 'New transaction on ${formatDate(day)}';
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: _addButtonSize,
      height: _addButtonSize,
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 400),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Material(
            elevation: 4,
            color: theme.colorScheme.primary,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => widget.onCreateOnDay(day),
              child: const Center(
                child: Icon(Icons.add, color: Colors.white, size: 22),
              ),
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
  });

  final Rect plot;
  final Rect monthBand;
  final Rect? weekBand;
  final Rect? dayBand;
  final bool showWeekLane;
  final bool showDayLane;
  final bool showDayLabels;

  static const double gutter = 96;
  static const double right = 12;
  static const double top = 8;

  static ChartLayout of(Size size, double visibleDays) {
    final plotWidth = math.max(1.0, size.width - gutter - right);
    final dayPx = plotWidth / math.max(visibleDays, 0.001);
    final showDayLabels = dayPx >= 12;
    final showDayLane = dayPx >= 3;
    final showWeekLane = dayPx * 7 >= 14;
    const monthH = 26.0;
    final weekH = showWeekLane ? 20.0 : 0.0;
    final dayH = !showDayLane ? 0.0 : (showDayLabels ? 32.0 : 14.0);
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
    );
  }

  double xOf(DateTime date, DateTime viewStart, double visibleDays) {
    final days =
        date.difference(viewStart).inMicroseconds / Duration.microsecondsPerDay;
    return plot.left + days / visibleDays * plot.width;
  }

  DateTime dateAt(double localDx, DateTime viewStart, double visibleDays) {
    final fraction = ((localDx - plot.left) / plot.width).clamp(0.0, 1.0);
    return dateOnly(addDays(viewStart, fraction * visibleDays));
  }
}

const _monthColors = <Color>[
  Color(0xFF1E4D78),
  Color(0xFF0B5F5A),
  Color(0xFF2E6B45),
  Color(0xFF8C5A28),
  Color(0xFFA34538),
  Color(0xFF8A3E62),
  Color(0xFF3A568C),
  Color(0xFF1F6E78),
  Color(0xFF5A6828),
  Color(0xFFB06A22),
  Color(0xFF6A4634),
  Color(0xFF3E4C63),
];

const _weekColors = <Color>[
  Color(0xFFF6E3B8),
  Color(0xFFD9EBD3),
  Color(0xFFF8D7CC),
  Color(0xFFD9E4F5),
];

const _dayColors = <Color>[
  Color(0xFFD5E4F2),
  Color(0xFFD8F0E4),
  Color(0xFFFFF1CC),
  Color(0xFFF9DCC8),
  Color(0xFFF6D0D4),
  Color(0xFFE4D7F4),
  Color(0xFFE7E5E0),
];

Color _monthColor(int month) => _monthColors[(month - 1).clamp(0, 11)];

Color _weekColor(int index) => _weekColors[index.clamp(0, 3)];

Color _dayColor(int weekday) => _dayColors[(weekday - 1).clamp(0, 6)];

class _BalanceChartPainter extends CustomPainter {
  _BalanceChartPainter({
    required this.series,
    required this.currency,
    required this.seedDate,
    required this.lossThreshold,
    required this.viewStart,
    required this.visibleDays,
    required this.selectAnchor,
    required this.selectEnd,
    required this.labelStyle,
    required this.strongStyle,
    required this.laneStyle,
    required this.transactionNames,
    required this.textScaler,
  });

  final BalanceSeries series;
  final String currency;
  final DateTime seedDate;
  final double lossThreshold;
  final DateTime viewStart;
  final double visibleDays;
  final DateTime? selectAnchor;
  final DateTime? selectEnd;
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

    final padded = paddedRange(visible.extents.min, visible.extents.max);
    final scale = _YScale(padded.min, padded.max, layout.plot);
    _paintGrid(canvas, layout, scale, visible.extents);
    _paintSelection(canvas, layout, viewEnd);
    _paintMarkers(canvas, layout, viewEnd, seed);
    _paintSeries(canvas, layout, scale, visible, seed, viewEnd);
    _paintOccurrences(canvas, layout, scale, viewEnd, seed);
    _paintYLabels(canvas, layout, scale, visible.extents);
    if (selectAnchor != null && selectEnd != null) {
      _paintSelectionLabel(canvas, layout);
    }
  }

  void _paintPlotBands(Canvas canvas, ChartLayout layout, DateTime viewEnd) {
    canvas.save();
    canvas.clipRect(layout.plot);
    final segments = layout.showDayLabels
        ? daySegments(viewStart, viewEnd)
        : layout.showWeekLane
        ? weekSegments(viewStart, viewEnd)
        : monthSegments(viewStart, viewEnd);
    for (final segment in segments) {
      final color = switch (segment.lane) {
        AxisLane.day => _dayColor(segment.colorIndex),
        AxisLane.week => _weekColor(segment.colorIndex),
        AxisLane.month => _monthColor(
          segment.colorIndex,
        ).withValues(alpha: 0.16),
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
    final monthPaint = Paint()
      ..color = const Color(0xFF1A2422).withValues(alpha: 0.28)
      ..strokeWidth = 1;
    for (final segment in monthSegments(viewStart, viewEnd)) {
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
      ..color = const Color(0xFF1A2422).withValues(alpha: 0.12)
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
      layout.monthBand,
      monthSegments(viewStart, viewEnd),
      viewEnd,
      (segment, width) {
        if (width >= 96) return DateFormat.MMMM().format(segment.start);
        if (width >= 40) return DateFormat.MMM().format(segment.start);
        return '';
      },
      (segment) => _monthColor(segment.colorIndex),
      Colors.white,
      'Month',
    );
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
        const Color(0xFF1A2422),
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
        (segment, width) {
          if (!layout.showDayLabels) return '';
          final ordinal = ordinalDay(segment.start.day);
          if (width >= 44) {
            return '${DateFormat.E().format(segment.start)}\n$ordinal';
          }
          return ordinal;
        },
        (segment) => _dayColor(segment.colorIndex),
        const Color(0xFF1A2422),
        'Day',
        rotateWhenTight: true,
      );
    }
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
    String laneName, {
    bool rotateWhenTight = false,
  }) {
    canvas.drawRect(band, Paint()..color = const Color(0xFFE7EEEC));
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
      if (rotateWhenTight && !_fitsHorizontally(label, style, rect)) {
        _paintRotated(canvas, rect, label, style);
      } else {
        _paintCentered(canvas, rect.deflate(1), label, style);
      }
    }
    canvas.restore();
    _paintCentered(
      canvas,
      Rect.fromLTWH(0, band.top, layout.plot.left - 4, band.height),
      laneName,
      labelStyle.copyWith(fontSize: 10, fontWeight: FontWeight.w700),
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
      ..color = const Color(0xFF1A2422).withValues(alpha: 0.08)
      ..strokeWidth = 1;
    final digits = moneyDigitsForSpan(extents.min, extents.max);
    final minY = scale.yOf(extents.min);
    final maxY = scale.yOf(extents.max);
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
        formatMoneyAmount(value, currency, decimalDigits: digits),
        labelStyle,
      );
    }

    if (scale.yMin < 0 && scale.yMax > 0) {
      final y = scale.yOf(0);
      canvas.drawLine(
        Offset(layout.plot.left, y),
        Offset(layout.plot.right, y),
        Paint()
          ..color = const Color(0xFF1A2422).withValues(alpha: 0.35)
          ..strokeWidth = 1,
      );
      if ((y - minY).abs() >= 22 && (y - maxY).abs() >= 22) {
        _paintYText(
          canvas,
          layout,
          y,
          formatMoneyAmount(0, currency, decimalDigits: digits),
          labelStyle,
        );
      }
    }

    final extentPaint = Paint()
      ..color = const Color(0xFF0B5F5A).withValues(alpha: 0.55)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(layout.plot.left, maxY),
      Offset(layout.plot.right, maxY),
      extentPaint,
    );
    if (!extents.isFlat) {
      canvas.drawLine(
        Offset(layout.plot.left, minY),
        Offset(layout.plot.right, minY),
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
        'max ${formatMoneyAmount(extents.max, currency, decimalDigits: digits)}';
    final maxY = scale.yOf(extents.max);
    if (extents.isFlat) {
      _paintYText(canvas, layout, maxY, maxLabel, strongStyle, emphasize: true);
      return;
    }
    final minLabel =
        'min ${formatMoneyAmount(extents.min, currency, decimalDigits: digits)}';
    final minY = scale.yOf(extents.min);
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
      canvas.drawRRect(
        bg,
        Paint()..color = const Color(0xFFF3F0E8).withValues(alpha: 0.92),
      );
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
      color: const Color(0xFF5C6B68).withValues(alpha: 0.8),
      label: 'Seed',
      labelColor: const Color(0xFF5C6B68),
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
    final next = dateOnly(date).add(const Duration(days: 1));
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

  void _paintSelection(Canvas canvas, ChartLayout layout, DateTime viewEnd) {
    final anchor = selectAnchor;
    final end = selectEnd;
    if (anchor == null || end == null) return;
    final start = anchor.isBefore(end) ? anchor : end;
    final finish = anchor.isBefore(end) ? end : anchor;
    final x1 = layout.xOf(start, viewStart, visibleDays);
    final x2 = layout.xOf(addDays(finish, 1), viewStart, visibleDays);
    final rect = Rect.fromLTRB(
      x1.clamp(layout.plot.left, layout.plot.right),
      layout.plot.top,
      x2.clamp(layout.plot.left, layout.plot.right),
      layout.dayBand?.bottom ??
          layout.weekBand?.bottom ??
          layout.monthBand.bottom,
    );
    canvas.drawRect(
      rect,
      Paint()..color = AppTheme.mint.withValues(alpha: 0.22),
    );
  }

  void _paintSelectionLabel(Canvas canvas, ChartLayout layout) {
    final anchor = selectAnchor;
    final end = selectEnd;
    if (anchor == null || end == null) return;
    final start = anchor.isBefore(end) ? anchor : end;
    final finish = anchor.isBefore(end) ? end : anchor;
    final text = '${formatDate(start)} → ${formatDate(finish)}';
    final painter = TextPainter(
      text: TextSpan(text: text, style: strongStyle.copyWith(fontSize: 12)),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        layout.plot.left + 8,
        layout.plot.top + 6,
        painter.width + 16,
        painter.height + 8,
      ),
      const Radius.circular(8),
    );
    canvas.drawRRect(
      rect,
      Paint()..color = const Color(0xFFFFFFF2).withValues(alpha: 0.94),
    );
    painter.paint(canvas, Offset(rect.left + 8, rect.top + 4));
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
    final drawStart = viewStart.isBefore(seed) ? seed : viewStart;
    if (!drawStart.isBefore(viewEnd)) return;

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
        .xOf(viewEnd, viewStart, visibleDays)
        .clamp(layout.plot.left, layout.plot.right)
        .toDouble();

    final plateaus = <({double x0, double x1, double value})>[];
    final strokes = <({Offset from, Offset to, bool loss})>[];
    double? current = carry?.closingBalance.toDouble();
    var cursor = startX;
    for (final jump in jumps) {
      final jx = layout
          .xOf(dateOnly(jump.date), viewStart, visibleDays)
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
    for (final plateau in plateaus) {
      if (plateau.x1 <= plateau.x0) continue;
      final y = scale.yOf(plateau.value);
      final fill = Path()
        ..moveTo(plateau.x0, y)
        ..lineTo(plateau.x1, y)
        ..lineTo(plateau.x1, layout.plot.bottom)
        ..lineTo(plateau.x0, layout.plot.bottom)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..color = _isLoss(plateau.value)
              ? AppTheme.debitColor.withValues(alpha: 0.22)
              : const Color(0xFF0B5F5A).withValues(alpha: 0.1),
      );
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
          ..color = loss ? AppTheme.debitColor : const Color(0xFF0B5F5A)
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
    final counts = <int, int>{};
    final vertices = <_ChartVertex>[];

    // Opening balance of each day with occurrences: close minus that day's
    // applied deltas, so same-day vertices can show a running balance.
    final dayTotals = <int, double>{};
    for (final occurrence in series.occurrences) {
      if (occurrence.skipped) continue;
      final key = dateOnly(occurrence.date).millisecondsSinceEpoch;
      dayTotals[key] = (dayTotals[key] ?? 0) + occurrence.signedDelta.toDouble();
    }
    final openings = <int, double>{
      for (final entry in dayTotals.entries)
        if (closes[entry.key] != null) entry.key: closes[entry.key]! - entry.value,
    };
    final running = <int, double>{};

    canvas.save();
    canvas.clipRect(layout.plot);
    for (final occurrence in series.occurrences) {
      final day = dateOnly(occurrence.date);
      final nextDay = day.add(const Duration(days: 1));
      if (day.isBefore(seed) ||
          !nextDay.isAfter(viewStart) ||
          day.isAfter(viewEnd)) {
        continue;
      }
      final yValue = closes[day.millisecondsSinceEpoch];
      if (yValue == null) continue;
      final key = day.millisecondsSinceEpoch;
      final stack = counts[key] ?? 0;
      counts[key] = stack + 1;
      final x = layout.xOf(day, viewStart, visibleDays);
      final y = scale.yOf(yValue) - stack * (radius * 2 + 2);
      final center = Offset(x, y);
      if (occurrence.skipped) {
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.fill,
        );
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = const Color(0xFF9AA5A1)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      } else {
        final debit = occurrence.signedDelta.toDouble() < 0;
        canvas.drawCircle(
          center,
          radius,
          Paint()..color = debit ? AppTheme.debitColor : AppTheme.creditColor,
        );
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = const Color(0xFF0B5F5A)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
      final rawName = transactionNames[occurrence.transactionId];
      final name = rawName == null
          ? ''
          : (rawName.trim().isEmpty ? 'Transaction' : rawName.trim());
      // Occurrences are in engine order, so this is the balance right after
      // this one applied (skipped occurrences leave the balance unchanged).
      final delta = occurrence.skipped ? 0.0 : occurrence.signedDelta.toDouble();
      running[key] = (running[key] ?? openings[key] ?? yValue) + delta;
      vertices.add(
        _ChartVertex(
          center: center,
          radius: radius,
          name: name,
          balance: running[key]!,
          skipped: occurrence.skipped,
          debit: occurrence.signedDelta.toDouble() < 0,
        ),
      );
    }
    canvas.restore();
    _paintVertexLabels(canvas, layout, vertices);
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
      color: const Color(0xFF1A2422),
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
          ? style.copyWith(color: const Color(0xFF5C6B68))
          : style;
      final amount = TextPainter(
        text: TextSpan(
          text: formatMoneyAmount(vertex.balance, currency),
          style: vertexStyle.copyWith(fontWeight: FontWeight.w800),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

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
          math.max(amount.width, name?.width ?? 0) + pad;
      double heightFor(TextPainter? name) =>
          amount.height + (name?.height ?? 0) + 4;

      // Prefer a label with the transaction name; fall back to the balance alone.
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
          if (budget <= 0 || budget < amount.width) continue;
          var name = withName ? layoutName(budget) : null;
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
                ? layoutName(math.max(amount.width, nudged.width - pad))
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
          _drawVertexLabel(canvas, amount, name, rect, vertex);
          name?.dispose();
          placed.add(rect);
          labeledAt.add(vertex.center);
          drawn = true;
          break;
        }
        if (drawn) break;
      }
      amount.dispose();
    }
  }

  List<Rect> _markerLabelRects(ChartLayout layout) {
    final rects = <Rect>[];
    void add(DateTime date, String label, {bool alignLeft = false}) {
      final day = dateOnly(date);
      final next = day.add(const Duration(days: 1));
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
    _ChartVertex vertex,
  ) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFFF3F0E8));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x331A2422),
    );
    final accent = vertex.skipped
        ? const Color(0xFF9AA5A1)
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
    amount.paint(canvas, Offset(rect.left + 6, rect.top + 2));
    name?.paint(canvas, Offset(rect.left + 6, rect.top + 2 + amount.height));
  }

  bool _fitsHorizontally(String text, TextStyle style, Rect rect) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    final fits = painter.width <= rect.width - 4;
    painter.dispose();
    return fits;
  }

  /// Draws [text] reading bottom-to-top so a day label fits a narrow column.
  void _paintRotated(Canvas canvas, Rect rect, String text, TextStyle style) {
    final line = text.split('\n').last;
    final small = style.copyWith(
      fontSize: math.min(style.fontSize ?? 11, math.max(7, rect.width - 3)),
    );
    final painter = TextPainter(
      text: TextSpan(text: line, style: small),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    canvas.save();
    canvas.translate(rect.center.dx, rect.center.dy);
    canvas.rotate(-math.pi / 2);
    painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
    canvas.restore();
    painter.dispose();
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
        oldDelegate.lossThreshold != lossThreshold ||
        oldDelegate.viewStart != viewStart ||
        oldDelegate.visibleDays != visibleDays ||
        oldDelegate.selectAnchor != selectAnchor ||
        oldDelegate.selectEnd != selectEnd ||
        oldDelegate.labelStyle != labelStyle ||
        oldDelegate.strongStyle != strongStyle ||
        oldDelegate.laneStyle != laneStyle ||
        oldDelegate.textScaler != textScaler ||
        !mapEquals(oldDelegate.transactionNames, transactionNames);
  }
}

class _ChartVertex {
  const _ChartVertex({
    required this.center,
    required this.radius,
    required this.name,
    required this.balance,
    required this.skipped,
    required this.debit,
  });

  final Offset center;
  final double radius;

  /// Empty when the transaction has no known name; the balance is still shown.
  final String name;

  /// Account balance right after this occurrence.
  final double balance;
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
