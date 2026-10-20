import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../engine/solver.dart' show SolverException;
import '../repo/pool_repo.dart';
import '../repo/scenario_repo.dart';
import 'goal.dart';
import 'json_helpers.dart';

const maxScenariosPerPool = 8;

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

/// `/<poolId>/scenarios` CRUD. Scenarios are what-ifs only; they never
/// touch the pool's transactions.
void attachScenarioRoutes(Router router, Session conn) {
  final pools = PoolRepo(conn);
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

  router.get('/<poolId>/scenarios', (Request r, String poolId) async {
    if (await pools.get(poolId) == null) {
      return jsonError(404, 'pool not found');
    }
    final list = await repo.listByPool(poolId);
    return jsonOk([for (final s in list) s.toJson()]);
  });

  router.post(
    '/<poolId>/scenarios',
    (Request r, String poolId) => guard(() async {
      if (await pools.get(poolId) == null) {
        return jsonError(404, 'pool not found');
      }
      final b = parseScenarioBody(await readJsonObject(r), create: true);
      final existing = await repo.listByPool(poolId);
      if (existing.length >= maxScenariosPerPool) {
        return jsonError(409, 'at most $maxScenariosPerPool scenarios');
      }
      final used = {for (final s in existing) s.colorIndex};
      final color = b.colorIndex ??
          List.generate(8, (i) => i).firstWhere(
            (i) => !used.contains(i),
            orElse: () => existing.length % 8,
          );
      final s = await repo.create(
        poolId: poolId,
        name: b.name!,
        colorIndex: color,
        included: b.included ?? true,
        request: b.request!,
      );
      return jsonOk(s.toJson(), status: 201);
    }),
  );

  Future<Response> owned(
    String poolId,
    String id,
    Future<Response> Function() f,
  ) async {
    final s = await repo.get(id);
    if (s == null || s.poolId != poolId) {
      return jsonError(404, 'scenario not found');
    }
    return f();
  }

  router.patch(
    '/<poolId>/scenarios/<id>',
    (Request r, String poolId, String id) => guard(
      () => owned(poolId, id, () async {
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
    '/<poolId>/scenarios/<id>',
    (Request r, String poolId, String id) => owned(poolId, id, () async {
      await repo.delete(id);
      return jsonOk({'deleted': id});
    }),
  );
}
