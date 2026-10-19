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
      this.touchEvery = const Duration(hours: 1),
      this.cacheTtl = Duration.zero,
      DateTime Function()? clock})
      : _hmac = Hmac(sha256, utf8.encode(secret)),
        _clock = clock ?? DateTime.now;

  /// NOTIFY channel carrying `{"hash": hex}` or `{"userId": id}` so every
  /// replica drops cached sessions on logout / disable.
  static const invalidationChannel = 'budget_sessions';

  /// In-memory lookup cache TTL (0 = off). Entries are dropped on logout,
  /// logout-all and user disable, locally and on other replicas via NOTIFY.
  final Duration cacheTtl;
  final DateTime Function() _clock;
  final _cache = <String, (SessionInfo, DateTime)>{};
  int cacheHits = 0;

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
    final key = _hex(h);
    if (cacheTtl > Duration.zero) {
      final hit = _cache[key];
      if (hit != null && _clock().isBefore(hit.$2)) {
        cacheHits++;
        return hit.$1;
      }
      _cache.remove(key);
    }
    final info = await _lookupDb(h);
    if (info != null && cacheTtl > Duration.zero) {
      if (_cache.length > 10000) _cache.clear();
      _cache[key] = (info, _clock().add(cacheTtl));
    }
    return info;
  }

  Future<SessionInfo?> _lookupDb(Uint8List h) async {
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

  Future<void> delete(String token) async {
    final h = hash(token);
    await _db.execute(
      Sql.named('DELETE FROM sessions WHERE id_hash = @h'),
      parameters: {'h': TypedValue(Type.byteArray, h)},
    );
    await _invalidate({'hash': _hex(h)});
  }

  Future<void> deleteAllForUser(String userId) async {
    await _db.execute(
      Sql.named('DELETE FROM sessions WHERE user_id = @u'),
      parameters: {'u': userId},
    );
    await _invalidate({'userId': userId});
  }

  Future<void> _invalidate(Map<String, String> what) async {
    handleInvalidation(jsonEncode(what));
    // Delivered to other replicas on commit.
    await _db.execute(Sql.named('SELECT pg_notify(@c, @p)'),
        parameters: {'c': invalidationChannel, 'p': jsonEncode(what)});
  }

  /// Applies an invalidation payload (local or from NOTIFY).
  void handleInvalidation(String payload) {
    if (_cache.isEmpty) return;
    try {
      final m = jsonDecode(payload) as Map<String, dynamic>;
      if (m['hash'] != null) _cache.remove(m['hash']);
      if (m['userId'] != null) {
        _cache.removeWhere((_, v) => v.$1.user.id == m['userId']);
      }
    } catch (_) {
      _cache.clear();
    }
  }

  /// Drops every cached entry (e.g. after the listener reconnects).
  void clearCache() => _cache.clear();

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// Deletes expired sessions; returns how many.
  Future<int> purgeExpired() async {
    final r = await _db
        .execute('DELETE FROM sessions WHERE expires_at < now() RETURNING 1');
    return r.length;
  }
}
