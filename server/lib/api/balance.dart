import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/models.dart';
import '../engine/balance_engine.dart';
import '../engine/balance_insights.dart';
import '../repo/pool_repo.dart';
import '../repo/transaction_repo.dart';
import 'json_helpers.dart';
import 'transactions.dart' show parseTransactionBody;

/// Registers `GET /<id>/balance` on [router].
void attachBalanceRoutes(Router router, Session conn) {
  final pools = PoolRepo(conn);
  final transactions = TransactionRepo(conn);

  router.get('/<id>/balance', (Request request, String id) async {
    try {
      final pool = await pools.get(id);
      if (pool == null) return jsonError(404, 'pool not found');

      final params = request.url.queryParameters;
      final fromRaw = params['from'];
      final toRaw = params['to'];
      if (fromRaw == null || toRaw == null) {
        return jsonError(
            400, 'from and to query params are required (YYYY-MM-DD)');
      }
      final from = parseDate(fromRaw);
      final to = parseDate(toRaw);

      final transactionList = await transactions.listByPool(id);
      final skipped = await transactions.skipsForPool(id);

      final series = BalanceEngine.compute(
        seedBalance: pool.seedBalance,
        seedDate: pool.seedDate,
        transactions: transactionList,
        transactionOrder: pool.transactionOrder,
        from: from,
        to: to,
        skipped: skipped,
      );

      return jsonOk({
        'points': series.points.map((p) => p.toJson()).toList(),
        'occurrences': series.occurrences.map((o) => o.toJson()).toList(),
      });
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });

  /// `POST /<id>/project`: the balance as if [transactions] (unsaved, same
  /// shape as a create body) were added. Nothing is stored.
  router.post('/<id>/project', (Request request, String id) async {
    try {
      final pool = await pools.get(id);
      if (pool == null) return jsonError(404, 'pool not found');
      final body = await readJsonObject(request);
      final from = parseDate(requireString(body, 'from'));
      final to = parseDate(requireString(body, 'to'));
      final raw = body['transactions'];
      if (raw is! List) {
        return jsonError(400, 'transactions must be an array');
      }
      final extra = <Transaction>[];
      for (var i = 0; i < raw.length; i++) {
        final item = raw[i];
        if (item is! Map<String, dynamic>) {
          return jsonError(400, 'transactions[$i] must be an object');
        }
        final p = parseTransactionBody(item);
        extra.add(Transaction(
          id: 'preview-$i',
          poolId: id,
          name: p.name,
          direction: p.direction,
          amount: p.amount,
          startDate: p.startDate,
          recurrenceMode: p.recurrenceMode,
          interval: p.interval,
          unit: p.unit,
          endMode: p.endMode,
          endDate: p.endDate,
          occurrenceCount: p.occurrenceCount,
          enabled: true,
          createdAt: DateTime.now().toUtc(),
        ));
      }
      final existing = await transactions.listByPool(id);
      final series = BalanceEngine.compute(
        seedBalance: pool.seedBalance,
        seedDate: pool.seedDate,
        transactions: [...existing, ...extra],
        transactionOrder: pool.transactionOrder,
        from: from,
        to: to,
        skipped: await transactions.skipsForPool(id),
      );
      return jsonOk({
        'points': series.points.map((p) => p.toJson()).toList(),
      });
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });

  /// `GET /<id>/insights?from=YYYY-MM-DD&days=365&horizonDays=1825`:
  /// lowest closing balance over `days` from `from`, and the first dates
  /// below the alert threshold and below zero within `horizonDays`.
  router.get('/<id>/insights', (Request request, String id) async {
    try {
      final pool = await pools.get(id);
      if (pool == null) return jsonError(404, 'pool not found');
      final q = request.url.queryParameters;
      final from =
          q['from'] == null ? DateTime.now().toUtc() : parseDate(q['from']!);
      final days = int.tryParse(q['days'] ?? '') ?? 365;
      final horizon = int.tryParse(q['horizonDays'] ?? '') ?? 1825;
      if (days < 1 || horizon < 1 || days > 36500 || horizon > 36500) {
        return jsonError(400, 'days and horizonDays must be 1..36500');
      }
      final start = DateTime.utc(from.year, from.month, from.day);
      final end = start.add(Duration(days: horizon > days ? horizon : days));
      final series = BalanceEngine.compute(
        seedBalance: pool.seedBalance,
        seedDate: pool.seedDate,
        transactions: await transactions.listByPool(id),
        transactionOrder: pool.transactionOrder,
        from: start,
        to: end,
        skipped: await transactions.skipsForPool(id),
      );
      final insights = BalanceInsights.of(
        series.points,
        threshold: pool.lossThreshold.toDouble(),
        lowestThrough: start.add(Duration(days: days - 1)),
      );
      return jsonOk({
        'from': formatDate(start),
        'days': days,
        'horizonDays': horizon,
        'threshold': pool.lossThreshold.toString(),
        ...insights.toJson(),
      });
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });
}
