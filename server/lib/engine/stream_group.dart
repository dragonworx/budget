import 'package:budget_loan/budget_loan.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';

import '../domain/models.dart';
import '../repo/event_repo.dart';
import '../repo/stream_repo.dart';
import 'balance_engine.dart';
import 'calendar_math.dart';
import 'loan_walk.dart';

/// One offset stream of a loan (spec 004), loaded for the walk.
class OffsetSource {
  OffsetSource({
    required this.stream,
    required this.events,
    this.skipped = const {},
  });

  final BudgetStream stream;
  final List<BudgetEvent> events;
  final Map<String, Set<DateTime>> skipped;

  /// `max(0, threshold)`: the account's "zero" for the offset.
  Decimal get thresholdUsed => OffsetMath.thresholdUsed(stream.lossThreshold);

  /// Usable balance per day from the offset's seed through [to], from its
  /// own series computed with the unchanged [BalanceEngine.compute] (a
  /// standard stream: rule 2 keeps loans out of offset streams). Days with
  /// no usable balance are left out.
  Map<DateTime, Decimal> usableThrough(DateTime to) {
    final seed = CalendarMath.dateOnly(stream.seedDate);
    final end = CalendarMath.dateOnly(to);
    if (end.isBefore(seed)) return const {};
    final series = BalanceEngine.compute(
      seedBalance: stream.seedBalance,
      seedDate: seed,
      events: events,
      eventOrder: stream.eventOrder,
      from: seed,
      to: end,
      skipped: skipped,
    );
    final z = stream.lossThreshold;
    return {
      for (final p in series.points)
        if (OffsetMath.usable(p.closingBalance, z) case final u
            when u > Decimal.zero)
          p.date: u,
    };
  }
}

/// A loan stream with its offset streams: the one place balance, project,
/// insights and loan-summary compute a loan from (spec 004 §11).
///
/// Order: each offset stream's series is computed in full first, then the
/// loan walk reads its closing balance on the same day (§10). That is only
/// sound because nothing an offset stream holds depends on the loan:
/// transfers are fixed amounts stored on both sides and interest lands in
/// the loan stream alone, and offset streams cannot hold a loan (no chains,
/// no cycles). If a later feature adds amounts computed across streams
/// (e.g. automatic "paid from" repayments sized from the loan), switch to a
/// lockstep walk in which the loan reads the offset's previous-day close.
class LoanGroup {
  const LoanGroup(this.offsets);

  /// No offsets: the loan (or standard stream) computes exactly as before.
  const LoanGroup.empty() : offsets = const [];
  static const none = LoanGroup.empty();

  final List<OffsetSource> offsets;

  bool get isEmpty => offsets.isEmpty;

  /// The usable offset per day through [to], summed over the offsets; null
  /// when there are none (the walk is then the phase 1 walk, unchanged).
  OffsetUsable? usableThrough(DateTime to) {
    if (offsets.isEmpty) return null;
    final maps = [for (final o in offsets) o.usableThrough(to)];
    if (maps.length == 1) {
      final m = maps.single;
      return (d) => m[d] ?? Decimal.zero;
    }
    return (d) => maps.fold(Decimal.zero, (a, m) => a + (m[d] ?? Decimal.zero));
  }

  /// [BalanceEngine.compute] for the group's loan stream.
  BalanceSeries compute({
    required BudgetStream stream,
    required List<BudgetEvent> events,
    required DateTime from,
    required DateTime to,
    Map<String, Set<DateTime>> skipped = const {},
  }) =>
      BalanceEngine.compute(
        seedBalance: stream.seedBalance,
        seedDate: stream.seedDate,
        events: events,
        eventOrder: stream.eventOrder,
        from: from,
        to: to,
        skipped: skipped,
        offsetUsable: usableThrough(to),
      );

  /// Loads the offsets of [events]' active reducing-balance loan. Ids that
  /// no longer load, belong to another owner, are the stream itself or now
  /// hold a loan are skipped (defensive: the API and stream delete keep the
  /// ids valid). [LoanGroup.none] when there is nothing to load.
  static Future<LoanGroup> load(
      Session conn, BudgetStream stream, List<BudgetEvent> events,
      {List<String>? offsetStreamIds}) async {
    final loan = LoanWalk.activeLoan(events);
    if (loan == null || loan.loan!.isFlat) return none;
    final ids = offsetStreamIds ?? loan.offsetStreamIds;
    if (ids.isEmpty) return none;
    final streams = StreamRepo(conn);
    final repo = EventRepo(conn);
    final out = <OffsetSource>[];
    for (final id in ids.toSet()) {
      if (id == stream.id) continue;
      final s = await streams.get(id);
      if (s == null || s.ownerId != stream.ownerId || s.hasLoan) continue;
      out.add(OffsetSource(
        stream: s,
        events: await repo.listByStream(id),
        skipped: await repo.skipsForStream(id),
      ));
    }
    return out.isEmpty ? none : LoanGroup(out);
  }
}

/// Loads [stream]'s events, skips and offsets and computes its balance:
/// `computeLoanGroup` of spec 004 §11 for any stream (standard streams and
/// loans without offsets take the unchanged path).
Future<BalanceSeries> computeLoanGroup(
  Session conn,
  BudgetStream stream, {
  required DateTime from,
  required DateTime to,
}) async {
  final repo = EventRepo(conn);
  final events = await repo.listByStream(stream.id);
  final skipped = await repo.skipsForStream(stream.id);
  final group = await LoanGroup.load(conn, stream, events);
  return group.compute(
      stream: stream, events: events, from: from, to: to, skipped: skipped);
}
