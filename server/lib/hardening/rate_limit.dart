import 'package:shelf/shelf.dart';

import '../api/json_helpers.dart';
import '../auth/middleware.dart';
import 'client_ip.dart';

/// Token bucket per key: [perMinute] requests/minute with an equal burst.
/// In-memory per replica (limits are per replica; Caddy spreads load).
class RateLimiter {
  RateLimiter(this.perMinute, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final int perMinute;
  final DateTime Function() _clock;
  final _buckets = <String, (double, DateTime)>{};

  /// Returns null when allowed, else the seconds to wait.
  int? take(String key) {
    if (perMinute <= 0) return null;
    final now = _clock();
    final (tokens, at) = _buckets[key] ?? (perMinute.toDouble(), now);
    final refill = now.difference(at).inMicroseconds / 60e6 * perMinute;
    var t = (tokens + refill).clamp(0, perMinute.toDouble()).toDouble();
    if (t < 1) {
      _buckets[key] = (t, now);
      return ((1 - t) * 60 / perMinute).ceil().clamp(1, 60);
    }
    _buckets[key] = (t - 1, now);
    if (_buckets.length > 50000) _prune(now);
    return null;
  }

  void _prune(DateTime now) => _buckets
      .removeWhere((_, v) => now.difference(v.$2) > const Duration(minutes: 2));
}

/// `/api/auth/*` limited per client IP; every other `/api` request per
/// session token (or per IP when anonymous). 429 + Retry-After when over.
Middleware rateLimitMiddleware(
    {required RateLimiter auth, required RateLimiter general}) {
  return (inner) => (request) async {
        final path = request.url.path;
        if (!path.startsWith('api')) return inner(request);
        final ip = clientIpOf(request);
        int? wait;
        if (path.startsWith('api/auth/')) {
          wait = auth.take('ip:$ip');
        } else {
          final token = sessionTokenFrom(request);
          wait = general.take(token != null && token.isNotEmpty
              ? 'session:${token.hashCode}:${token.length}'
              : 'ip:$ip');
        }
        if (wait != null) {
          return jsonError(429, 'too many requests',
                  details: {'retryAfter': wait})
              .change(headers: {'retry-after': '$wait'});
        }
        return inner(request);
      };
}
