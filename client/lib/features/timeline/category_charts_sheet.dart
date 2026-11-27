import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../state/app_prefs.dart';
import '../../theme/app_theme.dart';
import '../../widgets/date_range_preset_control.dart';
import '../../widgets/money_text.dart';
import 'category_chart_layout.dart';
import 'category_totals.dart';
import 'date_range.dart';

/// Opens the category charts as a phone bottom sheet (< 600) or a
/// desktop dialog (max width 560). The [tick] listenable rebuilds the
/// open view when the shared range or series changes.
Future<void> showCategoryCharts({
  required BuildContext context,
  required ValueNotifier<int> tick,
  required DateRange Function() rangeOf,
  required ValueChanged<DateRange> onRangeChanged,
  required CategoryTotals Function() totalsOf,
  required bool Function() hasEvents,
}) {
  final phone = MediaQuery.sizeOf(context).width < 600;
  Widget page(BuildContext ctx) => ValueListenableBuilder<int>(
    valueListenable: tick,
    builder: (_, _, _) => CategoryChartsView(
      range: rangeOf(),
      onRangeChanged: onRangeChanged,
      totals: totalsOf(),
      hasEvents: hasEvents(),
      onClose: () => Navigator.of(ctx).maybePop(),
      showHandle: phone,
    ),
  );
  if (phone) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // Theme enables a Material handle; we draw our own below.
      showDragHandle: false,
      backgroundColor: AppTheme.surface,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.9,
        child: page(ctx),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: AppTheme.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
        child: page(ctx),
      ),
    ),
  );
}

/// Pie / bar category totals for the shared date range.
class CategoryChartsView extends StatefulWidget {
  const CategoryChartsView({
    super.key,
    required this.range,
    required this.onRangeChanged,
    required this.totals,
    required this.hasEvents,
    required this.onClose,
    this.showHandle = false,
  });

  final DateRange range;
  final ValueChanged<DateRange> onRangeChanged;
  final CategoryTotals totals;
  final bool hasEvents;
  final VoidCallback onClose;
  final bool showHandle;

  @override
  State<CategoryChartsView> createState() => _CategoryChartsViewState();
}

class _CategoryChartsViewState extends State<CategoryChartsView> {
  late bool _pie;
  bool _moneyOut = true;
  String? _highlightId;

  @override
  void initState() {
    super.initState();
    _pie = appPrefs.getString(PrefKeys.categoryChartMode) != 'bar';
  }

  void _setPie(bool pie) {
    if (pie == _pie) return;
    setState(() => _pie = pie);
    appPrefs.setString(PrefKeys.categoryChartMode, pie ? 'pie' : 'bar');
  }

  void _setSide(bool moneyOut) {
    if (moneyOut == _moneyOut) return;
    setState(() {
      _moneyOut = moneyOut;
      _highlightId = null;
    });
  }

  void _select(String? id) {
    setState(() => _highlightId = id == _highlightId ? null : id);
    if (id != null) {
      final ctx = _legendKeys[id]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.2,
          duration: const Duration(milliseconds: 180),
        );
      }
    }
  }

  final _legendKeys = <String, GlobalKey>{};

  @override
  Widget build(BuildContext context) {
    final totals = widget.totals;
    final slices = totals.side(moneyOut: _moneyOut);
    final sideTotal = _moneyOut ? totals.outCents.abs() : totals.inCents;
    final rangeLabel = _rangeLabel(widget.range);
    final semantics = 'Category charts, ${widget.range.preset.label}';
    return Semantics(
      label: semantics,
      child: Material(
        color: AppTheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHandle) _handle(),
            _header(rangeLabel),
            _subheader(rangeLabel, totals),
            _sideToggle(totals),
            Expanded(child: _body(slices, sideTotal, totals)),
          ],
        ),
      ),
    );
  }

  Widget _handle() => Center(
    child: Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: AppTheme.borderStrong,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );

  Widget _header(String rangeLabel) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Category charts',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                key: const ValueKey('charts-close'),
                tooltip: 'Close',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          Row(
            children: [
              Flexible(
                child: DateRangePresetControl(
                  range: widget.range,
                  onChanged: widget.onRangeChanged,
                ),
              ),
              const SizedBox(width: 8),
              _modeToggle(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _modeToggle() {
    Widget seg(String key, String label, bool pie) {
      final on = _pie == pie;
      return Semantics(
        button: true,
        selected: on,
        label: label,
        child: Material(
          key: ValueKey(key),
          color: on ? AppTheme.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _setPie(pie),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                label,
                style: TextStyle(
                  color: on ? AppTheme.accent : AppTheme.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      label: 'Chart type',
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            seg('charts-mode-pie', 'Pie', true),
            seg('charts-mode-bar', 'Bar', false),
          ],
        ),
      ),
    );
  }

  Widget _subheader(String rangeLabel, CategoryTotals totals) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(rangeLabel, style: const TextStyle(color: AppTheme.textMuted)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _stat('Money in', formatSignedAmount(totals.inCents / 100.0)),
              _stat('Money out', formatSignedAmount(totals.outCents / 100.0)),
              _stat('Net', formatSignedAmount(totals.netCents / 100.0)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$label ',
          style: const TextStyle(color: AppTheme.textFaint, fontSize: 13),
        ),
        TextSpan(
          text: value,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );

  Widget _sideToggle(CategoryTotals totals) {
    Widget seg(String key, String label, bool out) {
      final on = _moneyOut == out;
      return Semantics(
        button: true,
        selected: on,
        label: label,
        child: Material(
          key: ValueKey(key),
          color: on ? AppTheme.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _setSide(out),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                label,
                style: TextStyle(
                  color: on ? AppTheme.accent : AppTheme.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: AppTheme.border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              seg('charts-side-out', 'Money out', true),
              seg('charts-side-in', 'Money in', false),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(
    List<CategoryBucket> slices,
    int sideTotal,
    CategoryTotals totals,
  ) {
    if (slices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(_emptyMessage(totals), textAlign: TextAlign.center),
        ),
      );
    }
    return Column(
      children: [
        Flexible(
          flex: _pie ? 3 : 5,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: _pie
                ? _pieChart(slices, sideTotal)
                : _barChart(slices, sideTotal),
          ),
        ),
        Expanded(
          flex: _pie ? 4 : 3,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [for (final b in slices) _legendRow(b, sideTotal)],
          ),
        ),
      ],
    );
  }

  String _emptyMessage(CategoryTotals totals) {
    if (!widget.hasEvents && widget.range.isAllTime) {
      return 'No transactions to chart yet.';
    }
    if (totals.isEmpty) return 'No counted transactions in this range';
    if (_moneyOut) return 'No money out in this range';
    return 'No money in in this range';
  }

  Widget _pieChart(List<CategoryBucket> slices, int sideTotal) {
    return LayoutBuilder(
      builder: (context, c) {
        final style =
            (Theme.of(context).textTheme.bodySmall ?? const TextStyle())
                .copyWith(
                  fontSize: pieLabelFontSize,
                  height: pieLabelLineHeight,
                  color: AppTheme.textMuted,
                  fontWeight: FontWeight.w500,
                );
        final layout = layoutPieChart(
          size: Size(c.maxWidth, c.maxHeight),
          slices: slices,
          total: sideTotal,
          moneyOut: _moneyOut,
          style: style,
        );
        return GestureDetector(
          onTapDown: (d) => _select(hitTestPie(d.localPosition, layout)),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _PiePainter(
                    layout: layout,
                    highlightId: _highlightId,
                  ),
                ),
              ),
              for (final lab in layout.labels)
                Positioned(
                  left: lab.rect.left,
                  top: lab.rect.top,
                  width: math.max(lab.rect.width, 1),
                  height: math.max(lab.rect.height, 1),
                  child: Semantics(
                    button: true,
                    selected: _highlightId == lab.id,
                    label: lab.caption,
                    child: GestureDetector(
                      key: ValueKey('charts-pie-label-${lab.id}'),
                      onTap: () => _select(lab.id),
                      child: Text(
                        lab.text,
                        maxLines: 3,
                        overflow: TextOverflow.visible,
                        textAlign: lab.left ? TextAlign.right : TextAlign.left,
                        style: style.copyWith(
                          color: _highlightId == lab.id
                              ? AppTheme.text
                              : AppTheme.textMuted,
                          fontWeight: _highlightId == lab.id
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _barChart(List<CategoryBucket> slices, int sideTotal) {
    return _ColumnBarChart(
      slices: slices,
      total: sideTotal,
      highlightId: _highlightId,
      moneyOut: _moneyOut,
      onSelect: _select,
    );
  }

  Widget _legendRow(CategoryBucket b, int sideTotal) {
    final key = _legendKeys.putIfAbsent(b.id, GlobalKey.new);
    final cents = b.centsOn(moneyOut: _moneyOut);
    final pct = sideTotal == 0 ? 0 : (cents.abs() * 100 / sideTotal).round();
    final amount = formatMoneyAmount(cents.abs() / 100.0);
    final on = _highlightId == b.id;
    final label = b.groupedCount > 0
        ? '${b.name}, $amount, $pct%, ${b.groupedCount} categories'
        : '${b.name}, $amount, $pct%';
    final path = b.path;
    return Semantics(
      button: true,
      selected: on,
      label: label,
      child: Material(
        key: key,
        color: on ? AppTheme.accentSoft : Colors.transparent,
        child: InkWell(
          key: ValueKey('charts-legend-${b.id}'),
          onTap: () => _select(b.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: b.color,
                    shape: BoxShape.circle,
                    border: _needsHairline(b.color)
                        ? Border.all(color: Colors.white54)
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (path != null)
                        Text(
                          path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textFaint,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      b.groupedCount > 0
                          ? '$amount · $pct% · ${b.groupedCount} categor${b.groupedCount == 1 ? 'y' : 'ies'}'
                          : (b.count > 1
                                ? '$amount · $pct% · ${b.count}'
                                : '$amount · $pct%'),
                      maxLines: 1,
                      style: const TextStyle(color: AppTheme.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _rangeLabel(DateRange range) {
  if (range.isAllTime) return 'All time';
  final start = range.start, end = range.end;
  if (start == null || end == null) return range.preset.label;
  final fmt = DateFormat('d MMM y');
  String dates;
  if (start.year == end.year && start.month == end.month) {
    dates = '${start.day}–${fmt.format(end)}';
  } else {
    dates = '${fmt.format(start)}–${fmt.format(end)}';
  }
  return '${range.preset.label} · $dates';
}

bool _needsHairline(Color color) {
  const bg = AppTheme.surface;
  return (color.computeLuminance() - bg.computeLuminance()).abs() < 0.14;
}

class _PiePainter extends CustomPainter {
  _PiePainter({required this.layout, required this.highlightId});

  final PieChartLayout layout;
  final String? highlightId;

  @override
  void paint(Canvas canvas, Size size) {
    if (layout.total == 0 || layout.slices.isEmpty) return;
    final c = layout.center;
    final r = layout.radius;
    var start = -math.pi / 2;
    for (final b in layout.slices) {
      final share = b.centsOn(moneyOut: layout.moneyOut).abs();
      final sweep = 2 * math.pi * share / layout.total;
      final mid = start + sweep / 2;
      final highlighted = b.id == highlightId;
      final center = highlighted
          ? c + Offset(math.cos(mid), math.sin(mid)) * 5
          : c;
      final rect = Rect.fromCircle(center: center, radius: r);
      canvas.drawArc(rect, start, sweep, true, Paint()..color = b.color);
      if (_needsHairline(b.color) || highlighted) {
        canvas.drawArc(
          rect,
          start,
          sweep,
          true,
          Paint()
            ..color = Colors.white70
            ..style = PaintingStyle.stroke
            ..strokeWidth = highlighted ? 2 : 1,
        );
      }
      start += sweep;
    }

    final leader = Paint()
      ..color = AppTheme.borderStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final lab in layout.labels) {
      final path = Path()
        ..moveTo(lab.rim.dx, lab.rim.dy)
        ..lineTo(lab.elbow.dx, lab.elbow.dy)
        ..lineTo(lab.anchor.dx, lab.anchor.dy);
      canvas.drawPath(
        path,
        leader
          ..color = highlightId == lab.id
              ? AppTheme.textMuted
              : AppTheme.borderStrong,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PiePainter old) =>
      old.layout != layout || old.highlightId != highlightId;
}

class _ColumnBarChart extends StatelessWidget {
  const _ColumnBarChart({
    required this.slices,
    required this.total,
    required this.highlightId,
    required this.moneyOut,
    required this.onSelect,
  });

  final List<CategoryBucket> slices;
  final int total;
  final String? highlightId;
  final bool moneyOut;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final valueStyle = Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: AppTheme.text, fontSize: 10);
        final labelStyle = Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: AppTheme.textMuted, fontSize: 10);
        final layout = layoutColumnBars(
          viewport: Size(c.maxWidth, c.maxHeight),
          slices: slices,
          total: total,
          moneyOut: moneyOut,
          valueStyle: valueStyle,
          labelStyle: labelStyle,
          needsHairline: _needsHairline,
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: layout.axisWidth,
              child: CustomPaint(
                painter: _BarAxisPainter(layout: layout, style: valueStyle),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: layout.contentWidth,
                  height: c.maxHeight,
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _ColumnBarPainter(
                            layout: layout,
                            highlightId: highlightId,
                          ),
                        ),
                      ),
                      for (final b in layout.bars) ...[
                        Positioned(
                          left: b.bar.left,
                          top: layout.plot.top,
                          width: math.max(b.bar.width, 8),
                          height: math.max(layout.plot.height, 8),
                          child: Semantics(
                            button: true,
                            selected: highlightId == b.id,
                            label: '${b.caption}, ${b.valueText}',
                            child: GestureDetector(
                              key: ValueKey('charts-bar-${b.id}'),
                              onTap: () => onSelect(b.id),
                              behavior: HitTestBehavior.opaque,
                            ),
                          ),
                        ),
                        Positioned(
                          left: b.bar.center.dx - 40,
                          top: b.bar.top - 16,
                          width: 80,
                          height: 16,
                          child: IgnorePointer(
                            child: Text(
                              b.valueText,
                              maxLines: 1,
                              textAlign: TextAlign.center,
                              style: valueStyle,
                            ),
                          ),
                        ),
                        Positioned(
                          left: b.bar.center.dx,
                          top: layout.plot.bottom + barLabelPad,
                          child: IgnorePointer(
                            child: Transform.rotate(
                              angle: barLabelAngle,
                              alignment: Alignment.topLeft,
                              child: Text(
                                b.name,
                                maxLines: 1,
                                style: labelStyle,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _BarAxisPainter extends CustomPainter {
  _BarAxisPainter({required this.layout, required this.style});

  final ColumnBarLayout layout;
  final TextStyle? style;

  @override
  void paint(Canvas canvas, Size size) {
    final tickPaint = Paint()
      ..color = AppTheme.border
      ..strokeWidth = 1;
    for (final t in layout.ticks) {
      canvas.drawLine(
        Offset(size.width - 4, t.y),
        Offset(size.width, t.y),
        tickPaint,
      );
      final tp = TextPainter(
        text: TextSpan(text: t.label, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width - 6);
      tp.paint(canvas, Offset(size.width - 6 - tp.width, t.y - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _BarAxisPainter old) => old.layout != layout;
}

class _ColumnBarPainter extends CustomPainter {
  _ColumnBarPainter({required this.layout, required this.highlightId});

  final ColumnBarLayout layout;
  final String? highlightId;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = AppTheme.border.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (final t in layout.ticks) {
      canvas.drawLine(Offset(0, t.y), Offset(layout.plot.width, t.y), grid);
    }
    final axis = Paint()
      ..color = AppTheme.borderStrong
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, layout.plot.bottom),
      Offset(layout.plot.width, layout.plot.bottom),
      axis,
    );
    for (final b in layout.bars) {
      final highlighted = b.id == highlightId;
      final rect = b.bar;
      if (rect.height <= 0) continue;
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(3));
      canvas.drawRRect(rrect, Paint()..color = b.color);
      if (b.hairline || highlighted) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = Colors.white70
            ..style = PaintingStyle.stroke
            ..strokeWidth = highlighted ? 2 : 1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ColumnBarPainter old) =>
      old.layout != layout || old.highlightId != highlightId;
}
