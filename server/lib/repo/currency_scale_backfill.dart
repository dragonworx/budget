import 'package:postgres/postgres.dart' hide Pool;

import '../domain/models.dart';
import '../engine/balance_engine.dart';
import '../engine/calendar_math.dart';
import 'pool_repo.dart';
import 'transaction_repo.dart';

/// Balance span a pool's default view must hold: projects daily closing
/// balances from the seed date to a year past max(seed, today) and returns
/// max(high, 0) - min(low, 0), so zero and the whole line fit.
Future<double> poolBalanceSpan(Session conn, Pool pool,
    {DateTime? today}) async {
  final txRepo = TransactionRepo(conn);
  final txs = await txRepo.listByPool(pool.id);
  final skipped = await txRepo.skipsForPool(pool.id);
  final now = CalendarMath.dateOnly(today ?? DateTime.now().toUtc());
  final seed = CalendarMath.dateOnly(pool.seedDate);
  final base = CalendarMath.compare(now, seed) > 0 ? now : seed;
  final to = DateTime.utc(base.year + 1, base.month, base.day);
  final series = BalanceEngine.compute(
    seedBalance: pool.seedBalance,
    seedDate: pool.seedDate,
    transactions: txs,
    transactionOrder: pool.transactionOrder,
    from: seed,
    to: to,
    skipped: skipped,
  );
  var hi = 0.0, lo = 0.0;
  final seedV = pool.seedBalance.toDouble();
  for (final v in [
    seedV,
    ...series.points.map((p) => p.closingBalance.toDouble())
  ]) {
    if (v > hi) hi = v;
    if (v < lo) lo = v;
  }
  return hi - lo;
}

/// One-time data migration: picks each existing pool's currency scale
/// from its projected balances (see [autoCurrencyScale]).
Future<void> backfillCurrencyScales(Session conn) async {
  final rows = await conn.execute('SELECT id::text FROM pools');
  final repo = PoolRepo(conn);
  for (final r in rows) {
    final pool = await repo.get(r[0] as String);
    if (pool == null) continue;
    final scale = autoCurrencyScale(await poolBalanceSpan(conn, pool));
    await repo.update(pool.id, currencyScale: scale);
  }
}
