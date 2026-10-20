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

/// Account owners and shares.
class MembershipRepo {
  MembershipRepo(this._db);
  final Session _db;

  /// The account's owner, as a member row with role owner.
  Future<Member?> accountOwner(String accountId) async {
    final r = await _db.execute(
      Sql.named('''
        SELECT u.id::text, u.email, u.name, u.picture_url, u.created_at
        FROM accounts a JOIN users u ON u.id = a.owner_id
        WHERE a.id = @a::uuid
      '''),
      parameters: {'a': accountId},
    );
    if (r.isEmpty) return null;
    final x = r.first;
    return Member(x[0] as String, x[1] as String, x[2] as String?,
        x[3] as String?, Role.owner, x[4] as DateTime? ?? DateTime.now());
  }

  Future<List<AccountShare>> accountShares({required String accountId}) async {
    final r = await _db.execute(
      Sql.named('''
        SELECT a.id::text, a.name, u.id::text, u.email, u.name, u.picture_url,
               s.role::text, s.created_at
        FROM account_shares s JOIN users u ON u.id = s.user_id
        JOIN accounts a ON a.id = s.account_id
        WHERE s.account_id = @a::uuid
        ORDER BY s.created_at
      '''),
      parameters: {'a': accountId},
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
}
