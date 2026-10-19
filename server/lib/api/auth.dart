import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/allowlist.dart';
import '../auth/google_verifier.dart';
import '../auth/middleware.dart';
import '../auth/session_store.dart';
import '../config.dart';
import '../hardening/client_ip.dart';
import '../repo/audit_repo.dart';
import '../repo/invite_repo.dart';
import '../repo/user_repo.dart';
import 'json_helpers.dart';

/// `/api/auth/*` (public: no session required).
///
///   GET  /api/auth/config     -> {googleClientId, devBypass, user|null}
///   GET  /api/auth/me         -> {user} | 401
///   POST /api/auth/google     {credential} -> {user} + Set-Cookie
///   POST /api/auth/google/redirect  (GIS redirect mode `login_uri`; form
///        credential + g_csrf_token) -> 303 to the app, or to the sign-in
///        page with `?error=` so the failure is shown instead of a blank page
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

  String? ip(Request r) => clientIpOf(r);

  Future<Response> startSession(Request r, User user,
      {bool isDev = false,
      Response Function(Map<String, String>)? build}) async {
    // Pending invites for this email become memberships on sign-in; each
    // grant and its audit event commit together.
    await txOf(db).runTx((tx) async {
      final txAudit = AuditRepo(tx);
      final accepted = await InviteRepo(tx, secret: config.sessionSecret)
          .acceptAllFor(user.email, user.id);
      for (final inv in accepted) {
        await txAudit.record(
          userId: user.id,
          action: 'invite.accepted',
          projectId: inv.projectId,
          accountId: inv.accountId,
          entityId: inv.id,
          subjectUserId: user.id,
          clientId: r.headers['x-client-id'],
          detail: {'role': inv.role.name, 'auto': true},
        );
      }
    });
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
      'googleUxMode': config.googleUxMode,
      'devBypass': config.devBypass,
      'user': a?.user.toJson(),
    });
  });

  router.get('/me', (Request r) {
    final a = authOf(r);
    if (a == null) return jsonError(401, 'authentication required');
    return jsonOk({'user': a.user.toJson()});
  });

  /// Verifies [credential] and signs the user in, or returns
  /// (status, message, details) describing why not.
  Future<(User?, int, String, Map<String, Object?>?)> googleUser(
      String credential) async {
    final GoogleIdentity id;
    try {
      id = await verifier.verify(credential);
    } on TokenInvalid catch (e) {
      return (null, 401, e.toString(), null);
    }
    if (!await allowlist.allows(id.email)) {
      return (
        null,
        403,
        '${id.email} is not on the allowlist. Ask the admin to add exactly '
            'this address.',
        <String, Object?>{'email': id.email},
      );
    }
    final existing = await users.byEmail(id.email);
    if (existing != null && existing.disabled) {
      return (null, 403, 'account disabled', null);
    }
    final user = await users.upsertGoogle(
      sub: id.sub,
      email: id.email,
      name: id.name,
      picture: id.picture,
      isAdmin: allowlist.isAdmin(id.email),
    );
    return (user, 200, '', null);
  }

  router.post('/google', (Request r) async {
    final body = await readJsonObject(r);
    final credential = body['credential'];
    if (credential is! String || credential.isEmpty) {
      return jsonError(400, 'Missing or invalid field: credential');
    }
    final (user, status, message, details) = await googleUser(credential);
    if (user == null) return jsonError(status, message, details: details);
    return startSession(r, user);
  });

  // GIS redirect mode: Google POSTs a form here (top-level navigation), so
  // the answer is always a redirect back into the app. CSRF is the GIS
  // double-submit token (cookie == form field), not the Origin check.
  router.post('/google/redirect', (Request r) async {
    Response back(String? error) => Response(303, headers: {
          'location': error == null
              ? '/#/'
              : '/#/sign-in?${Uri(queryParameters: {'error': error}).query}',
          'cache-control': 'no-store',
        });
    final Map<String, String> form;
    try {
      form = Uri.splitQueryString(await r.readAsString());
    } catch (_) {
      return back('Sign-in failed: unreadable response from Google.');
    }
    final credential = form['credential'] ?? '';
    final bodyCsrf = form['g_csrf_token'] ?? '';
    final cookieCsrf = cookieValue(r, 'g_csrf_token') ?? '';
    if (credential.isEmpty) {
      return back('Sign-in failed: Google did not return a credential.');
    }
    // Some browsers withhold the (SameSite-default) cookie on Google's
    // cross-site POST; then require that the POST came from Google itself.
    final fromGoogle = r.headers['origin'] == 'https://accounts.google.com';
    final csrfOk = bodyCsrf.isNotEmpty &&
        (cookieCsrf.isEmpty ? fromGoogle : bodyCsrf == cookieCsrf);
    if (!csrfOk) {
      return back('Sign-in failed: security check did not match. '
          'Please try again (cookies must be enabled).');
    }
    try {
      final (user, status, message, _) = await googleUser(credential);
      if (user == null) {
        return back(status == 401 ? 'Sign-in failed: $message' : message);
      }
      return await startSession(r, user,
          build: (h) => back(null).change(headers: h));
    } catch (e) {
      return back('Sign-in failed on the server. Please try again.');
    }
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
