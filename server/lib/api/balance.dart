import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/models.dart';
import '../engine/balance_engine.dart';
import '../repo/account_repo.dart';
import '../repo/transaction_repo.dart';
import 'json_helpers.dart';

/// Registers `GET /<id>/balance` on [router].
void attachBalanceRoutes(Router router, Connection conn) {
  final accounts = AccountRepo(conn);
  final transactions = TransactionRepo(conn);

  router.get('/<id>/balance', (Request request, String id) async {
    try {
      final account = await accounts.get(id);
      if (account == null) return jsonError(404, 'account not found');

      final params = request.url.queryParameters;
      final fromRaw = params['from'];
      final toRaw = params['to'];
      if (fromRaw == null || toRaw == null) {
        return jsonError(
            400, 'from and to query params are required (YYYY-MM-DD)');
      }
      final from = parseDate(fromRaw);
      final to = parseDate(toRaw);

      final transactionList = await transactions.listByAccount(id);
      final skipped = await transactions.skipsForAccount(id);

      final series = BalanceEngine.compute(
        seedBalance: account.seedBalance,
        seedDate: account.seedDate,
        transactions: transactionList,
        transactionOrder: account.transactionOrder,
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
}
