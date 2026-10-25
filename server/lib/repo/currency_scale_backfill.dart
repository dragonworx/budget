import 'package:postgres/postgres.dart' hide Pool;

import '../domain/models.dart';
import '../engine/balance_engine.dart';
import '../engine/calendar_math.dart';
import 'stream_repo.dart';
import 'event_repo.dart';

/// Balance span a stream's default view must hold: projects daily closing
/// balances from the seed date to a year past max(seed, today) and returns
/// max(high, 0) - min(low, 0), so zero and the whole line fit.
Future<double> streamBalanceSpan(Session conn, BudgetStream stream,
    {DateTime? today}) async {
  final txRepo = EventRepo(conn);
  final txs = await txRepo.listByStream(stream.id);
  final skipped = await txRepo.skipsForStream(stream.id);
  final now = CalendarMath.dateOnly(today ?? DateTime.now().toUtc());
  final seed = CalendarMath.dateOnly(stream.seedDate);
  final base = CalendarMath.compare(now, seed) > 0 ? now : seed;
  final to = DateTime.utc(base.year + 1, base.month, base.day);
  final series = BalanceEngine.compute(
    seedBalance: stream.seedBalance,
    seedDate: stream.seedDate,
    events: txs,
    eventOrder: stream.eventOrder,
    from: seed,
    to: to,
    skipped: skipped,
  );
  var hi = 0.0, lo = 0.0;
  final seedV = stream.seedBalance.toDouble();
  for (final v in [
    seedV,
    ...series.points.map((p) => p.closingBalance.toDouble())
  ]) {
    if (v > hi) hi = v;
    if (v < lo) lo = v;
  }
  return hi - lo;
}

/// One-time data migration: picks each existing stream's currency scale
/// from its projected balances (see [autoCurrencyScale]).
Future<void> backfillCurrencyScales(Session conn) async {
  final rows = await conn.execute('SELECT id::text FROM streams');
  final repo = StreamRepo(conn);
  for (final r in rows) {
    final stream = await repo.get(r[0] as String);
    if (stream == null) continue;
    final scale = autoCurrencyScale(await streamBalanceSpan(conn, stream));
    await repo.update(stream.id, currencyScale: scale);
  }
}
