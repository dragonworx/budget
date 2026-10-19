import 'package:postgres/postgres.dart';

import '../config.dart';

/// `true` when [email] matches an entry: exact address or `@domain`.
bool matchesPattern(String email, Iterable<String> patterns) {
  final e = email.toLowerCase();
  for (final p in patterns) {
    final q = p.toLowerCase();
    if (q.startsWith('@') ? e.endsWith(q) : e == q) return true;
  }
  return false;
}

/// Who may sign in: admins, AUTH_OPEN_SIGNUP, AUTH_ALLOWLIST (env),
/// `allowed_emails` (DB, admin-managed) and, when
/// AUTH_INVITES_BYPASS_ALLOWLIST, anyone with a pending invite (P3).
class Allowlist {
  Allowlist(this.config, this._db);
  final Config config;
  final Session _db;

  bool isAdmin(String email) =>
      config.adminEmails.contains(email.toLowerCase());

  Future<bool> allows(String email) async {
    final e = email.toLowerCase();
    if (isAdmin(e) || config.openSignup) return true;
    if (matchesPattern(e, config.allowlist)) return true;
    final rows = await _db.execute('SELECT pattern FROM allowed_emails');
    if (matchesPattern(e, rows.map((r) => r[0] as String))) return true;
    if (config.invitesBypassAllowlist && await _hasPendingInvite(e)) {
      return true;
    }
    return false;
  }

  Future<bool> _hasPendingInvite(String email) async {
    // The invites table arrives in P3 (migration 010).
    final t = await _db.execute("SELECT to_regclass('invites') IS NOT NULL");
    if (t.first[0] != true) return false;
    final rows = await _db.execute(
      Sql.named('SELECT 1 FROM invites WHERE lower(email) = @e '
          'AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > now() LIMIT 1'),
      parameters: {'e': email},
    );
    return rows.isNotEmpty;
  }
}
