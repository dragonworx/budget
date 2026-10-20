import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/authz.dart';
import '../auth/authz_middleware.dart';
import '../auth/middleware.dart';
import '../config.dart';
import '../repo/invite_repo.dart';
import '../repo/membership_repo.dart';
import '../repo/user_repo.dart';
import 'json_helpers.dart';

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

Role _parseShareRole(Map<String, dynamic> body, {Role fallback = Role.viewer}) {
  final v = body['role'];
  if (v == null) return fallback;
  final r = Role.parse(v);
  if (r == null || r == Role.owner) {
    throw const FormatException('role must be viewer or editor');
  }
  return r;
}

String _parseEmail(Map<String, dynamic> body) {
  final e = requireString(body, 'email').trim().toLowerCase();
  if (!_emailRe.hasMatch(e)) throw const FormatException('invalid email');
  return e;
}

String inviteUrl(Config c, String token) => '${c.publicOrigin}/invite/$token';

/// Invites [email] to account [accountId]: an existing user gets the share
/// at once (`status: added`), anyone else a pending invite link.
Future<Response> _invite(
    Request r, Session db, Config config, String accountId) async {
  final auth = requireAuth(r);
  final body = await readJsonObject(r);
  final email = _parseEmail(body);
  final role = _parseShareRole(body);
  final existing = await UserRepo(db).byEmail(email);
  if (existing != null) {
    if (existing.id == auth.user.id) {
      return jsonError(409, 'you already own this account');
    }
    await MembershipRepo(db)
        .grantAccount(accountId, existing.id, role, addedBy: auth.user.id);
    return jsonOk({
      'id': existing.id,
      'status': 'added',
      'member': {
        'userId': existing.id,
        'email': existing.email,
        'name': existing.name,
        'pictureUrl': existing.pictureUrl,
        'role': role.name,
      },
    }, status: 201);
  }
  final (invite, token) = await InviteRepo(db, secret: config.sessionSecret)
      .create(
          email: email,
          role: role,
          accountId: accountId,
          invitedBy: auth.user.id);
  return jsonOk({
    'id': invite.id,
    'status': 'invited',
    'invite': invite.toJson(),
    'token': token,
    'inviteUrl': inviteUrl(config, token),
  }, status: 201);
}

/// `/api/accounts/<a>/shares|invites|leave`.
void attachAccountSharingRoutes(Router router, Session db, Config config) {
  final members = MembershipRepo(db);
  final invites = InviteRepo(db, secret: config.sessionSecret);

  router.get('/<a>/shares', (Request r, String a) async {
    final access = accessOf(r)!;
    final me = requireAuth(r).user.id;
    final isOwner = access.isOwner;
    final shares = await members.accountShares(accountId: a);
    return jsonOk({
      'role': access.role!.name,
      'owner': (await members.accountOwner(a))?.toJson(),
      // The owner sees every share; others see only their own.
      'shares': isOwner
          ? shares.map((s) => s.toJson()).toList()
          : shares.where((s) => s.userId == me).map((s) => s.toJson()).toList(),
      if (isOwner)
        'invites': (await invites.pending(accountId: a))
            .map((i) => i.toJson())
            .toList(),
    });
  });

  router.post(
      '/<a>/invites', (Request r, String a) => _invite(r, db, config, a));

  router.patch('/<a>/shares/<u>', (Request r, String a, String u) async {
    final role = _parseShareRole(await readJsonObject(r));
    if (!await members.setAccountRole(a, u, role)) {
      return jsonError(404, 'share not found');
    }
    return jsonOk({'userId': u, 'role': role.name});
  });

  router.delete('/<a>/shares/<u>', (Request r, String a, String u) async {
    if (!await members.removeAccountShare(a, u)) {
      return jsonError(404, 'share not found');
    }
    return jsonOk({'removed': u});
  });

  router.post('/<a>/leave', (Request r, String a) async {
    final me = requireAuth(r).user.id;
    if (accessOf(r)!.isOwner) {
      return jsonError(409, 'the owner cannot leave their own account');
    }
    if (!await members.removeAccountShare(a, me)) {
      return jsonError(404, 'no account share to leave');
    }
    return jsonOk({'left': a});
  });
}

/// `/api/invites...`.
Router buildInvitesApi(Session db, Config config) {
  final invites = InviteRepo(db, secret: config.sessionSecret);
  final router = Router();

  router.get('/', (Request r) async {
    final me = requireAuth(r).user;
    final list = await invites.pending(email: me.email);
    return jsonOk({'invites': list.map((i) => i.toJson()).toList()});
  });

  router.post('/preview', (Request r) async {
    final me = requireAuth(r).user;
    final token = requireString(await readJsonObject(r), 'token');
    final inv = await invites.byToken(token);
    if (inv == null) return jsonError(404, 'invite not found');
    return jsonOk({
      'invite': inv.toJson(),
      'emailMatches': inv.email == me.email,
    });
  });

  router.post('/accept', (Request r) async {
    final me = requireAuth(r).user;
    final token = requireString(await readJsonObject(r), 'token');
    final inv = await invites.byToken(token);
    if (inv == null) return jsonError(404, 'invite not found');
    if (inv.status != 'pending') {
      return jsonError(410, 'invite ${inv.status}',
          details: {'status': inv.status});
    }
    if (inv.email != me.email) {
      return jsonError(403, 'this invite is for a different email',
          details: {'email': inv.email});
    }
    await invites.accept(inv, me.id);
    return jsonOk({
      'id': inv.id,
      'accountId': inv.accountId,
      'role': inv.role.name,
    });
  });

  router.post('/<i>/link', (Request r, String i) async {
    final token = await invites.rotate(i);
    if (token == null) return jsonError(410, 'invite is no longer pending');
    return jsonOk(
        {'id': i, 'token': token, 'inviteUrl': inviteUrl(config, token)});
  });

  router.delete('/<i>', (Request r, String i) async {
    if (!await invites.revoke(i)) {
      return jsonError(410, 'invite is no longer pending');
    }
    return jsonOk({'revoked': i});
  });

  return router;
}
