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

class AccountShare extends Member {
  AccountShare(this.accountId, this.accountName, String userId, String email,
      String? name, String? pictureUrl, Role role, DateTime createdAt)
      : super(userId, email, name, pictureUrl, role, createdAt);
  final String accountId;
  final String accountName;

  @override
  Map<String, Object?> toJson() =>
      {'accountId': accountId, 'accountName': accountName, ...super.toJson()};
}

/// Project members and account shares.
class MembershipRepo {
  MembershipRepo(this._db);
  final Session _db;

  Future<List<Member>> projectMembers(String projectId) async {
    final r = await _db.execute(
      Sql.named('''
        SELECT u.id::text, u.email, u.name, u.picture_url, m.role::text, m.created_at
        FROM project_members m JOIN users u ON u.id = m.user_id
        WHERE m.project_id = @p::uuid
        ORDER BY (m.role = 'owner') DESC, m.created_at
      '''),
      parameters: {'p': projectId},
    );
    return r
        .map((x) => Member(x[0] as String, x[1] as String, x[2] as String?,
            x[3] as String?, Role.parse(x[4])!, x[5] as DateTime))
        .toList();
  }

  Future<List<AccountShare>> accountShares(
      {String? accountId, String? projectId}) async {
    final r = await _db.execute(
      Sql.named('''
        SELECT a.id::text, a.name, u.id::text, u.email, u.name, u.picture_url,
               s.role::text, s.created_at
        FROM account_shares s JOIN users u ON u.id = s.user_id
        JOIN accounts a ON a.id = s.account_id
        WHERE (@a::uuid IS NULL OR s.account_id = @a::uuid)
          AND (@p::uuid IS NULL OR a.project_id = @p::uuid)
        ORDER BY a.name, s.created_at
      '''),
      parameters: {'a': accountId, 'p': projectId},
    );
    return r
        .map((x) => AccountShare(
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

  /// Adds or raises a project membership (never lowers or touches owner).
  Future<void> grantProject(String projectId, String userId, Role role,
      {String? addedBy}) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO project_members (project_id, user_id, role, added_by)
        VALUES (@p::uuid, @u::uuid, @r::text::member_role, @by::uuid)
        ON CONFLICT (project_id, user_id) DO UPDATE
          SET role = GREATEST(project_members.role, EXCLUDED.role)
      '''),
      parameters: {'p': projectId, 'u': userId, 'r': role.name, 'by': addedBy},
    );
  }

  Future<void> grantAccount(String accountId, String userId, Role role,
      {String? addedBy}) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO account_shares (account_id, user_id, role, added_by)
        VALUES (@a::uuid, @u::uuid, @r::text::member_role, @by::uuid)
        ON CONFLICT (account_id, user_id) DO UPDATE
          SET role = GREATEST(account_shares.role, EXCLUDED.role)
      '''),
      parameters: {'a': accountId, 'u': userId, 'r': role.name, 'by': addedBy},
    );
  }

  /// Sets a non-owner member's role. Returns false if not a (non-owner) member.
  Future<bool> setProjectRole(
      String projectId, String userId, Role role) async {
    final r = await _db.execute(
      Sql.named('''
        UPDATE project_members SET role = @r::text::member_role
        WHERE project_id = @p::uuid AND user_id = @u::uuid AND role <> 'owner'
        RETURNING 1
      '''),
      parameters: {'p': projectId, 'u': userId, 'r': role.name},
    );
    return r.isNotEmpty;
  }

  Future<bool> removeProjectMember(String projectId, String userId) async {
    final r = await _db.execute(
      Sql.named('''
        DELETE FROM project_members
        WHERE project_id = @p::uuid AND user_id = @u::uuid AND role <> 'owner'
        RETURNING 1
      '''),
      parameters: {'p': projectId, 'u': userId},
    );
    return r.isNotEmpty;
  }

  Future<bool> setAccountRole(
      String accountId, String userId, Role role) async {
    final r = await _db.execute(
      Sql.named('''
        UPDATE account_shares SET role = @r::text::member_role
        WHERE account_id = @a::uuid AND user_id = @u::uuid RETURNING 1
      '''),
      parameters: {'a': accountId, 'u': userId, 'r': role.name},
    );
    return r.isNotEmpty;
  }

  Future<bool> removeAccountShare(String accountId, String userId) async {
    final r = await _db.execute(
      Sql.named('DELETE FROM account_shares '
          'WHERE account_id = @a::uuid AND user_id = @u::uuid RETURNING 1'),
      parameters: {'a': accountId, 'u': userId},
    );
    return r.isNotEmpty;
  }

  /// Hands ownership to an existing member; the old owner becomes editor.
  Future<void> transferOwnership(
      TxSession tx, String projectId, String fromUser, String toUser) async {
    await tx.execute(
      Sql.named("UPDATE project_members SET role = 'editor' "
          'WHERE project_id = @p::uuid AND user_id = @f::uuid'),
      parameters: {'p': projectId, 'f': fromUser},
    );
    await tx.execute(
      Sql.named("UPDATE project_members SET role = 'owner' "
          'WHERE project_id = @p::uuid AND user_id = @t::uuid'),
      parameters: {'p': projectId, 't': toUser},
    );
    await tx.execute(
      Sql.named('UPDATE projects SET owner_id = @t::uuid WHERE id = @p::uuid'),
      parameters: {'p': projectId, 't': toUser},
    );
  }
}
