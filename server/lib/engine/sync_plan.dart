import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import 'calendar_math.dart';

/// One sync's outcome in a walk (spec 015 "API shape"): the target
/// [balance], the close [calculated] before the pin and their [drift]
/// (target − calculated). Superseded syncs carry the day's calculated
/// close and no effect; before-seed syncs have no calculated close.
class SyncRecord {
  SyncRecord({
    required this.eventId,
    required this.date,
    required this.balance,
    this.calculated,
    this.superseded = false,
    this.beforeSeed = false,
  });

  final String eventId;
  final DateTime date;
  final Decimal balance;
  final Decimal? calculated;
  final bool superseded;
  final bool beforeSeed;

  Decimal? get drift => calculated == null ? null : balance - calculated!;

  Map<String, Object?> toJson() => {
        'eventId': eventId,
        'date': formatDate(date),
        'balance': balance.toString(),
        'calculated': calculated?.toString(),
        'drift': drift?.toString(),
        'superseded': superseded,
        'beforeSeed': beforeSeed,
      };
}

/// The rank the engine orders a day's events by: the index in the stream's
/// `eventOrder`, then (events missing from it) creation order.
int Function(String eventId) eventRanker(
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
  return (id) => orderIndex[id] ?? eventOrder.length + (creationIndex[id] ?? 0);
}

/// A stream's active syncs by day (spec 015): each day's list in rank
/// order, the last one wins. Syncs before the seed have no effect and are
/// only reported ([beforeSeed]).
class SyncPlan {
  SyncPlan._(this.byDay, this.beforeSeed);

  static final empty = SyncPlan._(const {}, const []);

  final Map<DateTime, List<BudgetEvent>> byDay;
  final List<BudgetEvent> beforeSeed;

  bool get isEmpty => byDay.isEmpty && beforeSeed.isEmpty;

  static SyncPlan build(
      List<BudgetEvent> events, List<String> eventOrder, DateTime seedDate) {
    final syncs = [
      for (final e in events)
        if (e.isSync && e.active) e
    ];
    if (syncs.isEmpty) return empty;
    final seed = CalendarMath.dateOnly(seedDate);
    final rank = eventRanker(events, eventOrder);
    final byDay = <DateTime, List<BudgetEvent>>{};
    final before = <BudgetEvent>[];
    for (final e in syncs) {
      final d = CalendarMath.dateOnly(e.startDate);
      if (CalendarMath.compare(d, seed) < 0) {
        before.add(e);
      } else {
        byDay.putIfAbsent(d, () => []).add(e);
      }
    }
    for (final l in byDay.values) {
      l.sort((a, b) => rank(a.id).compareTo(rank(b.id)));
    }
    before.sort((a, b) {
      final c = CalendarMath.compare(a.startDate, b.startDate);
      return c != 0 ? c : rank(a.id).compareTo(rank(b.id));
    });
    return SyncPlan._(byDay, before);
  }

  /// The before-seed records (reported first: they precede every day).
  List<SyncRecord> beforeSeedRecords() => [
        for (final e in beforeSeed)
          SyncRecord(
            eventId: e.id,
            date: CalendarMath.dateOnly(e.startDate),
            balance: e.amount,
            beforeSeed: true,
          ),
      ];

  /// Pins [day]'s close: returns the new balance (the winner's amount, or
  /// [calculated] when the day has no sync). Adds the day's sync
  /// occurrences (superseded first, the winner last, in rank order) to
  /// [occurrences] when given, and their records to [records].
  Decimal pin(DateTime day, Decimal calculated,
      {List<Occurrence>? occurrences, required List<SyncRecord> records}) {
    final list = byDay[day];
    if (list == null) return calculated;
    final winner = list.last;
    for (final e in list) {
      final won = identical(e, winner);
      records.add(SyncRecord(
        eventId: e.id,
        date: day,
        balance: e.amount,
        calculated: calculated,
        superseded: !won,
      ));
      occurrences?.add(Occurrence(
        eventId: e.id,
        date: day,
        signedDelta: won ? e.amount - calculated : Decimal.zero,
        skipped: false,
        component: 'sync',
        syncBalance: e.amount,
        calculated: calculated,
        superseded: !won,
      ));
    }
    return winner.amount;
  }
}
