import 'package:postgres/postgres.dart';

import 'event.dart';

/// What one user can currently read, for filtering events.
class AccessSet {
  AccessSet(this.userId,
      {this.ownedPools = const {},
      this.sharedPools = const {},
      this.isAdmin = false,
      this.disabled = false});

  final String userId;

  /// Pools the user owns.
  final Set<String> ownedPools;

  /// Pools shared directly with the user.
  final Set<String> sharedPools;
  final bool isAdmin;
  final bool disabled;

  static Future<AccessSet> load(Session db, String userId) async {
    final r = await db.execute(
      Sql.named('''
        SELECT
          ARRAY(SELECT id::text FROM pools WHERE owner_id = @u::uuid),
          ARRAY(SELECT s.pool_id::text FROM pool_shares s WHERE s.user_id = @u::uuid),
          COALESCE((SELECT is_admin FROM users WHERE id = @u::uuid), false),
          COALESCE((SELECT disabled FROM users WHERE id = @u::uuid), true)
      '''),
      parameters: {'u': userId},
    );
    Set<String> set(Object? v) => {for (final x in (v as List)) x.toString()};
    final row = r.first;
    return AccessSet(userId,
        ownedPools: set(row[0]),
        sharedPools: set(row[1]),
        isAdmin: row[2] as bool,
        disabled: row[3] as bool);
  }

  bool canReadPool(String id) =>
      ownedPools.contains(id) || sharedPools.contains(id);

  bool touches(BudgetEvent e) =>
      e.poolId != null && canReadPool(e.poolId!);

  /// Whether [e] may be delivered to this user.
  bool canRead(BudgetEvent e) {
    if (e.subjectUserId == userId) return true;
    if (e.entity == 'admin') return isAdmin;
    final a = e.poolId;
    return a != null && canReadPool(a);
  }
}
