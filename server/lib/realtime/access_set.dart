import 'package:postgres/postgres.dart';

import 'event.dart';

/// What one user can currently read, for filtering events.
class AccessSet {
  AccessSet(this.userId,
      {this.ownedAccounts = const {},
      this.sharedAccounts = const {},
      this.isAdmin = false,
      this.disabled = false});

  final String userId;

  /// Accounts the user owns.
  final Set<String> ownedAccounts;

  /// Accounts shared directly with the user.
  final Set<String> sharedAccounts;
  final bool isAdmin;
  final bool disabled;

  static Future<AccessSet> load(Session db, String userId) async {
    final r = await db.execute(
      Sql.named('''
        SELECT
          ARRAY(SELECT id::text FROM accounts WHERE owner_id = @u::uuid),
          ARRAY(SELECT s.account_id::text FROM account_shares s WHERE s.user_id = @u::uuid),
          COALESCE((SELECT is_admin FROM users WHERE id = @u::uuid), false),
          COALESCE((SELECT disabled FROM users WHERE id = @u::uuid), true)
      '''),
      parameters: {'u': userId},
    );
    Set<String> set(Object? v) => {for (final x in (v as List)) x.toString()};
    final row = r.first;
    return AccessSet(userId,
        ownedAccounts: set(row[0]),
        sharedAccounts: set(row[1]),
        isAdmin: row[2] as bool,
        disabled: row[3] as bool);
  }

  bool canReadAccount(String id) =>
      ownedAccounts.contains(id) || sharedAccounts.contains(id);

  bool touches(BudgetEvent e) =>
      e.accountId != null && canReadAccount(e.accountId!);

  /// Whether [e] may be delivered to this user.
  bool canRead(BudgetEvent e) {
    if (e.subjectUserId == userId) return true;
    if (e.entity == 'admin') return isAdmin;
    final a = e.accountId;
    return a != null && canReadAccount(a);
  }
}
