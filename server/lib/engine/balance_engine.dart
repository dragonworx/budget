import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import 'calendar_math.dart';
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
    required List<Transaction> transactions,
    required List<String> transactionOrder,
    required DateTime from,
    required DateTime to,
    Map<String, Set<DateTime>> skipped = const {},
  }) {
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

    final occurrences = OccurrenceGenerator.generate(
      transactions: transactions,
      from: rangeStart,
      to: rangeEnd,
      skipped: skipped,
    );

    final orderIndex = <String, int>{};
    for (var i = 0; i < transactionOrder.length; i++) {
      orderIndex[transactionOrder[i]] = i;
    }
    // Transactions not in transactionOrder append in creation order (createdAt).
    final creationIndex = <String, int>{};
    final sortedByCreation = [...transactions]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (var i = 0; i < sortedByCreation.length; i++) {
      creationIndex[sortedByCreation[i].id] = i;
    }

    int occurrenceRank(Occurrence o) {
      final inOrder = orderIndex[o.transactionId];
      if (inOrder != null) return inOrder;
      return transactionOrder.length + (creationIndex[o.transactionId] ?? 0);
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

    return BalanceSeries(points: points, occurrences: occurrences);
  }
}
