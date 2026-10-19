import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/models.dart';
import '../domain/transaction_import.dart';
import '../engine/calendar_math.dart';
import '../repo/account_repo.dart';
import '../repo/transaction_repo.dart';
import 'balance.dart';
import 'json_helpers.dart';
import 'goal.dart';
import 'scenarios.dart';
import 'solve.dart';
import 'transactions.dart' show parseTransactionBody;

/// All `/api/accounts...` routes on one router (specific paths before `/<id>`).
Router buildAccountsApi(Session conn) {
  final accounts = AccountRepo(conn);
  final transactions = TransactionRepo(conn);
  final router = Router();

  router.get('/<accountId>/transactions',
      (Request request, String accountId) async {
    final account = await accounts.get(accountId);
    if (account == null) return jsonError(404, 'account not found');
    final items = await transactions.listByAccount(accountId);
    return jsonOk({'transactions': items.map((s) => s.toJson()).toList()});
  });

  router.post('/<accountId>/transactions',
      (Request request, String accountId) async {
    try {
      final account = await accounts.get(accountId);
      if (account == null) return jsonError(404, 'account not found');

      final body = await readJsonObject(request);
      final parsed = parseTransactionBody(body);
      final transferTo = optionalString(body, 'transferToAccountId');
      final skips = (body['skippedDates'] as List?)
              ?.map((e) => parseDate(e.toString()))
              .toList() ??
          const <DateTime>[];
      // A transfer creates both sides atomically.
      final transaction = await txOf(conn).runTx((tx) async {
        final transactions = TransactionRepo(tx);
        var created = await transactions.create(
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
        for (final d in skips) {
          await transactions.setSkip(created.id, d, true);
        }
        if (transferTo != null) {
          created = await transactions.linkNewPeer(created, transferTo);
        }
        return created;
      });
      return jsonOk(transaction.toJson(), status: 201);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });

  // Bulk import (see docs in transaction_import.dart). Body: the raw paste —
  // a JSON array of TransactionImport, a single object, or either wrapped in
  // a ```json fence. `?dryRun=true` validates and returns the preview only.
  // All-or-nothing: any invalid item -> 400 with per-item `issues`, nothing
  // written. Items whose `id` already exists in this account are skipped.
  router.post('/<accountId>/transactions/import',
      (Request request, String accountId) async {
    final account = await accounts.get(accountId);
    if (account == null) return jsonError(404, 'account not found');
    final dryRun = request.url.queryParameters['dryRun'] == 'true';
    final raw = await request.readAsString();
    try {
      final items = parseImport(raw);
      if (dryRun) {
        final existing = (await transactions.listByAccount(accountId))
            .map((t) => t.id)
            .toSet();
        final dupes = [
          for (final i in items)
            if (i.id != null && existing.contains(i.id)) i.index
        ];
        return jsonOk({
          'dryRun': true,
          'items': items
              .map((i) => {...i.toJson(), 'exists': dupes.contains(i.index)})
              .toList(),
          'toCreate': items.length - dupes.length,
          'toSkip': dupes.length,
        });
      }
      final result = await txOf(conn)
          .runTx((tx) => TransactionRepo(tx).importItems(accountId, items));
      return jsonOk({
        'created': result.created.length,
        'skipped': result.skipped.length,
        'createdIds': result.created,
        'skippedIds': result.skipped,
      }, status: result.created.isEmpty ? 200 : 201);
    } on ImportValidationException catch (e) {
      return jsonError(400,
          'Import rejected: ${e.issues.length} problem(s); nothing was imported',
          details: e.issues
              .map((i) => {...i.toJson(), 'text': i.toString()})
              .toList());
    }
  });

  attachBalanceRoutes(router, conn);
  attachSolveRoutes(router, conn);
  attachGoalRoutes(router, conn);
  attachScenarioRoutes(router, conn);

  router.patch('/<id>/reorder-transactions',
      (Request request, String id) async {
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
      final newSeed = body.containsKey('seedDate')
          ? parseDate(requireString(body, 'seedDate'))
          : null;
      // Seed date change moves every schedule by the same calendar-day
      // delta, atomically with the account update.
      final account = await txOf(conn).runTx((tx) async {
        final repo = AccountRepo(tx);
        final before = await repo.get(id);
        if (before == null) return null;
        final updated = await repo.update(
          id,
          name: optionalString(body, 'name'),
          currency: optionalString(body, 'currency'),
          seedBalance: body.containsKey('seedBalance')
              ? parseDecimal(body['seedBalance'])
              : null,
          lossThreshold: body.containsKey('lossThreshold')
              ? parseDecimal(body['lossThreshold'])
              : null,
          seedDate: newSeed,
          displayOrder: optionalInt(body, 'displayOrder'),
          currencyScale: parseCurrencyScale(body),
        );
        if (newSeed != null) {
          await repo.shiftSchedules(
            id,
            calendarDayDelta(before.seedDate, newSeed),
          );
        }
        return updated;
      });
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
