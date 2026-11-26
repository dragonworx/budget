import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../state/app_prefs.dart';
import '../../theme/app_theme.dart';
import '../../widgets/date_range_preset_control.dart';
import '../../widgets/money_text.dart';
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
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _pie
                ? _pieChart(slices, sideTotal)
                : SingleChildScrollView(child: _barChart(slices, sideTotal)),
          ),
        ),
        Expanded(
          flex: 4,
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
      return 'No events to chart yet.';
    }
    if (totals.isEmpty) return 'No counted events in this range';
    if (_moneyOut) return 'No money out in this range';
    return 'No money in in this range';
  }

  Widget _pieChart(List<CategoryBucket> slices, int sideTotal) {
    return LayoutBuilder(
      builder: (context, c) {
        final cap = c.maxWidth < 400 ? 180.0 : 280.0;
        final maxSide = math.min(math.min(c.maxWidth, c.maxHeight), cap);
        final size = maxSide.clamp(96.0, cap);
        return Center(
          child: SizedBox.square(
            dimension: size,
            child: GestureDetector(
              onTapDown: (d) {
                final id = pieHit(
                  d.localPosition,
                  Size(size, size),
                  slices,
                  sideTotal,
                );
                _select(id);
              },
              child: CustomPaint(
                painter: _PiePainter(
                  slices: slices,
                  total: sideTotal,
                  highlightId: _highlightId,
                  moneyOut: _moneyOut,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _barChart(List<CategoryBucket> slices, int sideTotal) {
    return _BarChart(
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

/// Which slice contains [local], or null if the tap is in empty space.
/// [slices] are already the active side (one of in/out is zero).
String? pieHit(
  Offset local,
  Size size,
  List<CategoryBucket> slices,
  int total,
) {
  if (total == 0 || slices.isEmpty) return null;
  final c = Offset(size.width / 2, size.height / 2);
  final r = math.min(size.width, size.height) / 2 - 8;
  final v = local - c;
  if (v.distance > r + 12 || v.distance < 2) return null;
  var theta = math.atan2(v.dy, v.dx) + math.pi / 2;
  while (theta < 0) {
    theta += 2 * math.pi;
  }
  var acc = 0.0;
  for (final b in slices) {
    final share = (b.outCents != 0 ? b.outCents : b.inCents).abs();
    final sw = 2 * math.pi * share / total;
    if (theta <= acc + sw) return b.id;
    acc += sw;
  }
  return slices.last.id;
}

class _PiePainter extends CustomPainter {
  _PiePainter({
    required this.slices,
    required this.total,
    required this.highlightId,
    required this.moneyOut,
  });

  final List<CategoryBucket> slices;
  final int total;
  final String? highlightId;
  final bool moneyOut;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 - 8;
    var start = -math.pi / 2;
    for (final b in slices) {
      final share = b.centsOn(moneyOut: moneyOut).abs();
      final sweep = 2 * math.pi * share / total;
      final mid = start + sweep / 2;
      final highlighted = b.id == highlightId;
      final center = highlighted
          ? c + Offset(math.cos(mid), math.sin(mid)) * 6
          : c;
      final rect = Rect.fromCircle(center: center, radius: r);
      final paint = Paint()..color = b.color;
      canvas.drawArc(rect, start, sweep, true, paint);
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
  }

  @override
  bool shouldRepaint(covariant _PiePainter old) =>
      old.slices != slices ||
      old.total != total ||
      old.highlightId != highlightId ||
      old.moneyOut != moneyOut;
}

class _BarChart extends StatelessWidget {
  const _BarChart({
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
    return Column(
      children: [
        for (final b in slices)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: _bar(b)),
      ],
    );
  }

  Widget _bar(CategoryBucket b) {
    final share = b.centsOn(moneyOut: moneyOut).abs();
    final frac = total == 0 ? 0.0 : share / total;
    final amount = formatMoneyAmount(share / 100.0);
    final on = highlightId == b.id;
    return Semantics(
      button: true,
      selected: on,
      label: '${b.name}, $amount, ${(frac * 100).round()}%',
      child: Material(
        color: on ? AppTheme.accentSoft : Colors.transparent,
        child: InkWell(
          key: ValueKey('charts-bar-${b.id}'),
          onTap: () => onSelect(b.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        b.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(amount, maxLines: 1),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 10,
                    child: CustomPaint(
                      painter: _BarPainter(
                        fraction: frac,
                        color: b.color,
                        hairline: _needsHairline(b.color),
                      ),
                      child: const SizedBox.expand(),
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

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.fraction,
    required this.color,
    required this.hairline,
  });

  final double fraction;
  final Color color;
  final bool hairline;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = AppTheme.overlay;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)),
      bg,
    );
    final w = size.width * fraction.clamp(0.0, 1.0);
    if (w <= 0) return;
    final rect = Rect.fromLTWH(0, 0, w, size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = color,
    );
    if (hairline) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()
          ..color = Colors.white54
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.hairline != hairline;
}
