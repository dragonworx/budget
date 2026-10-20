import 'package:postgres/postgres.dart';

/// Roles, ordered: viewer < editor < owner.
enum Role {
  viewer,
  editor,
  owner;

  static Role? parse(Object? v) {
    if (v == null) return null;
    for (final r in Role.values) {
      if (r.name == v.toString()) return r;
    }
    return null;
  }

  bool atLeast(Role other) => index >= other.index;
  static Role? max(Role? a, Role? b) =>
      a == null ? b : (b == null ? a : (a.index >= b.index ? a : b));
}

/// What a resolved request may do, attached as `request.context['access']`.
class Access {
  Access({
    this.role,
    this.accountId,
    this.params = const {},
  });

  /// Effective role on the target (null for scope `auth`/`admin`): owner
  /// for the account's owner, else the account share's role.
  final Role? role;
  final String? accountId;
  final Map<String, String> params;

  bool get isOwner => role == Role.owner;
}

/// How a route's target is resolved to a role.
enum Scope {
  /// Any signed-in user; no resource.
  auth,

  /// Admin users only.
  admin,

  /// `:a`: owner if the user owns it, else their account share's role.
  account,

  /// `:t` via its account.
  transaction,

  /// `:i` (invite id) via the invite's account.
  invite,
}

class Policy {
  const Policy(this.method, this.path, this.scope,
      {this.min = Role.viewer, this.event, this.versioned});

  final String method;

  /// Path below `/api/`, `:x` segments are parameters.
  final String path;
  final Scope scope;
  final Role min;

  /// Audit/realtime action name for mutations (e.g. `transaction.updated`).
  final String? event;

  /// Table whose `version` a PATCH must match (optimistic concurrency).
  final String? versioned;

  List<String> get segments => path.split('/');

  Map<String, String>? match(String m, List<String> segs) {
    if (m != method && !(m == 'HEAD' && method == 'GET')) return null;
    final p = segments;
    if (p.length != segs.length) return null;
    final params = <String, String>{};
    for (var i = 0; i < p.length; i++) {
      if (p[i].startsWith(':')) {
        if (segs[i].isEmpty) return null;
        params[p[i].substring(1)] = segs[i];
      } else if (p[i] != segs[i]) {
        return null;
      }
    }
    return params;
  }
}

const _e = Role.editor, _o = Role.owner;

/// Every authenticated `/api` route. Anything not listed is denied (404);
/// `test/authz/route_sweep_test.dart` checks each router route has an entry.
const policies = <Policy>[
  // Accounts
  Policy('GET', 'accounts', Scope.auth),
  Policy('POST', 'accounts', Scope.auth, event: 'account.created'),
  Policy('GET', 'accounts/:a', Scope.account),
  // Remember the last-opened account (landing after sign-in). No event.
  Policy('POST', 'accounts/:a/opened', Scope.account),
  Policy('PATCH', 'accounts/:a', Scope.account,
      min: _e, event: 'account.updated', versioned: 'accounts'),
  Policy('DELETE', 'accounts/:a', Scope.account,
      min: _o, event: 'account.deleted'),
  Policy('GET', 'accounts/:a/transactions', Scope.account),
  Policy('POST', 'accounts/:a/transactions', Scope.account,
      min: _e, event: 'transaction.created'),
  Policy('POST', 'accounts/:a/transactions/import', Scope.account,
      min: _e, event: 'transactions.imported'),
  Policy('PATCH', 'accounts/:a/reorder-transactions', Scope.account,
      min: _e, event: 'account.reordered'),
  Policy('GET', 'accounts/:a/balance', Scope.account),
  Policy('POST', 'accounts/:a/project', Scope.account),
  Policy('GET', 'accounts/:a/insights', Scope.account),
  Policy('POST', 'accounts/:a/solve', Scope.account),
  Policy('POST', 'accounts/:a/goal', Scope.account),
  Policy('GET', 'accounts/:a/scenarios', Scope.account),
  Policy('POST', 'accounts/:a/scenarios', Scope.account,
      min: _e, event: 'scenario.created'),
  Policy('PATCH', 'accounts/:a/scenarios/:s', Scope.account,
      min: _e, event: 'scenario.updated', versioned: 'scenarios'),
  Policy('DELETE', 'accounts/:a/scenarios/:s', Scope.account,
      min: _e, event: 'scenario.deleted'),
  // Account sharing
  Policy('GET', 'accounts/:a/shares', Scope.account),
  Policy('POST', 'accounts/:a/invites', Scope.account,
      min: _o, event: 'invite.created'),
  Policy('PATCH', 'accounts/:a/shares/:u', Scope.account,
      min: _o, event: 'account_share.changed'),
  Policy('DELETE', 'accounts/:a/shares/:u', Scope.account,
      min: _o, event: 'account_share.revoked'),
  Policy('POST', 'accounts/:a/leave', Scope.account,
      event: 'account_share.left'),
  // Transactions
  Policy('GET', 'transactions/:t', Scope.transaction),
  Policy('PATCH', 'transactions/:t', Scope.transaction,
      min: _e, event: 'transaction.updated', versioned: 'transactions'),
  Policy('DELETE', 'transactions/:t', Scope.transaction,
      min: _e, event: 'transaction.deleted'),
  Policy('PUT', 'transactions/:t/skips/:d', Scope.transaction,
      min: _e, event: 'skip.changed'),
  Policy('PUT', 'transactions/:t/overrides/:d', Scope.transaction,
      min: _e, event: 'transaction.override_set', versioned: 'transactions'),
  Policy('DELETE', 'transactions/:t/overrides/:d', Scope.transaction,
      min: _e,
      event: 'transaction.override_cleared',
      versioned: 'transactions'),
  Policy('DELETE', 'transactions/:t/overrides', Scope.transaction,
      min: _e,
      event: 'transaction.overrides_cleared',
      versioned: 'transactions'),
  Policy('POST', 'transactions/:t/split', Scope.transaction,
      min: _e, event: 'transaction.split', versioned: 'transactions'),
  // Invites
  Policy('GET', 'invites', Scope.auth),
  Policy('POST', 'invites/preview', Scope.auth),
  Policy('POST', 'invites/accept', Scope.auth, event: 'invite.accepted'),
  Policy('POST', 'invites/:i/link', Scope.invite,
      min: _o, event: 'invite.link_rotated'),
  Policy('DELETE', 'invites/:i', Scope.invite,
      min: _o, event: 'invite.revoked'),
  // Realtime (SSE; per-event filtering happens in the stream)
  Policy('GET', 'events', Scope.auth),
  // Admin
  Policy('GET', 'admin/users', Scope.admin),
  Policy('PATCH', 'admin/users/:u', Scope.admin, event: 'admin.user_updated'),
  Policy('GET', 'admin/allowlist', Scope.admin),
  Policy('POST', 'admin/allowlist', Scope.admin,
      event: 'admin.allowlist_added'),
  Policy('DELETE', 'admin/allowlist/:pattern', Scope.admin,
      event: 'admin.allowlist_removed'),
];

/// Finds the policy for `METHOD /api/<segs>`; null means deny.
(Policy, Map<String, String>)? findPolicy(String method, List<String> segs) {
  for (final p in policies) {
    final m = p.match(method, segs);
    if (m != null) return (p, m);
  }
  return null;
}

final uuidRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false);

/// Role lookups (one query each).
class Authz {
  Authz(this._db);
  final Session _db;

  /// Effective access to an account: owner, else its share role.
  Future<Access?> account(String accountId, String userId) async {
    if (!uuidRe.hasMatch(accountId)) return null;
    final r = await _db.execute(
      Sql.named('''
        SELECT CASE WHEN a.owner_id = @u::uuid THEN 'owner'
                    ELSE s.role::text END
        FROM accounts a
        LEFT JOIN account_shares s
          ON s.account_id = a.id AND s.user_id = @u::uuid
        WHERE a.id = @a::uuid
      '''),
      parameters: {'a': accountId, 'u': userId},
    );
    if (r.isEmpty) return null;
    final role = Role.parse(r.first[0]);
    if (role == null) return null;
    return Access(role: role, accountId: accountId);
  }

  /// Accounts (of [ids]) that [userId] can read.
  Future<Set<String>> readableAccounts(
      Iterable<String> ids, String userId) async {
    final list = ids.where(uuidRe.hasMatch).toSet().toList();
    if (list.isEmpty) return {};
    final r = await _db.execute(
      Sql.named('''
        SELECT a.id::text FROM accounts a
        WHERE a.id = ANY (@ids::uuid[]) AND (
          a.owner_id = @u::uuid
          OR EXISTS (SELECT 1 FROM account_shares s
                  WHERE s.account_id = a.id AND s.user_id = @u::uuid))
      '''),
      parameters: {'ids': list, 'u': userId},
    );
    return {for (final row in r) row[0] as String};
  }

  /// (accountId, peer accountId?) for a transaction.
  Future<(String, String?)?> transactionAccounts(String txId) async {
    if (!uuidRe.hasMatch(txId)) return null;
    final r = await _db.execute(
      Sql.named('''
        SELECT t.account_id::text, p.account_id::text FROM transactions t
        LEFT JOIN transactions p ON t.transfer_id IS NOT NULL
          AND p.transfer_id = t.transfer_id AND p.id <> t.id
        WHERE t.id = @t::uuid
      '''),
      parameters: {'t': txId},
    );
    if (r.isEmpty) return null;
    return (r.first[0] as String, r.first[1] as String?);
  }

  /// The account an invite targets.
  Future<String?> inviteAccount(String inviteId) async {
    if (!uuidRe.hasMatch(inviteId)) return null;
    final r = await _db.execute(
      Sql.named('SELECT account_id::text FROM invites WHERE id = @i::uuid'),
      parameters: {'i': inviteId},
    );
    return r.isEmpty ? null : r.first[0] as String?;
  }
}
