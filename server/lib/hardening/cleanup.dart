import 'dart:async';

import 'package:postgres/postgres.dart';

import '../auth/session_store.dart';
import 'logging.dart';

/// Periodically deletes expired sessions and stale invites. Uses a
/// event-scoped advisory lock so only one replica runs it per tick.
class CleanupJob {
  CleanupJob(this._db, this._sessions, this._log,
      {this.interval = const Duration(hours: 1),
      this.inviteKeep = const Duration(days: 30)});

  final SessionExecutor _db;
  final SessionStore _sessions;
  final Log _log;
  final Duration interval;

  /// Expired/revoked invites are kept this long after expiry for the audit
  /// trail, then deleted. Accepted invites are kept.
  final Duration inviteKeep;
  Timer? _timer;

  static const _lockKey = 0x6275646765; // 'budge'

  void start({Duration firstRunAfter = const Duration(seconds: 30)}) {
    _timer = Timer(firstRunAfter, () {
      unawaited(runOnce());
      _timer = Timer.periodic(interval, (_) => unawaited(runOnce()));
    });
  }

  /// Returns (sessions, invites) deleted, or null if another replica holds
  /// the lock.
  Future<(int, int)?> runOnce() async {
    try {
      return await _db.runTx((tx) async {
        final got = await tx.execute(
            Sql.named('SELECT pg_try_advisory_xact_lock(@k)'),
            parameters: {'k': _lockKey});
        if (got.first[0] != true) return null;
        final sessions =
            await SessionStore(tx, secret: 'unused').purgeExpired();
        final invites = await tx.execute(
          Sql.named('''
            DELETE FROM invites WHERE accepted_at IS NULL AND (
              expires_at < now() - make_interval(secs => @keep)
              OR revoked_at < now() - make_interval(secs => @keep))
            RETURNING 1
          '''),
          parameters: {'keep': inviteKeep.inSeconds.toDouble()},
        );
        _sessions.clearCache();
        if (sessions > 0 || invites.isNotEmpty) {
          _log.info(
              'cleanup', {'sessions': sessions, 'invites': invites.length});
        }
        return (sessions, invites.length);
      });
    } catch (e) {
      _log.error('cleanup failed', {'error': e.toString()});
      return null;
    }
  }

  void stop() => _timer?.cancel();
}
