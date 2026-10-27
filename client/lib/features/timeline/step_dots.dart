import 'dart:math' as math;
import 'dart:ui';

import '../../data/models.dart';
import '../../widgets/money_text.dart';
import 'chart_geometry.dart';
import 'zoom_level.dart';

/// One step of the balance line: a day whose closing balance differs from
/// the day before's (the net of every occurrence that day, gains and
/// losses together; transfers between combined streams net out).
class BalanceStep {
  const BalanceStep({
    required this.day,
    required this.before,
    required this.balance,
    required this.events,
  });

  final DateTime day;

  /// The balance just before the step (the previous close).
  final double before;

  /// The balance after the step (the day's close: where the riser lands).
  final double balance;

  /// Counted (not skipped, not netted-out) occurrences that day.
  final int events;

  /// The step's net change, to the cent.
  double get delta => ((balance - before) * 100).round() / 100;

  @override
  String toString() => 'BalanceStep($day, $before -> $balance, $events)';
}

/// A step dot as drawn: its step and its centre on the line.
class StepDot {
  const StepDot(this.step, this.center, this.radius);
  final BalanceStep step;
  final Offset center;
  final double radius;
}

final _stepCache = Expando<Map<int, List<BalanceStep>>>('BalanceSteps');

/// Every step of [series] after [lineStart] (where the line begins: a day
/// on it shows its close without a riser), days ascending. Days whose
/// events net to zero have no step. Cached per series.
List<BalanceStep> balanceSteps(
  BalanceSeries series, {
  required DateTime lineStart,
}) {
  final startUs = dateOnly(lineStart).microsecondsSinceEpoch;
  final byStart = _stepCache[series] ??= {};
  return byStart[startUs] ??= _steps(series, startUs);
}

List<BalanceStep> _steps(BalanceSeries series, int startUs) {
  final ix = pointIndexOf(series.points);
  final counts = <int, int>{
    for (final g in groupByDay(series.occurrences))
      g.day.millisecondsSinceEpoch: g.active.where((o) => !o.netted).length,
  };
  final steps = <BalanceStep>[];
  double? prev;
  final n = ix.days.length;
  for (var i = 0; i < n; i++) {
    final us = ix.days[i];
    // Several samples on a day: its last one is the close.
    if (i + 1 < n && ix.days[i + 1] == us) continue;
    final v = ix.values[i];
    if (prev != null && us > startUs && ((v - prev) * 100).round() != 0) {
      final day = DateTime.fromMicrosecondsSinceEpoch(us);
      steps.add(
        BalanceStep(
          day: day,
          before: prev,
          balance: v,
          events: counts[us ~/ 1000] ?? 0,
        ),
      );
    }
    prev = v;
  }
  return steps;
}

/// Dot radius for a zoom ([dayPx] pixels per day).
double stepDotRadius(double dayPx) => dayPx >= 12 ? 4.5 : 3.5;

/// The minimum centre-to-centre spacing between drawn step dots: two radii
/// and a pixel, so neighbouring dots never touch.
double stepDotMinGap(double radius) => radius * 2 + 1;

/// Where a step's dot sits: its day's left edge (where the line rises or
/// falls) at the balance after the step. The one geometry for the dot, its
/// hover / selected ring and its guides, so they always coincide.
Offset stepCenter(
  DateTime day,
  double balance, {
  required double Function(DateTime day) xOf,
  required double Function(double value) yOf,
}) => Offset(xOf(day), yOf(balance));

/// The step dots in view, thinned left to right so no two drawn dots are
/// closer than [stepDotMinGap] (a dense zoom keeps every other / every
/// few dots rather than a smear).
List<StepDot> visibleStepDots({
  required List<BalanceStep> steps,
  required double Function(DateTime day) xOf,
  required double Function(double value) yOf,
  required Rect plot,
  required double dayPx,
}) {
  final r = stepDotRadius(dayPx);
  final gap = stepDotMinGap(r);
  final out = <StepDot>[];
  double? lastX;
  for (final s in steps) {
    final c = stepCenter(s.day, s.balance, xOf: xOf, yOf: yOf);
    final x = c.dx, y = c.dy;
    if (x < plot.left - r) continue;
    if (x > plot.right + r) break;
    if (y < plot.top - r || y > plot.bottom + r) continue;
    if (lastX != null && x - lastX < gap) continue;
    out.add(StepDot(s, c, r));
    lastX = x;
  }
  return out;
}

/// Hit radius of a step dot: a 22px target with a mouse, 44px by touch.
double stepDotHitRadius({required bool touch}) => touch ? 22 : 11;

/// The drawn dot nearest [pos] within its hit radius.
StepDot? stepDotAt(List<StepDot> dots, Offset pos, {required bool touch}) {
  final hit = stepDotHitRadius(touch: touch);
  StepDot? best;
  var bestD = double.infinity;
  for (final d in dots) {
    final dist = (d.center - pos).distance;
    if (dist <= math.max(hit, d.radius) && dist < bestD) {
      best = d;
      bestD = dist;
    }
  }
  return best;
}

/// "+$250.00" / "−$100.00".
String formatStepDelta(double delta) =>
    '${delta < 0 ? '−' : '+'}${formatMoneyAmount(delta.abs(), decimalDigits: 2)}';

/// "$1,234.56" (a negative balance "-$12.00").
String formatStepBalance(double balance) =>
    formatMoneyAmount(balance, decimalDigits: 2);

/// "1 event" / "5 events".
String formatStepEvents(int n) => n == 1 ? '1 event' : '$n events';

/// Where a step's tooltip of [size] goes: centred over the dot at
/// [anchor], [gap] above it (below when there is no room above), kept
/// inside [bounds] with a 4px margin.
Offset placeStepTip(Size size, Offset anchor, double gap, Rect bounds) {
  const m = 4.0;
  var top = anchor.dy - gap - size.height;
  if (top < bounds.top + m) top = anchor.dy + gap;
  top = top
      .clamp(
        bounds.top + m,
        math.max(bounds.top + m, bounds.bottom - size.height - m),
      )
      .toDouble();
  final left = (anchor.dx - size.width / 2)
      .clamp(
        bounds.left + m,
        math.max(bounds.left + m, bounds.right - size.width - m),
      )
      .toDouble();
  return Offset(left, top);
}
