import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';

import '../repo/user_repo.dart';

class SessionInfo {
  SessionInfo(this.user, this.isDev);
  final User user;
  final bool isDev;
}

/// Opaque random session tokens; only HMAC(SESSION_SECRET, token) is stored.
/// Sliding expiry: extended (at most once per [touchEvery]) on use.
class SessionStore {
  SessionStore(this._db,
      {required String secret,
      this.ttl = const Duration(days: 30),
      this.touchEvery = const Duration(hours: 1)})
      : _hmac = Hmac(sha256, utf8.encode(secret));

  final Session _db;
  final Hmac _hmac;
  final Duration ttl;
  final Duration touchEvery;
  static final _rng = Random.secure();

  Uint8List hash(String token) =>
      Uint8List.fromList(_hmac.convert(utf8.encode(token)).bytes);

  Future<String> create(String userId,
      {String? userAgent, String? ip, bool isDev = false}) async {
    final token = base64Url
        .encode(List<int>.generate(32, (_) => _rng.nextInt(256)))
        .replaceAll('=', '');
    await _db.execute(
      Sql.named('''
        INSERT INTO sessions (id_hash, user_id, expires_at, user_agent, ip, is_dev)
        VALUES (@h, @u, now() + make_interval(secs => @ttl), @ua, @ip, @dev)
      '''),
      parameters: {
        'h': TypedValue(Type.byteArray, hash(token)),
        'u': userId,
        'ttl': ttl.inSeconds.toDouble(),
        'ua': userAgent,
        'ip': ip,
        'dev': isDev,
      },
    );
    return token;
  }

  Future<SessionInfo?> lookup(String token) async {
    if (token.isEmpty || token.length > 200) return null;
    final h = hash(token);
    final rows = await _db.execute(
      Sql.named('''
        SELECT $userCols, s.is_dev, s.last_seen_at < now() - make_interval(secs => @touch)
        FROM sessions s JOIN users u ON u.id = s.user_id
        WHERE s.id_hash = @h AND s.expires_at > now() AND NOT u.disabled
      '''),
      parameters: {
        'h': TypedValue(Type.byteArray, h),
        'touch': touchEvery.inSeconds.toDouble(),
      },
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    if (r[8] == true) {
      await _db.execute(
        Sql.named('''
          UPDATE sessions SET last_seen_at = now(),
            expires_at = now() + make_interval(secs => @ttl)
          WHERE id_hash = @h
        '''),
        parameters: {
          'h': TypedValue(Type.byteArray, h),
          'ttl': ttl.inSeconds.toDouble()
        },
      );
    }
    return SessionInfo(userFromRow(r), r[7] as bool);
  }

  Future<void> delete(String token) => _db.execute(
        Sql.named('DELETE FROM sessions WHERE id_hash = @h'),
        parameters: {'h': TypedValue(Type.byteArray, hash(token))},
      );

  Future<void> deleteAllForUser(String userId) => _db.execute(
        Sql.named('DELETE FROM sessions WHERE user_id = @u'),
        parameters: {'u': userId},
      );

  Future<void> purgeExpired() =>
      _db.execute('DELETE FROM sessions WHERE expires_at < now()');
}
