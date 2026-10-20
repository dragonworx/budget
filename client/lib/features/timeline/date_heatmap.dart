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

/// Signed colour mix for a net [v]: + towards credit, − towards debit, 0
/// neutral. Intensity is sqrt(|v| / maxAbs) so small days still show,
/// from 30% up.
@visibleForTesting
double heatmapMix(double v, double maxAbs) {
  if (v.abs() < 0.005 || maxAbs <= 0) return 0;
  final t = math.sqrt((v.abs() / maxAbs).clamp(0.0, 1.0));
  return v.sign * (0.3 + 0.7 * t);
}

/// The colour for a signed [mix] (see [heatmapMix]).
Color heatmapMixColor(double mix) {
  if (mix.abs() < 1e-6) return heatmapNeutral;
  final hue = mix > 0 ? AppTheme.creditColor : AppTheme.debitColor;
  return Color.lerp(heatmapNeutral, hue, mix.abs().clamp(0.0, 1.0))!;
}

/// A cell's colour: credit for a net gain, debit for a loss, neutral for 0.
@visibleForTesting
Color heatmapColor(double v, double maxAbs) =>
    heatmapMixColor(heatmapMix(v, maxAbs));

/// Glow an active cell casts on quiet neighbours 1 and 2 cells away (a
/// slight gaussian, so an isolated day reads as a soft band, not a hairline).
const List<double> heatmapGlow = [0.4, 0.15];

/// Gradient colour per cell centre for bucket nets [cells]: an active cell
/// keeps its own colour exactly; a quiet (0) cell takes the summed glow of
/// active neighbours (gains and losses beside each other cancel).
@visibleForTesting
List<Color> heatmapBlend(List<double> cells) {
  final maxAbs = cells.fold<double>(0, (m, v) => math.max(m, v.abs()));
  final mix = [for (final v in cells) heatmapMix(v, maxAbs)];
  return [
    for (var i = 0; i < mix.length; i++)
      if (mix[i] != 0)
        heatmapMixColor(mix[i])
      else
        heatmapMixColor(() {
          var g = 0.0;
          for (var d = 1; d <= heatmapGlow.length; d++) {
            for (final j in [i - d, i + d]) {
              if (j >= 0 && j < mix.length) g += heatmapGlow[d - 1] * mix[j];
            }
          }
          return g.clamp(-1.0, 1.0);
        }()),
  ];
}

/// The date-range control: start date at the left, end date at the right,
/// and a heatmap of each day's net in between. Three separate tap targets
/// (and screen-reader buttons): the start label edits the view's start
/// ([onStartTap]), the end label its end ([onEndTap]), and the heatmap
/// between them ([onTap]) opens the start picker too. Taps only open
/// pickers; they never create or edit anything.
class DateRangeHeatmap extends StatelessWidget {
  const DateRangeHeatmap({
    super.key,
    required this.from,
    required this.to,
    required this.nets,
    required this.onTap,
    this.onStartTap,
    this.onEndTap,
    this.today,
    this.height = 44,
  });

  final DateTime from;
  final DateTime to;
  final Map<int, double> nets;

  /// The heatmap strip between the labels.
  final VoidCallback onTap;

  /// The start label (null: the strip's [onTap]).
  final VoidCallback? onStartTap;

  /// The end label (null: the strip's [onTap]).
  final VoidCallback? onEndTap;
  final DateTime? today;

  /// Row height; the label tap targets are at least [minTapHeight] tall.
  final double height;

  /// Smallest touch height of each tap target.
  static const double minTapHeight = 44;

  static String _yy(DateTime d) => '’${DateFormat('yy').format(d)}';

  /// "9 Oct" … "4 Nov ’26"; both ends carry a year across a year end.
  String get startLabel => from.year == to.year
      ? DateFormat('d MMM').format(from)
      : '${DateFormat('d MMM').format(from)} ${_yy(from)}';
  String get endLabel => '${DateFormat('d MMM').format(to)} ${_yy(to)}';

  /// The full dates, for screen readers.
  static String _long(DateTime d) => DateFormat('d MMMM y').format(d);

  Widget _target({
    required Key key,
    required String tooltip,
    required String semantics,
    required VoidCallback onPressed,
    required Widget child,
    EdgeInsets padding = EdgeInsets.zero,
  }) => Tooltip(
    message: tooltip,
    excludeFromSemantics: true,
    child: Semantics(
      button: true,
      label: semantics,
      onTap: onPressed,
      excludeSemantics: true,
      child: InkWell(
        key: key,
        onTap: onPressed,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: minTapHeight),
          child: Padding(
            padding: padding,
            child: Center(child: child),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w700,
      color: AppTheme.text,
    );
    final rowHeight = math.max(height, minTapHeight);
    return Material(
      key: const ValueKey('jump-to-date'),
      color: AppTheme.raised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: rowHeight,
        child: Row(
          children: [
            _target(
              key: const ValueKey('range-start-button'),
              tooltip: 'Edit start date',
              semantics: 'Start date: ${_long(from)}. Edit start date',
              onPressed: onStartTap ?? onTap,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                startLabel,
                key: const ValueKey('range-start'),
                style: label,
                maxLines: 1,
              ),
            ),
            Expanded(
              child: _target(
                key: const ValueKey('range-heatmap-button'),
                tooltip: 'Jump to a date',
                semantics:
                    'Jump to a date: $startLabel – $endLabel '
                    '(daily net heatmap)',
                onPressed: onTap,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final cells = heatmapBuckets(
                      nets,
                      from,
                      to,
                      math.max(1, (box.maxWidth / heatmapMinCell).floor()),
                    );
                    final a = dayCoord(from);
                    final span = dayCoord(to) - a + 1; // inclusive days
                    final t = today == null
                        ? null
                        : (dayCoord(today!) - a + 0.5) / span;
                    return CustomPaint(
                      key: const ValueKey('range-heatmap'),
                      size: Size(box.maxWidth, rowHeight - 16),
                      painter: HeatmapPainter(
                        colors: heatmapBlend(cells),
                        todayFraction: t != null && t >= 0 && t <= 1 ? t : null,
                      ),
                    );
                  },
                ),
              ),
            ),
            _target(
              key: const ValueKey('range-end-button'),
              tooltip: 'Edit end date',
              semantics: 'End date: ${_long(to)}. Edit end date',
              onPressed: onEndTap ?? onTap,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                endLabel,
                key: const ValueKey('range-end'),
                style: label,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints the heatmap as one continuous horizontal gradient (a stop at each
/// cell's centre, so adjacent days blend) and a thin today marker.
class HeatmapPainter extends CustomPainter {
  HeatmapPainter({required this.colors, this.todayFraction});

  /// Colour at each cell centre, left to right.
  final List<Color> colors;
  final double? todayFraction;

  /// Gradient stops: the cell centres as fractions of the width.
  List<double> get stops => [
    for (var i = 0; i < colors.length; i++) (i + 0.5) / colors.length,
  ];

  /// The gradient filling the strip (null: a single solid colour).
  LinearGradient? get gradient =>
      colors.length < 2 ? null : LinearGradient(colors: colors, stops: stops);

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty || size.width <= 0) return;
    final rect = Offset.zero & size;
    final g = gradient;
    final paint = Paint();
    if (g == null) {
      paint.color = colors.first;
    } else {
      paint.shader = g.createShader(rect);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      paint,
    );
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
