import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/middleware.dart';
import '../auth/session_store.dart';
import '../config.dart';
import 'json_helpers.dart';

final _patternRe = RegExp(r'^([^@\s]+@)?@?[^@\s]+\.[^@\s]+$');

/// `/api/admin/*` (admins only; enforced by the authz policy table).
Router buildAdminApi(Session db, Config config, SessionStore sessions) {
  final router = Router();

  router.get('/users', (Request r) async {
    final rows = await db.execute('''
      SELECT u.id::text, u.email, u.name, u.picture_url, u.is_admin, u.disabled,
             u.created_at, u.last_login_at,
             (SELECT count(*) FROM projects p WHERE p.owner_id = u.id)::int
      FROM users u ORDER BY u.created_at
    ''');
    return jsonOk({
      'users': rows
          .map((x) => {
                'id': x[0],
                'email': x[1],
                'name': x[2],
                'pictureUrl': x[3],
                'isAdmin': x[4],
                'disabled': x[5],
                'createdAt': (x[6] as DateTime).toUtc().toIso8601String(),
                'lastLoginAt': (x[7] as DateTime?)?.toUtc().toIso8601String(),
                'ownedProjects': x[8],
              })
          .toList(),
    });
  });

  router.patch('/users/<u>', (Request r, String u) async {
    final body = await readJsonObject(r);
    final disabled = optionalBool(body, 'disabled');
    if (disabled == null) {
      throw const FormatException('Missing field: disabled');
    }
    if (u == requireAuth(r).user.id && disabled) {
      return jsonError(400, 'you cannot disable yourself');
    }
    final rows = await db.execute(
      Sql.named('UPDATE users SET disabled = @d WHERE id = @u::uuid '
          'RETURNING id::text, email, disabled'),
      parameters: {'u': u, 'd': disabled},
    );
    if (rows.isEmpty) return jsonError(404, 'user not found');
    if (disabled) await sessions.deleteAllForUser(u);
    return jsonOk({
      'id': rows.first[0],
      'email': rows.first[1],
      'disabled': rows.first[2]
    });
  });

  router.get('/allowlist', (Request r) async {
    final rows = await db.execute('''
      SELECT a.pattern, a.created_at, u.email FROM allowed_emails a
      LEFT JOIN users u ON u.id = a.added_by ORDER BY a.pattern
    ''');
    return jsonOk({
      'env': config.allowlist,
      'admins': config.adminEmails,
      'openSignup': config.openSignup,
      'invitesBypassAllowlist': config.invitesBypassAllowlist,
      'entries': rows
          .map((x) => {
                'pattern': x[0],
                'createdAt': (x[1] as DateTime).toUtc().toIso8601String(),
                'addedBy': x[2],
              })
          .toList(),
    });
  });

  router.post('/allowlist', (Request r) async {
    final pattern =
        requireString(await readJsonObject(r), 'pattern').trim().toLowerCase();
    if (!_patternRe.hasMatch(pattern) || pattern.contains(' ')) {
      return jsonError(400, 'pattern must be an email or @domain');
    }
    await db.execute(
      Sql.named('INSERT INTO allowed_emails (pattern, added_by) '
          'VALUES (@p, @u::uuid) ON CONFLICT DO NOTHING'),
      parameters: {'p': pattern, 'u': requireAuth(r).user.id},
    );
    return jsonOk({'id': pattern, 'pattern': pattern}, status: 201);
  });

  router.delete('/allowlist/<pattern>', (Request r, String pattern) async {
    final p = Uri.decodeComponent(pattern).toLowerCase();
    final rows = await db.execute(
      Sql.named('DELETE FROM allowed_emails WHERE pattern = @p RETURNING 1'),
      parameters: {'p': p},
    );
    if (rows.isEmpty) return jsonError(404, 'pattern not found');
    return jsonOk({'removed': p});
  });

  return router;
}
