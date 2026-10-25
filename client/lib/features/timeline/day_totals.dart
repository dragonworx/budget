import '../../data/models.dart';
import 'chart_geometry.dart';

/// Whether [o] counts towards a day's money in / out: the same rule as the
/// chart footer's day totals (not skipped, not a transfer netted out between
/// combined streams, and its series enabled).
bool countsInDayTotals(Occurrence o, {bool? enabled}) =>
    !o.skipped && !o.netted && enabled != false;

/// Net money per calendar day (day coord → in − out) for [series], counted
/// like the footer day totals. [enabledOf] says whether a series is enabled
/// (null: unknown, counted).
Map<int, double> dayNetTotals(
  BalanceSeries series, {
  bool? Function(String eventId)? enabledOf,
}) {
  final out = <int, double>{};
  for (final o in series.occurrences) {
    if (!countsInDayTotals(o, enabled: enabledOf?.call(o.eventId))) {
      continue;
    }
    final k = dayCoord(DateTime(o.date.year, o.date.month, o.date.day)).round();
    out[k] = (out[k] ?? 0) + o.signedDelta.toDouble();
  }
  return out;
}
