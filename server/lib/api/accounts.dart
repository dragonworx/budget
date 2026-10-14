import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/models.dart';
import '../repo/account_repo.dart';
import '../repo/transaction_repo.dart';
import 'balance.dart';
import 'json_helpers.dart';
import 'solve.dart';
import 'transactions.dart' show parseTransactionBody;

/// All `/api/accounts...` routes on one router (specific paths before `/<id>`).
Router buildAccountsApi(Connection conn) {
  final accounts = AccountRepo(conn);
  final transactions = TransactionRepo(conn);
  final router = Router();

  router.get('/<accountId>/transactions', (Request request, String accountId) async {
    final account = await accounts.get(accountId);
    if (account == null) return jsonError(404, 'account not found');
    final items = await transactions.listByAccount(accountId);
    return jsonOk({'transactions': items.map((s) => s.toJson()).toList()});
  });

  router.post('/<accountId>/transactions', (Request request, String accountId) async {
    try {
      final account = await accounts.get(accountId);
      if (account == null) return jsonError(404, 'account not found');

      final body = await readJsonObject(request);
      final parsed = parseTransactionBody(body);
      final transaction = await transactions.create(
        accountId: accountId,
        name: parsed.name,
        direction: parsed.direction,
        amount: parsed.amount,
        startDate: parsed.startDate,
        recurrenceMode: parsed.recurrenceMode,
        interval: parsed.interval,
        unit: parsed.unit,
        endMode: parsed.endMode,
        endDate: parsed.endDate,
        occurrenceCount: parsed.occurrenceCount,
        enabled: parsed.enabled,
      );
      return jsonOk(transaction.toJson(), status: 201);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });

  attachBalanceRoutes(router, conn);
  attachSolveRoutes(router, conn);

  router.patch('/<id>/reorder-transactions', (Request request, String id) async {
    try {
      final body = await readJsonObject(request);
      final raw = body['transactionIds'];
      if (raw is! List) {
        return jsonError(400, 'transactionIds must be an array');
      }
      final transactionIds = raw.map((e) => e.toString()).toList();
      final account = await accounts.reorderTransactions(id, transactionIds);
      if (account == null) return jsonError(404, 'account not found');
      return jsonOk(account.toJson());
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  router.get('/<id>', (Request request, String id) async {
    final account = await accounts.get(id);
    if (account == null) return jsonError(404, 'account not found');
    return jsonOk(account.toJson());
  });

  router.patch('/<id>', (Request request, String id) async {
    try {
      final body = await readJsonObject(request);
      final account = await accounts.update(
        id,
        name: optionalString(body, 'name'),
        currency: optionalString(body, 'currency'),
        seedBalance:
            body.containsKey('seedBalance') ? parseDecimal(body['seedBalance']) : null,
        lossThreshold: body.containsKey('lossThreshold')
            ? parseDecimal(body['lossThreshold'])
            : null,
        seedDate: body.containsKey('seedDate')
            ? parseDate(requireString(body, 'seedDate'))
            : null,
        displayOrder: optionalInt(body, 'displayOrder'),
      );
      if (account == null) return jsonError(404, 'account not found');
      return jsonOk(account.toJson());
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ServerException catch (e) {
      if (e.code == '23505') {
        return jsonError(409, 'account name already exists in project');
      }
      rethrow;
    }
  });

  router.delete('/<id>', (Request request, String id) async {
    final ok = await accounts.delete(id);
    if (!ok) return jsonError(404, 'account not found');
    return Response(204);
  });

  return router;
}
