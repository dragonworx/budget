import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/models.dart';
import 'chart_geometry.dart';
import 'zoom_level.dart';

/// A what-if balance line drawn dashed over the chart (plan preview,
/// saved scenarios). [points] are daily closing balances; the line starts
/// at the opening of [from] (the first day it differs from the real line).
class GhostLine {
  const GhostLine({
    required this.points,
    required this.color,
    this.from,
    this.label,
    this.dashed = true,
    this.strokeWidth = 2,
  });

  final List<BalancePoint> points;
  final Color color;
  final DateTime? from;
  final String? label;
  final bool dashed;
  final double strokeWidth;
}

/// One horizontal run of a step line: [value] from day coordinate [x0] to
/// [x1] (days since epoch, fractional).
typedef GhostStep = ({DateTime start, DateTime end, double value});

/// Collapses daily [points] into flat steps from [from] (day start) to the
/// day after the last point. Balances change mid-day, like the main line.
List<GhostStep> ghostSteps(List<BalancePoint> points, {DateTime? from}) {
  if (points.isEmpty) return const [];
  final sorted = [...points]..sort((a, b) => a.date.compareTo(b.date));
  final start = dateOnly(from ?? sorted.first.date);
  double? current;
  for (final p in sorted) {
    if (dateOnly(p.date).isBefore(start)) current = p.closingBalance.toDouble();
  }
  final steps = <GhostStep>[];
  var cursor = start;
  DateTime? lastDay;
  for (final p in sorted) {
    final day = dateOnly(p.date);
    if (day.isBefore(start)) continue;
    lastDay = day;
    final value = p.closingBalance.toDouble();
    if (current == null) {
      current = value;
      continue;
    }
    if (value == current) continue;
    final at = addDays(day, 0.5);
    steps.add((start: cursor, end: at, value: current));
    cursor = at;
    current = value;
  }
  if (current == null || lastDay == null) return steps;
  steps.add((start: cursor, end: addCalendarDays(lastDay, 1), value: current));
  return steps;
}

class GhostLinePainter extends CustomPainter {
  GhostLinePainter({
    required this.ghosts,
    required this.plot,
    required this.xOf,
    required this.yOf,
    required this.repaintKey,
  });

  final List<GhostLine> ghosts;
  final Rect plot;
  final double Function(DateTime) xOf;
  final double Function(double) yOf;

  /// Everything the mapping depends on (view, y range, size).
  final Object repaintKey;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(plot);
    for (final g in ghosts) {
      final steps = ghostSteps(g.points, from: g.from);
      if (steps.isEmpty) continue;
      final path = Path();
      for (var i = 0; i < steps.length; i++) {
        final s = steps[i];
        final y = yOf(s.value);
        final x0 = xOf(s.start), x1 = xOf(s.end);
        if (i == 0) {
          path.moveTo(x0, y);
        } else {
          path.lineTo(x0, y);
        }
        path.lineTo(x1, y);
      }
      final paint = Paint()
        ..color = g.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = g.strokeWidth
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(g.dashed ? _dash(path, 7, 5) : path, paint);
      final last = steps.last;
      canvas.drawCircle(
        Offset(xOf(last.end), yOf(last.value)),
        3.5,
        Paint()..color = g.color,
      );
    }
    canvas.restore();
  }

  static Path _dash(Path source, double on, double off) {
    final out = Path();
    for (final ui.PathMetric m in source.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        out.addPath(m.extractPath(d, d + on), Offset.zero);
        d += on + off;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(covariant GhostLinePainter old) =>
      old.repaintKey != repaintKey || !identical(old.ghosts, ghosts);
}
