import 'dart:ui';

import 'package:decimal/decimal.dart';

import '../../data/models.dart';
import 'zoom_level.dart';

/// What releasing a date-axis drag does, by where the pointer is.
enum PickZone {
  /// On (or just above) the date footer: create a one-off on that day.
  create,

  /// Inside the balance fill (below the line, above the footer) with a
  /// recurring series to trim: end that series on the picked day.
  trim,

  /// Anywhere else above the footer: release cancels.
  discard,
}

/// Pixels above the footer that still count as the footer (finger slop).
const double pickFooterSlop = 16;

/// Zone for a pick at screen [y]. [lineY] is the balance line's y at the
/// picked day (null when unknown); the fill is everything below it.
/// Without a trim target ([canTrim] false) the old behaviour holds: up to
/// [cancelMargin] above the footer still creates, higher cancels.
PickZone pickZone({
  required double y,
  required double axisTop,
  required double? lineY,
  required bool canTrim,
  double cancelMargin = 56,
}) {
  if (y >= axisTop - pickFooterSlop) return PickZone.create;
  final inFill = lineY != null && y >= lineY;
  if (inFill && canTrim) return PickZone.trim;
  if (!canTrim && y >= axisTop - cancelMargin) return PickZone.create;
  return PickZone.discard;
}

/// The recurring series a trim on [day] would end, and what it removes.
class TrimTarget {
  const TrimTarget(this.transaction, this.removed);
  final Transaction transaction;

  /// Occurrences (in the loaded data) after [day] that the trim drops.
  final List<Occurrence> removed;
}

/// Whether [t] can be trimmed to end on [day]: a repeating, enabled series
/// that started on or before [day] and still runs after it.
bool canTrimOn(Transaction t, DateTime day) {
  if (t.recurrenceMode != RecurrenceMode.every || !t.enabled) return false;
  final d = dateOnly(day);
  if (dateOnly(t.startDate).isAfter(d)) return false;
  final end = t.endMode == EndMode.untilDate ? t.endDate : null;
  return end == null || dateOnly(end).isAfter(d);
}

/// Picks the series to trim at [day]: among trimmable series with a loaded
/// occurrence after [day], the one whose next occurrence dot ([dotOf]) is
/// nearest [pointer] on screen. Ties go to the series added first
/// ([transactions] iterates in creation order).
TrimTarget? chooseTrimTarget({
  required DateTime day,
  required Offset pointer,
  required Map<String, Transaction> transactions,
  required List<Occurrence> occurrences,
  required Offset? Function(Occurrence) dotOf,
}) {
  final d = dateOnly(day);
  final after = <String, List<Occurrence>>{};
  for (final o in occurrences) {
    if (!dateOnly(o.date).isAfter(d)) continue;
    (after[o.transactionId] ??= []).add(o);
  }
  TrimTarget? best;
  var bestDist = double.infinity;
  for (final t in transactions.values) {
    final removed = after[t.id];
    if (removed == null || !canTrimOn(t, d)) continue;
    removed.sort((a, b) => a.date.compareTo(b.date));
    final at = dotOf(removed.first);
    final dist = at == null ? 1e9 : (at - pointer).distance;
    if (dist < bestDist) {
      bestDist = dist;
      best = TrimTarget(t, removed);
    }
  }
  return best;
}

/// [t] ending on [day] (inclusive, as the editor's "On date" end).
Transaction trimmedTransaction(Transaction t, DateTime day) => t.copyWith(
  endMode: EndMode.untilDate,
  endDate: dateOnly(day),
  clearOccurrenceCount: true,
);

/// [points] as if [removed] (non-skipped) occurrences never happened.
List<BalancePoint> trimmedPoints(
  List<BalancePoint> points,
  List<Occurrence> removed,
) {
  final deltas = [
    for (final o in removed)
      if (!o.skipped) (dateOnly(o.date), o.signedDelta),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final sorted = [...points]..sort((a, b) => a.date.compareTo(b.date));
  var i = 0;
  var cut = Decimal.zero;
  return [
    for (final p in sorted)
      () {
        while (i < deltas.length && !deltas[i].$1.isAfter(dateOnly(p.date))) {
          cut += deltas[i].$2;
          i++;
        }
        return BalancePoint(
          date: p.date,
          closingBalance: p.closingBalance - cut,
        );
      }(),
  ];
}
