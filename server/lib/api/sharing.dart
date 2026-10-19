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

/// Shared invite-or-add logic for projects and accounts.
Future<Response> _invite(
  Request r,
  Session db,
  Config config, {
  String? projectId,
  String? accountId,
}) async {
  final auth = requireAuth(r);
  final body = await readJsonObject(r);
  final email = _parseEmail(body);
  final role = _parseShareRole(body);
  final members = MembershipRepo(db);
  final existing = await UserRepo(db).byEmail(email);
  if (existing != null) {
    // Already a project member with at least this role?
    if (projectId != null) {
      final cur = await Authz(db).projectRole(projectId, existing.id);
      if (cur != null) {
        return jsonError(409, 'already a member', details: {'role': cur.name});
      }
      await members.grantProject(projectId, existing.id, role,
          addedBy: auth.user.id);
    } else {
      await members.grantAccount(accountId!, existing.id, role,
          addedBy: auth.user.id);
    }
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
          projectId: projectId,
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

/// `/api/projects/<p>/members|invites|leave|transfer-ownership`.
void attachProjectSharingRoutes(Router router, Session db, Config config) {
  final members = MembershipRepo(db);
  final invites = InviteRepo(db, secret: config.sessionSecret);

  router.get('/<p>/members', (Request r, String p) async {
    final access = accessOf(r)!;
    final isOwner = access.projectRole == Role.owner;
    final me = requireAuth(r).user.id;
    final list = await members.projectMembers(p);
    final shares = await members.accountShares(projectId: p);
    return jsonOk({
      'role': access.role!.name,
      'members': access.limited
          ? list
              .where((m) => m.role == Role.owner)
              .map((m) => m.toJson())
              .toList()
          : list.map((m) => m.toJson()).toList(),
      'accountShares': isOwner
          ? shares.map((s) => s.toJson()).toList()
          : shares.where((s) => s.userId == me).map((s) => s.toJson()).toList(),
      if (isOwner)
        'invites': (await invites.pending(projectId: p, includeAccounts: true))
            .map((i) => i.toJson())
            .toList(),
    });
  });

  router.post('/<p>/invites',
      (Request r, String p) => _invite(r, db, config, projectId: p));

  router.patch('/<p>/members/<u>', (Request r, String p, String u) async {
    final role = _parseShareRole(await readJsonObject(r), fallback: Role.owner);
    if (role == Role.owner) {
      throw const FormatException('role must be viewer or editor');
    }
    if (!await members.setProjectRole(p, u, role)) {
      return jsonError(404, 'member not found (the owner cannot be changed)');
    }
    return jsonOk({'userId': u, 'role': role.name});
  });

  router.delete('/<p>/members/<u>', (Request r, String p, String u) async {
    if (!await members.removeProjectMember(p, u)) {
      return jsonError(404, 'member not found (the owner cannot be removed)');
    }
    return jsonOk({'removed': u});
  });

  router.post('/<p>/leave', (Request r, String p) async {
    final me = requireAuth(r).user.id;
    if (accessOf(r)!.projectRole == Role.owner) {
      return jsonError(409, 'the owner cannot leave; transfer ownership first');
    }
    await members.removeProjectMember(p, me);
    return jsonOk({'left': p});
  });

  router.post('/<p>/transfer-ownership', (Request r, String p) async {
    final me = requireAuth(r).user.id;
    final to = requireString(await readJsonObject(r), 'userId');
    if (to == me) return jsonError(400, 'already the owner');
    final role = await Authz(db).projectRole(p, to);
    if (role == null) {
      return jsonError(404, 'new owner must already be a project member');
    }
    try {
      await txOf(db).runTx((tx) => members.transferOwnership(tx, p, me, to));
    } on ServerException catch (e) {
      if (e.code == '23505') {
        return jsonError(
            409, 'the new owner already has a project with this name');
      }
      rethrow;
    }
    return jsonOk({'projectId': p, 'ownerId': to});
  });
}

/// `/api/accounts/<a>/shares|invites|leave`.
void attachAccountSharingRoutes(Router router, Session db, Config config) {
  final members = MembershipRepo(db);
  final invites = InviteRepo(db, secret: config.sessionSecret);

  router.get('/<a>/shares', (Request r, String a) async {
    final access = accessOf(r)!;
    final me = requireAuth(r).user.id;
    final isOwner = access.projectRole == Role.owner;
    final shares = await members.accountShares(accountId: a);
    return jsonOk({
      'role': access.role!.name,
      'shares': isOwner || access.projectRole != null
          ? shares.map((s) => s.toJson()).toList()
          : shares.where((s) => s.userId == me).map((s) => s.toJson()).toList(),
      if (isOwner)
        'invites': (await invites.pending(accountId: a))
            .map((i) => i.toJson())
            .toList(),
    });
  });

  router.post('/<a>/invites',
      (Request r, String a) => _invite(r, db, config, accountId: a));

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
      'projectId': inv.projectId ?? await _accountProject(db, inv.accountId!),
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

Future<String?> _accountProject(Session db, String accountId) async {
  final r = await db.execute(
      Sql.named('SELECT project_id::text FROM accounts WHERE id = @a::uuid'),
      parameters: {'a': accountId});
  return r.isEmpty ? null : r.first[0] as String;
}
