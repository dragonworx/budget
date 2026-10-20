import 'package:postgres/postgres.dart';

import '../auth/authz.dart';

class Member {
  Member(this.userId, this.email, this.name, this.pictureUrl, this.role,
      this.createdAt);
  final String userId;
  final String email;
  final String? name;
  final String? pictureUrl;
  final Role role;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'userId': userId,
        'email': email,
        'name': name,
        'pictureUrl': pictureUrl,
        'role': role.name,
        'addedAt': createdAt.toUtc().toIso8601String(),
      };
}

class PoolShare extends Member {
  PoolShare(this.poolId, this.poolName, String userId, String email,
      String? name, String? pictureUrl, Role role, DateTime createdAt)
      : super(userId, email, name, pictureUrl, role, createdAt);
  final String poolId;
  final String poolName;

  @override
  Map<String, Object?> toJson() =>
      {'poolId': poolId, 'poolName': poolName, ...super.toJson()};
}

/// Pool owners and shares.
class MembershipRepo {
  MembershipRepo(this._db);
  final Session _db;

  /// The pool's owner, as a member row with role owner.
  Future<Member?> poolOwner(String poolId) async {
    final r = await _db.execute(
      Sql.named('''
        SELECT u.id::text, u.email, u.name, u.picture_url, u.created_at
        FROM pools a JOIN users u ON u.id = a.owner_id
        WHERE a.id = @a::uuid
      '''),
      parameters: {'a': poolId},
    );
    if (r.isEmpty) return null;
    final x = r.first;
    return Member(x[0] as String, x[1] as String, x[2] as String?,
        x[3] as String?, Role.owner, x[4] as DateTime? ?? DateTime.now());
  }

  Future<List<PoolShare>> poolShares({required String poolId}) async {
    final r = await _db.execute(
      Sql.named('''
        SELECT a.id::text, a.name, u.id::text, u.email, u.name, u.picture_url,
               s.role::text, s.created_at
        FROM pool_shares s JOIN users u ON u.id = s.user_id
        JOIN pools a ON a.id = s.pool_id
        WHERE s.pool_id = @a::uuid
        ORDER BY s.created_at
      '''),
      parameters: {'a': poolId},
    );
    return r
        .map((x) => PoolShare(
            x[0] as String,
            x[1] as String,
            x[2] as String,
            x[3] as String,
            x[4] as String?,
            x[5] as String?,
            Role.parse(x[6])!,
            x[7] as DateTime))
        .toList();
  }

  Future<void> grantPool(String poolId, String userId, Role role,
      {String? addedBy}) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO pool_shares (pool_id, user_id, role, added_by)
        VALUES (@a::uuid, @u::uuid, @r::text::member_role, @by::uuid)
        ON CONFLICT (pool_id, user_id) DO UPDATE
          SET role = GREATEST(pool_shares.role, EXCLUDED.role)
      '''),
      parameters: {'a': poolId, 'u': userId, 'r': role.name, 'by': addedBy},
    );
  }

  Future<bool> setPoolRole(
      String poolId, String userId, Role role) async {
    final r = await _db.execute(
      Sql.named('''
        UPDATE pool_shares SET role = @r::text::member_role
        WHERE pool_id = @a::uuid AND user_id = @u::uuid RETURNING 1
      '''),
      parameters: {'a': poolId, 'u': userId, 'r': role.name},
    );
    return r.isNotEmpty;
  }

  Future<bool> removePoolShare(String poolId, String userId) async {
    final r = await _db.execute(
      Sql.named('DELETE FROM pool_shares '
          'WHERE pool_id = @a::uuid AND user_id = @u::uuid RETURNING 1'),
      parameters: {'a': poolId, 'u': userId},
    );
    return r.isNotEmpty;
  }
}
