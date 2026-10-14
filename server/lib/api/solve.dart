import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../engine/solver.dart';
import '../repo/account_repo.dart';
import 'json_helpers.dart';

/// Registers `POST /<accountId>/solve` on [router].
void attachSolveRoutes(Router router, Connection conn) {
  final accounts = AccountRepo(conn);

  router.post('/<accountId>/solve', (Request request, String accountId) async {
    try {
      final account = await accounts.get(accountId);
      if (account == null) return jsonError(404, 'account not found');

      final body = await readJsonObject(request);
      final direction = Direction.parse(requireString(body, 'direction'));
      final unit = RecurrenceUnit.parse(requireString(body, 'unit'));
      final roundingRaw = optionalString(body, 'rounding');

      final req = SolveRequest(
        direction: direction,
        unit: unit,
        name: optionalString(body, 'name') ?? '',
        startDate: optionalString(body, 'startDate') == null
            ? null
            : parseDate(body['startDate'].toString()),
        endDate: optionalString(body, 'endDate') == null
            ? null
            : parseDate(body['endDate'].toString()),
        amount: body.containsKey('amount') ? parseDecimal(body['amount']) : null,
        interval: optionalInt(body, 'interval'),
        occurrenceCount: optionalInt(body, 'occurrenceCount'),
        targetTotal: body.containsKey('targetTotal')
            ? parseDecimal(body['targetTotal'])
            : null,
        rounding: roundingRaw == null
            ? RoundingMode.nearest
            : RoundingMode.parse(roundingRaw),
        enabled: optionalBool(body, 'enabled') ?? true,
      );

      final result = TransactionSolver.solve(req);
      final json = result.toJson();
      final transaction = result.transaction;
      if (transaction != null) {
        json['transaction'] = transaction.copyWith(accountId: accountId).toJson();
      }
      return jsonOk(json);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on SolverException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });
}
