import 'package:postgres/postgres.dart';

import 'event.dart';

/// What one user can currently read, for filtering events.
class AccessSet {
  AccessSet(this.userId,
      {this.projects = const {},
      this.limitedProjects = const {},
      this.sharedAccounts = const {},
      this.isAdmin = false,
      this.disabled = false});

  final String userId;

  /// Projects the user is a member of (any role): every event in them.
  final Set<String> projects;

  /// Projects seen only through account shares: project-level events only.
  final Set<String> limitedProjects;

  /// Accounts shared directly with the user.
  final Set<String> sharedAccounts;
  final bool isAdmin;
  final bool disabled;

  static Future<AccessSet> load(Session db, String userId) async {
    final r = await db.execute(
      Sql.named('''
        SELECT
          ARRAY(SELECT project_id::text FROM project_members WHERE user_id = @u::uuid),
          ARRAY(SELECT s.account_id::text FROM account_shares s WHERE s.user_id = @u::uuid),
          ARRAY(SELECT DISTINCT a.project_id::text FROM account_shares s
                JOIN accounts a ON a.id = s.account_id WHERE s.user_id = @u::uuid),
          COALESCE((SELECT is_admin FROM users WHERE id = @u::uuid), false),
          COALESCE((SELECT disabled FROM users WHERE id = @u::uuid), true)
      '''),
      parameters: {'u': userId},
    );
    Set<String> set(Object? v) => {for (final x in (v as List)) x.toString()};
    final row = r.first;
    final projects = set(row[0]);
    return AccessSet(userId,
        projects: projects,
        sharedAccounts: set(row[1]),
        limitedProjects: set(row[2]).difference(projects),
        isAdmin: row[3] as bool,
        disabled: row[4] as bool);
  }

  bool touches(BudgetEvent e) =>
      (e.projectId != null &&
          (projects.contains(e.projectId) ||
              limitedProjects.contains(e.projectId))) ||
      (e.accountId != null && sharedAccounts.contains(e.accountId));

  /// Whether [e] may be delivered to this user.
  bool canRead(BudgetEvent e) {
    if (e.subjectUserId == userId) return true;
    if (e.entity == 'admin') return isAdmin;
    final p = e.projectId;
    if (p == null) return false;
    if (projects.contains(p)) return true;
    if (e.accountId != null) return sharedAccounts.contains(e.accountId);
    return limitedProjects.contains(p) && e.entity == 'project';
  }
}
