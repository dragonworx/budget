import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/models.dart';
import '../repo/account_repo.dart';
import '../repo/project_repo.dart';
import 'json_helpers.dart';

/// All `/api/projects...` routes on one router (specific paths before `/<id>`).
Router buildProjectsApi(Connection conn) {
  final projects = ProjectRepo(conn);
  final accounts = AccountRepo(conn);
  final router = Router();

  router.get('/', (Request request) async {
    final items = await projects.list();
    return jsonOk({'projects': items.map((p) => p.toJson()).toList()});
  });

  router.post('/', (Request request) async {
    try {
      final body = await readJsonObject(request);
      final name = requireString(body, 'name');
      final project = await projects.create(name);
      return jsonOk(project.toJson(), status: 201);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ServerException catch (e) {
      if (e.code == '23505') {
        return jsonError(409, 'project name already exists');
      }
      rethrow;
    }
  });

  router.get('/<projectId>/accounts', (Request request, String projectId) async {
    final project = await projects.get(projectId);
    if (project == null) return jsonError(404, 'project not found');
    final items = await accounts.listByProject(projectId);
    return jsonOk({'accounts': items.map((a) => a.toJson()).toList()});
  });

  router.post('/<projectId>/accounts', (Request request, String projectId) async {
    try {
      final project = await projects.get(projectId);
      if (project == null) return jsonError(404, 'project not found');

      final body = await readJsonObject(request);
      final name = requireString(body, 'name');
      final currency = optionalString(body, 'currency') ?? 'USD';
      if (currency.length != 3) {
        return jsonError(400, 'currency must be a 3-letter ISO code');
      }
      final seedBalance = parseDecimal(body['seedBalance'] ?? '0');
      final seedDate = parseDate(requireString(body, 'seedDate'));
      final lossThreshold = body.containsKey('lossThreshold')
          ? parseDecimal(body['lossThreshold'])
          : Decimal.zero;
      final displayOrder = optionalInt(body, 'displayOrder') ?? 0;

      final account = await accounts.create(
        projectId: projectId,
        name: name,
        currency: currency,
        seedBalance: seedBalance,
        seedDate: seedDate,
        lossThreshold: lossThreshold,
        displayOrder: displayOrder,
      );
      return jsonOk(account.toJson(), status: 201);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ServerException catch (e) {
      if (e.code == '23505') {
        return jsonError(409, 'account name already exists in project');
      }
      rethrow;
    }
  });

  router.get('/<id>', (Request request, String id) async {
    final project = await projects.get(id);
    if (project == null) return jsonError(404, 'project not found');
    return jsonOk(project.toJson());
  });

  router.patch('/<id>', (Request request, String id) async {
    try {
      final body = await readJsonObject(request);
      final name = optionalString(body, 'name');
      final project = await projects.update(id, name: name);
      if (project == null) return jsonError(404, 'project not found');
      return jsonOk(project.toJson());
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ServerException catch (e) {
      if (e.code == '23505') {
        return jsonError(409, 'project name already exists');
      }
      rethrow;
    }
  });

  router.delete('/<id>', (Request request, String id) async {
    final ok = await projects.delete(id);
    if (!ok) return jsonError(404, 'project not found');
    return Response(204);
  });

  return router;
}
