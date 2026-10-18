import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../engine/solver.dart' show SolverException;
import '../repo/account_repo.dart';
import '../repo/scenario_repo.dart';
import 'goal.dart';
import 'json_helpers.dart';

const maxScenariosPerAccount = 8;

/// Validated scenario fields from a create (all required bar color/included)
/// or patch (all optional) body. The request is checked by parsing it as a
/// goal request so a stored scenario can always be re-solved.
({String? name, int? colorIndex, bool? included, Map<String, dynamic>? request})
parseScenarioBody(Map<String, dynamic> body, {required bool create}) {
  String? name = optionalString(body, 'name')?.trim();
  if (create && (name == null || name.isEmpty)) {
    throw const FormatException('name is required');
  }
  if (name != null && (name.isEmpty || name.length > 80)) {
    throw const FormatException('name must be 1–80 characters');
  }
  final color = optionalInt(body, 'colorIndex');
  if (color != null && (color < 0 || color > 7)) {
    throw const FormatException('colorIndex must be 0–7');
  }
  final included = optionalBool(body, 'included');
  Map<String, dynamic>? request;
  final raw = body['request'];
  if (raw != null) {
    if (raw is! Map) throw const FormatException('request must be an object');
    request = Map<String, dynamic>.from(raw)..remove('today');
    parseGoalRequest(request); // throws on invalid input
  } else if (create) {
    throw const FormatException('request is required');
  }
  return (name: name, colorIndex: color, included: included, request: request);
}

/// `/<accountId>/scenarios` CRUD. Scenarios are what-ifs only; they never
/// touch the account's transactions.
void attachScenarioRoutes(Router router, Connection conn) {
  final accounts = AccountRepo(conn);
  final repo = ScenarioRepo(conn);

  Future<Response> guard(Future<Response> Function() f) async {
    try {
      return await f();
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on SolverException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  }

  router.get('/<accountId>/scenarios', (Request r, String accountId) async {
    if (await accounts.get(accountId) == null) {
      return jsonError(404, 'account not found');
    }
    final list = await repo.listByAccount(accountId);
    return jsonOk([for (final s in list) s.toJson()]);
  });

  router.post(
    '/<accountId>/scenarios',
    (Request r, String accountId) => guard(() async {
      if (await accounts.get(accountId) == null) {
        return jsonError(404, 'account not found');
      }
      final b = parseScenarioBody(await readJsonObject(r), create: true);
      final existing = await repo.listByAccount(accountId);
      if (existing.length >= maxScenariosPerAccount) {
        return jsonError(409, 'at most $maxScenariosPerAccount scenarios');
      }
      final used = {for (final s in existing) s.colorIndex};
      final color =
          b.colorIndex ??
          List.generate(8, (i) => i).firstWhere(
            (i) => !used.contains(i),
            orElse: () => existing.length % 8,
          );
      final s = await repo.create(
        accountId: accountId,
        name: b.name!,
        colorIndex: color,
        included: b.included ?? true,
        request: b.request!,
      );
      return jsonOk(s.toJson(), status: 201);
    }),
  );

  Future<Response> owned(
    String accountId,
    String id,
    Future<Response> Function() f,
  ) async {
    final s = await repo.get(id);
    if (s == null || s.accountId != accountId) {
      return jsonError(404, 'scenario not found');
    }
    return f();
  }

  router.patch(
    '/<accountId>/scenarios/<id>',
    (Request r, String accountId, String id) => guard(
      () => owned(accountId, id, () async {
        final b = parseScenarioBody(await readJsonObject(r), create: false);
        final s = await repo.update(
          id,
          name: b.name,
          colorIndex: b.colorIndex,
          included: b.included,
          request: b.request,
        );
        return jsonOk(s!.toJson());
      }),
    ),
  );

  router.delete(
    '/<accountId>/scenarios/<id>',
    (Request r, String accountId, String id) => owned(accountId, id, () async {
      await repo.delete(id);
      return jsonOk({'deleted': id});
    }),
  );
}
