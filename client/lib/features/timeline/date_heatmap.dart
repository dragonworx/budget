import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../theme/app_theme.dart';
import 'chart_geometry.dart';

/// Whether [o] counts towards a day's money in / out: the same rule as the
/// chart footer's day totals (not skipped, not a transfer netted out between
/// combined pools, and its series enabled).
bool countsInDayTotals(Occurrence o, {bool? enabled}) =>
    !o.skipped && !o.netted && enabled != false;

/// Net money per calendar day (day coord → in − out) for [series], counted
/// like the footer day totals. [enabledOf] says whether a series is enabled
/// (null: unknown, counted).
Map<int, double> dayNetTotals(
  BalanceSeries series, {
  bool? Function(String transactionId)? enabledOf,
}) {
  final out = <int, double>{};
  for (final o in series.occurrences) {
    if (!countsInDayTotals(o, enabled: enabledOf?.call(o.transactionId))) {
      continue;
    }
    final k = dayCoord(DateTime(o.date.year, o.date.month, o.date.day)).round();
    out[k] = (out[k] ?? 0) + o.signedDelta.toDouble();
  }
  return out;
}

/// Smallest heatmap cell, in logical pixels: more days than fit are bucketed.
const double heatmapMinCell = 3;

/// Net per cell for the days [from]..[to] (inclusive) split into at most
/// [maxCells] equal runs of days (one cell per day when they fit).
@visibleForTesting
List<double> heatmapBuckets(
  Map<int, double> nets,
  DateTime from,
  DateTime to,
  int maxCells,
) {
  final a = dayCoord(DateTime(from.year, from.month, from.day)).round();
  final b = dayCoord(DateTime(to.year, to.month, to.day)).round();
  final days = math.max(1, b - a + 1);
  final cells = math.max(1, math.min(days, maxCells));
  final out = List<double>.filled(cells, 0);
  for (var d = 0; d < days; d++) {
    final v = nets[a + d];
    if (v != null) out[d * cells ~/ days] += v;
  }
  return out;
}

/// Neutral cell (no money moved).
const Color heatmapNeutral = Color(0xFF222B36);

/// A cell's colour: credit for a net gain, debit for a loss, neutral for 0.
/// Intensity is sqrt(|v| / maxAbs) so small days still show, from 30% up.
@visibleForTesting
Color heatmapColor(double v, double maxAbs) {
  if (v.abs() < 0.005 || maxAbs <= 0) return heatmapNeutral;
  final t = math.sqrt((v.abs() / maxAbs).clamp(0.0, 1.0));
  final hue = v > 0 ? AppTheme.creditColor : AppTheme.debitColor;
  return Color.lerp(heatmapNeutral, hue, 0.3 + 0.7 * t)!;
}

/// The date-range control: start date at the left, end date at the right,
/// and a heatmap of each day's net in between. Tap opens the date picker.
class DateRangeHeatmap extends StatelessWidget {
  const DateRangeHeatmap({
    super.key,
    required this.from,
    required this.to,
    required this.nets,
    required this.onTap,
    this.today,
    this.height = 40,
  });

  final DateTime from;
  final DateTime to;
  final Map<int, double> nets;
  final VoidCallback onTap;
  final DateTime? today;
  final double height;

  static String _yy(DateTime d) => '’${DateFormat('yy').format(d)}';

  /// "9 Oct" … "4 Nov ’26"; both ends carry a year across a year end.
  String get startLabel => from.year == to.year
      ? DateFormat('d MMM').format(from)
      : '${DateFormat('d MMM').format(from)} ${_yy(from)}';
  String get endLabel => '${DateFormat('d MMM').format(to)} ${_yy(to)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w700,
      color: AppTheme.text,
    );
    return Tooltip(
      message: 'Jump to a date',
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: 'Jump to a date: $startLabel – $endLabel',
        // The InkWell's own action is excluded with its children: keep tap.
        onTap: onTap,
        excludeSemantics: true,
        child: Material(
          color: AppTheme.raised,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppTheme.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('jump-to-date'),
            onTap: onTap,
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Text(
                      startLabel,
                      key: const ValueKey('range-start'),
                      style: label,
                      maxLines: 1,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final cells = heatmapBuckets(
                            nets,
                            from,
                            to,
                            math.max(
                              1,
                              (box.maxWidth / heatmapMinCell).floor(),
                            ),
                          );
                          final maxAbs = cells.fold<double>(
                            0,
                            (m, v) => math.max(m, v.abs()),
                          );
                          final a = dayCoord(from);
                          final span = dayCoord(to) - a + 1; // inclusive days
                          final t = today == null
                              ? null
                              : (dayCoord(today!) - a + 0.5) / span;
                          return CustomPaint(
                            key: const ValueKey('range-heatmap'),
                            size: Size(box.maxWidth, height - 16),
                            painter: HeatmapPainter(
                              colors: [
                                for (final v in cells) heatmapColor(v, maxAbs),
                              ],
                              todayFraction: t != null && t >= 0 && t <= 1
                                  ? t
                                  : null,
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      endLabel,
                      key: const ValueKey('range-end'),
                      style: label,
                      maxLines: 1,
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

/// Paints the heatmap cells left to right and a thin today marker.
class HeatmapPainter extends CustomPainter {
  HeatmapPainter({required this.colors, this.todayFraction});

  final List<Color> colors;
  final double? todayFraction;

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty || size.width <= 0) return;
    final w = size.width / colors.length;
    final gap = w >= 5 ? 1.0 : 0.0;
    final r = Radius.circular(math.min(2, w / 3));
    final paint = Paint();
    for (var i = 0; i < colors.length; i++) {
      paint.color = colors[i];
      canvas.drawRRect(
        RRect.fromLTRBR(
          i * w + gap / 2,
          0,
          (i + 1) * w - gap / 2,
          size.height,
          r,
        ),
        paint,
      );
    }
    final t = todayFraction;
    if (t != null) {
      final x = t * size.width;
      canvas.drawLine(
        Offset(x, -3),
        Offset(x, size.height + 3),
        Paint()
          ..color = AppTheme.accent
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant HeatmapPainter old) =>
      old.todayFraction != todayFraction || !listEquals(old.colors, colors);
}
