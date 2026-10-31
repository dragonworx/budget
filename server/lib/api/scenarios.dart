import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../engine/solver.dart' show SolverException;
import '../repo/stream_repo.dart';
import '../repo/scenario_repo.dart';
import 'goal.dart';
import 'loan_fields.dart' show planningNotSupported;
import 'json_helpers.dart';

const maxScenariosPerStream = 8;

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

/// `/<streamId>/scenarios` CRUD. Scenarios are what-ifs only; they never
/// touch the stream's events.
void attachScenarioRoutes(Router router, Session conn) {
  final streams = StreamRepo(conn);
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

  router.get('/<streamId>/scenarios', (Request r, String streamId) async {
    if (await streams.get(streamId) == null) {
      return jsonError(404, 'stream not found');
    }
    final list = await repo.listByStream(streamId);
    return jsonOk([for (final s in list) s.toJson()]);
  });

  router.post(
    '/<streamId>/scenarios',
    (Request r, String streamId) => guard(() async {
      final stream = await streams.get(streamId);
      if (stream == null) return jsonError(404, 'stream not found');
      if (stream.hasLoan) return jsonError(409, planningNotSupported);
      final b = parseScenarioBody(await readJsonObject(r), create: true);
      final existing = await repo.listByStream(streamId);
      if (existing.length >= maxScenariosPerStream) {
        return jsonError(409, 'at most $maxScenariosPerStream scenarios');
      }
      final used = {for (final s in existing) s.colorIndex};
      final color = b.colorIndex ??
          List.generate(8, (i) => i).firstWhere(
            (i) => !used.contains(i),
            orElse: () => existing.length % 8,
          );
      final s = await repo.create(
        streamId: streamId,
        name: b.name!,
        colorIndex: color,
        included: b.included ?? true,
        request: b.request!,
      );
      return jsonOk(s.toJson(), status: 201);
    }),
  );

  Future<Response> owned(
    String streamId,
    String id,
    Future<Response> Function() f,
  ) async {
    final s = await repo.get(id);
    if (s == null || s.streamId != streamId) {
      return jsonError(404, 'scenario not found');
    }
    return f();
  }

  router.patch(
    '/<streamId>/scenarios/<id>',
    (Request r, String streamId, String id) => guard(
      () => owned(streamId, id, () async {
        if ((await streams.get(streamId))?.hasLoan ?? false) {
          return jsonError(409, planningNotSupported);
        }
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
    '/<streamId>/scenarios/<id>',
    (Request r, String streamId, String id) => owned(streamId, id, () async {
      await repo.delete(id);
      return jsonOk({'deleted': id});
    }),
  );
}
