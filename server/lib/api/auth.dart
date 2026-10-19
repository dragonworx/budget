import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/allowlist.dart';
import '../auth/google_verifier.dart';
import '../auth/middleware.dart';
import '../auth/session_store.dart';
import '../config.dart';
import '../repo/audit_repo.dart';
import '../repo/invite_repo.dart';
import '../repo/user_repo.dart';
import 'json_helpers.dart';

/// `/api/auth/*` (public: no session required).
///
///   GET  /api/auth/config     -> {googleClientId, devBypass, user|null}
///   GET  /api/auth/me         -> {user} | 401
///   POST /api/auth/google     {credential} -> {user} + Set-Cookie
///   POST /api/auth/dev-login  -> {user} + Set-Cookie   (AUTH_DEV_BYPASS only)
///   GET  /api/auth/dev-login?redirect=/ -> 302 + Set-Cookie (dev only)
///   POST /api/auth/logout     -> {ok:true}, clears cookie
///   POST /api/auth/logout-all -> {ok:true}, deletes all the user's sessions
Router buildAuthApi({
  required Config config,
  required Session db,
  required SessionStore sessions,
  required GoogleIdTokenVerifier verifier,
}) {
  final users = UserRepo(db);
  final allowlist = Allowlist(config, db);
  final router = Router();

  String? ip(Request r) =>
      r.headers['x-forwarded-for']?.split(',').first.trim() ??
      (r.context['shelf.io.connection_info'] as dynamic)?.remoteAddress?.address
          as String?;

  final invites = InviteRepo(db, secret: config.sessionSecret);
  final audit = AuditRepo(db);

  Future<Response> startSession(Request r, User user,
      {bool isDev = false,
      Response Function(Map<String, String>)? build}) async {
    // Pending invites for this email become memberships on sign-in.
    for (final inv in await invites.acceptAllFor(user.email, user.id)) {
      await audit.record(
        userId: user.id,
        action: 'invite.accepted',
        projectId: inv.projectId,
        accountId: inv.accountId,
        entityId: inv.id,
        detail: {'role': inv.role.name, 'auto': true},
      );
    }
    final token = await sessions.create(user.id,
        userAgent: r.headers['user-agent'], ip: ip(r), isDev: isDev);
    final headers = {'set-cookie': sessionCookieHeader(config, token)};
    if (build != null) return build(headers);
    final res = jsonOk({'user': user.toJson()});
    return res.change(headers: headers);
  }

  router.get('/config', (Request r) {
    final a = authOf(r);
    return jsonOk({
      'googleClientId': config.googleClientId,
      'devBypass': config.devBypass,
      'user': a?.user.toJson(),
    });
  });

  router.get('/me', (Request r) {
    final a = authOf(r);
    if (a == null) return jsonError(401, 'authentication required');
    return jsonOk({'user': a.user.toJson()});
  });

  router.post('/google', (Request r) async {
    final body = await readJsonObject(r);
    final credential = body['credential'];
    if (credential is! String || credential.isEmpty) {
      return jsonError(400, 'Missing or invalid field: credential');
    }
    final GoogleIdentity id;
    try {
      id = await verifier.verify(credential);
    } on TokenInvalid catch (e) {
      return jsonError(401, e.toString());
    }
    if (!await allowlist.allows(id.email)) {
      return jsonError(403, 'not on the allowlist',
          details: {'email': id.email});
    }
    final existing = await users.byEmail(id.email);
    if (existing != null && existing.disabled) {
      return jsonError(403, 'account disabled');
    }
    final user = await users.upsertGoogle(
      sub: id.sub,
      email: id.email,
      name: id.name,
      picture: id.picture,
      isAdmin: allowlist.isAdmin(id.email),
    );
    return startSession(r, user);
  });

  if (config.devBypass && !config.isProduction) {
    Future<User> devUser() =>
        users.ensure(config.primaryAdminEmail, isAdmin: true);
    router.post('/dev-login', (Request r) async {
      return startSession(r, await devUser(), isDev: true);
    });
    router.get('/dev-login', (Request r) async {
      var to = r.url.queryParameters['redirect'] ?? '/';
      if (!to.startsWith('/') || to.startsWith('//')) to = '/';
      return startSession(r, await devUser(),
          isDev: true, build: (h) => Response.found(to, headers: h));
    });
  }

  router.post('/logout', (Request r) async {
    final token = sessionTokenFrom(r);
    if (token != null && token.isNotEmpty) await sessions.delete(token);
    return jsonOk({'ok': true}).change(
        headers: {'set-cookie': sessionCookieHeader(config, '', clear: true)});
  });

  router.post('/logout-all', (Request r) async {
    final a = authOf(r);
    if (a == null) return jsonError(401, 'authentication required');
    await sessions.deleteAllForUser(a.user.id);
    return jsonOk({'ok': true}).change(
        headers: {'set-cookie': sessionCookieHeader(config, '', clear: true)});
  });

  return router;
}
