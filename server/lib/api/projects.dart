import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/authz.dart';
import '../auth/authz_middleware.dart';
import '../auth/middleware.dart';
import '../domain/models.dart';
import '../repo/account_repo.dart';
import '../repo/project_repo.dart';
import 'json_helpers.dart';

/// All `/api/projects...` routes on one router (specific paths before `/<id>`).
Router buildProjectsApi(Session conn) {
  final projects = ProjectRepo(conn);
  final accounts = AccountRepo(conn);
  final router = Router();

  router.get('/', (Request request) async {
    final items = await projects.listAccessible(requireAuth(request).user.id);
    return jsonOk({'projects': items});
  });

  router.post('/', (Request request) async {
    try {
      final body = await readJsonObject(request);
      final name = requireString(body, 'name');
      final project =
          await projects.create(name, ownerId: requireAuth(request).user.id);
      return jsonOk({...project.toJson(), 'role': 'owner'}, status: 201);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ServerException catch (e) {
      if (e.code == '23505') {
        return jsonError(409, 'project name already exists');
      }
      rethrow;
    }
  });

  router.get('/<projectId>/accounts',
      (Request request, String projectId) async {
    final project = await projects.get(projectId);
    if (project == null) return jsonError(404, 'project not found');
    final access = accessOf(request)!;
    final me = requireAuth(request).user.id;
    final shared = await _sharedRoles(conn, projectId, me);
    final items = (await accounts.listByProject(projectId))
        .where((a) => !access.limited || shared.containsKey(a.id))
        .map((a) => {
              ...a.toJson(),
              'role':
                  (Role.max(access.projectRole, shared[a.id]) ?? Role.viewer)
                      .name,
            })
        .toList();
    return jsonOk({'accounts': items});
  });

  router.post('/<projectId>/accounts',
      (Request request, String projectId) async {
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
        // No explicit choice: pick from the seed balance (no transactions
        // exist yet), like the dialog's preselected value.
        currencyScale: parseCurrencyScale(body) ??
            autoCurrencyScale(seedBalance.toDouble()),
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
    final access = accessOf(request)!;
    return jsonOk({
      ...project.toJson(),
      'role': access.role!.name,
      'access': access.limited ? 'account' : 'project',
    });
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

/// accountId -> role for accounts in [projectId] shared directly with [userId].
Future<Map<String, Role>> _sharedRoles(
    Session db, String projectId, String userId) async {
  final rows = await db.execute(
    Sql.named('''
      SELECT s.account_id::text, s.role::text FROM account_shares s
      JOIN accounts a ON a.id = s.account_id
      WHERE a.project_id = @p::uuid AND s.user_id = @u::uuid
    '''),
    parameters: {'p': projectId, 'u': userId},
  );
  return {for (final r in rows) r[0] as String: Role.parse(r[1])!};
}
