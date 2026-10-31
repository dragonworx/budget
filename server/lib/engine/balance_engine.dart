import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import 'calendar_math.dart';
import 'loan_walk.dart';
import 'occurrence_gen.dart';

class BalanceSeries {
  BalanceSeries({
    required this.points,
    required this.occurrences,
  });

  final List<BalancePoint> points;
  final List<Occurrence> occurrences;
}

/// Pure daily closing-balance series (§3).
class BalanceEngine {
  /// Computes closing balance for each day in `[from, to]` when that range
  /// intersects dates `>= seedDate`. Days before [seedDate] are omitted.
  static BalanceSeries compute({
    required Decimal seedBalance,
    required DateTime seedDate,
    required List<BudgetEvent> events,
    required List<String> eventOrder,
    required DateTime from,
    required DateTime to,
    Map<String, Set<DateTime>> skipped = const {},
    OffsetUsable? offsetUsable,
  }) {
    // A stream with an active loan takes the loan walk (spec 002); every
    // other stream keeps the code below, unchanged.
    final loan = LoanWalk.activeLoan(events);
    if (loan != null) {
      return LoanWalk.compute(
        seedBalance: seedBalance,
        seedDate: seedDate,
        events: events,
        eventOrder: eventOrder,
        from: from,
        to: to,
        loan: loan,
        skipped: skipped,
        offsetUsable: offsetUsable,
      ).series;
    }
    final seed = CalendarMath.dateOnly(seedDate);
    var rangeStart = CalendarMath.dateOnly(from);
    final rangeEnd = CalendarMath.dateOnly(to);

    if (CalendarMath.compare(rangeEnd, rangeStart) < 0) {
      throw ArgumentError('to must be >= from');
    }

    // No series before seedDate.
    if (CalendarMath.compare(rangeEnd, seed) < 0) {
      return BalanceSeries(points: const [], occurrences: const []);
    }
    if (CalendarMath.compare(rangeStart, seed) < 0) {
      rangeStart = seed;
    }

    // Generate from the seed: occurrences before the requested window still
    // move the opening balance. Only in-window ones are returned.
    final occurrences = OccurrenceGenerator.generate(
      events: events,
      from: seed,
      to: rangeEnd,
      skipped: skipped,
    );

    final orderIndex = <String, int>{};
    for (var i = 0; i < eventOrder.length; i++) {
      orderIndex[eventOrder[i]] = i;
    }
    // Events not in eventOrder append in creation order (createdAt).
    final creationIndex = <String, int>{};
    final sortedByCreation = [...events]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (var i = 0; i < sortedByCreation.length; i++) {
      creationIndex[sortedByCreation[i].id] = i;
    }

    int occurrenceRank(Occurrence o) {
      final inOrder = orderIndex[o.eventId];
      if (inOrder != null) return inOrder;
      return eventOrder.length + (creationIndex[o.eventId] ?? 0);
    }

    occurrences.sort((a, b) {
      final byDate = CalendarMath.compare(a.date, b.date);
      if (byDate != 0) return byDate;
      return occurrenceRank(a).compareTo(occurrenceRank(b));
    });

    final byDate = <DateTime, List<Occurrence>>{};
    for (final o in occurrences) {
      byDate.putIfAbsent(o.date, () => []).add(o);
    }

    // Walk from seed to rangeEnd so opening balances stay correct even when
    // the requested window starts after seedDate.
    var balance = seedBalance;
    final points = <BalancePoint>[];
    var cursor = seed;
    while (CalendarMath.compare(cursor, rangeEnd) <= 0) {
      final dayOcc = byDate[cursor] ?? const <Occurrence>[];
      for (final o in dayOcc) {
        if (!o.skipped) {
          balance += o.signedDelta;
        }
      }
      if (CalendarMath.compare(cursor, rangeStart) >= 0) {
        points.add(BalancePoint(date: cursor, closingBalance: balance));
      }
      cursor = cursor.add(const Duration(days: 1));
    }

    return BalanceSeries(
      points: points,
      occurrences: [
        for (final o in occurrences)
          if (CalendarMath.compare(o.date, rangeStart) >= 0) o,
      ],
    );
  }

  /// Sorts [occurrences] as [compute] does: by date, then by [eventOrder],
  /// then events missing from it in creation order. (The loan walk's copy
  /// of [compute]'s ordering; [compute] keeps its own inline code.)
  static void sortOccurrences(List<Occurrence> occurrences,
      List<BudgetEvent> events, List<String> eventOrder) {
    final orderIndex = <String, int>{};
    for (var i = 0; i < eventOrder.length; i++) {
      orderIndex[eventOrder[i]] = i;
    }
    final creationIndex = <String, int>{};
    final sortedByCreation = [...events]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (var i = 0; i < sortedByCreation.length; i++) {
      creationIndex[sortedByCreation[i].id] = i;
    }
    int rank(Occurrence o) =>
        orderIndex[o.eventId] ??
        eventOrder.length + (creationIndex[o.eventId] ?? 0);
    occurrences.sort((a, b) {
      final byDate = CalendarMath.compare(a.date, b.date);
      if (byDate != 0) return byDate;
      return rank(a).compareTo(rank(b));
    });
  }
}
