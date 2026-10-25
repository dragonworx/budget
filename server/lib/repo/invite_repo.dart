import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../auth/authz.dart';
import 'membership_repo.dart';

class Invite {
  Invite({
    required this.id,
    required this.email,
    required this.role,
    required this.streamId,
    this.streamName,
    required this.invitedBy,
    required this.invitedByEmail,
    this.invitedByName,
    required this.createdAt,
    required this.expiresAt,
    this.acceptedAt,
    this.revokedAt,
  });

  final String id;
  final String email;
  final Role role;
  final String streamId;
  final String? streamName;
  final String invitedBy;
  final String invitedByEmail;
  final String? invitedByName;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? acceptedAt;
  final DateTime? revokedAt;

  String get status => acceptedAt != null
      ? 'accepted'
      : revokedAt != null
          ? 'revoked'
          : expiresAt.isBefore(DateTime.now())
              ? 'expired'
              : 'pending';

  Map<String, Object?> toJson() => {
        'id': id,
        'email': email,
        'role': role.name,
        'streamId': streamId,
        'streamName': streamName,
        'invitedBy': {
          'id': invitedBy,
          'email': invitedByEmail,
          'name': invitedByName
        },
        'status': status,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };
}

const _cols = '''
  i.id::text, i.email, i.role::text, i.stream_id::text,
  a.name, u.id::text, u.email, u.name,
  i.created_at, i.expires_at, i.accepted_at, i.revoked_at''';
const _from = '''
  FROM invites i
  JOIN users u ON u.id = i.invited_by
  JOIN streams a ON a.id = i.stream_id''';

Invite _row(List<Object?> x) => Invite(
      id: x[0] as String,
      email: x[1] as String,
      role: Role.parse(x[2])!,
      streamId: x[3] as String,
      streamName: x[4] as String?,
      invitedBy: x[5] as String,
      invitedByEmail: x[6] as String,
      invitedByName: x[7] as String?,
      createdAt: x[8] as DateTime,
      expiresAt: x[9] as DateTime,
      acceptedAt: x[10] as DateTime?,
      revokedAt: x[11] as DateTime?,
    );

/// Invites by email to a single stream. Tokens are random;
/// only HMAC(SESSION_SECRET, token) is stored.
class InviteRepo {
  InviteRepo(this._db,
      {required String secret, this.ttl = const Duration(days: 14)})
      : _hmac = Hmac(sha256, utf8.encode('invite:$secret'));

  final Session _db;
  final Hmac _hmac;
  final Duration ttl;
  static final _rng = Random.secure();
  static const _uuid = Uuid();

  Uint8List _hash(String token) =>
      Uint8List.fromList(_hmac.convert(utf8.encode(token)).bytes);

  static String _newToken() => base64Url
      .encode(List<int>.generate(24, (_) => _rng.nextInt(256)))
      .replaceAll('=', '');

  /// Creates a pending invite (revoking earlier pending ones for the same
  /// email + target). Returns the invite and its one-time token.
  Future<(Invite, String)> create({
    required String email,
    required Role role,
    required String streamId,
    required String invitedBy,
  }) async {
    await _db.execute(
      Sql.named('''
        UPDATE invites SET revoked_at = now()
        WHERE email = @e AND accepted_at IS NULL AND revoked_at IS NULL
          AND stream_id = @a::uuid
      '''),
      parameters: {'e': email, 'a': streamId},
    );
    final id = _uuid.v4();
    final token = _newToken();
    await _db.execute(
      Sql.named('''
        INSERT INTO invites (id, token_hash, email, stream_id, role, invited_by, expires_at)
        VALUES (@id::uuid, @h, @e, @a::uuid, @r::text::member_role, @by::uuid,
                now() + make_interval(secs => @ttl))
      '''),
      parameters: {
        'id': id,
        'h': TypedValue(Type.byteArray, _hash(token)),
        'e': email,
        'a': streamId,
        'r': role.name,
        'by': invitedBy,
        'ttl': ttl.inSeconds.toDouble(),
      },
    );
    return ((await byId(id))!, token);
  }

  Future<Invite?> byId(String id) async {
    final r = await _db.execute(
        Sql.named('SELECT $_cols $_from WHERE i.id = @id::uuid'),
        parameters: {'id': id});
    return r.isEmpty ? null : _row(r.first);
  }

  Future<Invite?> byToken(String token) async {
    if (token.isEmpty || token.length > 200) return null;
    final r = await _db.execute(
        Sql.named('SELECT $_cols $_from WHERE i.token_hash = @h'),
        parameters: {'h': TypedValue(Type.byteArray, _hash(token))});
    return r.isEmpty ? null : _row(r.first);
  }

  /// New token for a pending invite (the old link stops working).
  Future<String?> rotate(String id) async {
    final token = _newToken();
    final r = await _db.execute(
      Sql.named('''
        UPDATE invites SET token_hash = @h,
          expires_at = GREATEST(expires_at, now() + make_interval(secs => @ttl))
        WHERE id = @id::uuid AND accepted_at IS NULL AND revoked_at IS NULL
        RETURNING 1
      '''),
      parameters: {
        'id': id,
        'h': TypedValue(Type.byteArray, _hash(token)),
        'ttl': ttl.inSeconds.toDouble(),
      },
    );
    return r.isEmpty ? null : token;
  }

  Future<bool> revoke(String id) async {
    final r = await _db.execute(
      Sql.named('UPDATE invites SET revoked_at = now() WHERE id = @id::uuid '
          'AND accepted_at IS NULL AND revoked_at IS NULL RETURNING 1'),
      parameters: {'id': id},
    );
    return r.isNotEmpty;
  }

  /// Pending invites, by target or by email.
  Future<List<Invite>> pending({String? streamId, String? email}) async {
    final r = await _db.execute(
      Sql.named('''
        SELECT $_cols $_from
        WHERE i.accepted_at IS NULL AND i.revoked_at IS NULL AND i.expires_at > now()
          AND (@e::text IS NULL OR i.email = @e::text)
          AND (@a::uuid IS NULL OR i.stream_id = @a::uuid)
        ORDER BY i.created_at
      '''),
      parameters: {'e': email, 'a': streamId},
    );
    return r.map(_row).toList();
  }

  /// Grants the invite to [userId] and marks it accepted.
  Future<void> accept(Invite inv, String userId) async {
    await MembershipRepo(_db)
        .grantStream(inv.streamId, userId, inv.role, addedBy: inv.invitedBy);
    await _db.execute(
      Sql.named(
          'UPDATE invites SET accepted_at = now(), accepted_by = @u::uuid '
          'WHERE id = @id::uuid'),
      parameters: {'id': inv.id, 'u': userId},
    );
  }

  /// Accepts every pending invite for [email] (on sign-in). Returns them.
  Future<List<Invite>> acceptAllFor(String email, String userId) async {
    final list = await pending(email: email.toLowerCase());
    for (final i in list) {
      await accept(i, userId);
    }
    return list;
  }
}
