import 'package:postgres/postgres.dart';

import '../domain/models.dart';
import '../engine/balance_engine.dart';
import '../engine/calendar_math.dart';
import 'account_repo.dart';
import 'transaction_repo.dart';

/// Balance span an account's default view must hold: projects daily closing
/// balances from the seed date to a year past max(seed, today) and returns
/// max(high, 0) - min(low, 0), so zero and the whole line fit.
Future<double> accountBalanceSpan(Session conn, Account account,
    {DateTime? today}) async {
  final txRepo = TransactionRepo(conn);
  final txs = await txRepo.listByAccount(account.id);
  final skipped = await txRepo.skipsForAccount(account.id);
  final now = CalendarMath.dateOnly(today ?? DateTime.now().toUtc());
  final seed = CalendarMath.dateOnly(account.seedDate);
  final base = CalendarMath.compare(now, seed) > 0 ? now : seed;
  final to = DateTime.utc(base.year + 1, base.month, base.day);
  final series = BalanceEngine.compute(
    seedBalance: account.seedBalance,
    seedDate: account.seedDate,
    transactions: txs,
    transactionOrder: account.transactionOrder,
    from: seed,
    to: to,
    skipped: skipped,
  );
  var hi = 0.0, lo = 0.0;
  final seedV = account.seedBalance.toDouble();
  for (final v in [seedV, ...series.points.map((p) => p.closingBalance.toDouble())]) {
    if (v > hi) hi = v;
    if (v < lo) lo = v;
  }
  return hi - lo;
}

/// One-time data migration: picks each existing account's currency scale
/// from its projected balances (see [autoCurrencyScale]).
Future<void> backfillCurrencyScales(Session conn) async {
  final rows = await conn.execute('SELECT id::text FROM accounts');
  final repo = AccountRepo(conn);
  for (final r in rows) {
    final account = await repo.get(r[0] as String);
    if (account == null) continue;
    final scale = autoCurrencyScale(await accountBalanceSpan(conn, account));
    await repo.update(account.id, currencyScale: scale);
  }
}

