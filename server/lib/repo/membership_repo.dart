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

class StreamShare extends Member {
  StreamShare(this.streamId, this.streamName, String userId, String email,
      String? name, String? pictureUrl, Role role, DateTime createdAt)
      : super(userId, email, name, pictureUrl, role, createdAt);
  final String streamId;
  final String streamName;

  @override
  Map<String, Object?> toJson() =>
      {'streamId': streamId, 'streamName': streamName, ...super.toJson()};
}

/// Stream owners and shares.
class MembershipRepo {
  MembershipRepo(this._db);
  final Session _db;

  /// The stream's owner, as a member row with role owner.
  Future<Member?> streamOwner(String streamId) async {
    final r = await _db.execute(
      Sql.named('''
        SELECT u.id::text, u.email, u.name, u.picture_url, u.created_at
        FROM streams a JOIN users u ON u.id = a.owner_id
        WHERE a.id = @a::uuid
      '''),
      parameters: {'a': streamId},
    );
    if (r.isEmpty) return null;
    final x = r.first;
    return Member(x[0] as String, x[1] as String, x[2] as String?,
        x[3] as String?, Role.owner, x[4] as DateTime? ?? DateTime.now());
  }

  Future<List<StreamShare>> streamShares({required String streamId}) async {
    final r = await _db.execute(
      Sql.named('''
        SELECT a.id::text, a.name, u.id::text, u.email, u.name, u.picture_url,
               s.role::text, s.created_at
        FROM stream_shares s JOIN users u ON u.id = s.user_id
        JOIN streams a ON a.id = s.stream_id
        WHERE s.stream_id = @a::uuid
        ORDER BY s.created_at
      '''),
      parameters: {'a': streamId},
    );
    return r
        .map((x) => StreamShare(
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

  Future<void> grantStream(String streamId, String userId, Role role,
      {String? addedBy}) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO stream_shares (stream_id, user_id, role, added_by)
        VALUES (@a::uuid, @u::uuid, @r::text::member_role, @by::uuid)
        ON CONFLICT (stream_id, user_id) DO UPDATE
          SET role = GREATEST(stream_shares.role, EXCLUDED.role)
      '''),
      parameters: {'a': streamId, 'u': userId, 'r': role.name, 'by': addedBy},
    );
  }

  Future<bool> setStreamRole(String streamId, String userId, Role role) async {
    final r = await _db.execute(
      Sql.named('''
        UPDATE stream_shares SET role = @r::text::member_role
        WHERE stream_id = @a::uuid AND user_id = @u::uuid RETURNING 1
      '''),
      parameters: {'a': streamId, 'u': userId, 'r': role.name},
    );
    return r.isNotEmpty;
  }

  Future<bool> removeStreamShare(String streamId, String userId) async {
    final r = await _db.execute(
      Sql.named('DELETE FROM stream_shares '
          'WHERE stream_id = @a::uuid AND user_id = @u::uuid RETURNING 1'),
      parameters: {'a': streamId, 'u': userId},
    );
    return r.isNotEmpty;
  }
}
