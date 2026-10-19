import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

/// Fetches JWKS JSON; injectable for tests. Returns (body, maxAge).
typedef JwksFetcher = Future<(String body, Duration maxAge)> Function();

const googleJwksUrl = 'https://www.googleapis.com/oauth2/v3/certs';

JwksFetcher httpJwksFetcher([String url = googleJwksUrl, http.Client? client]) {
  return () async {
    final c = client ?? http.Client();
    final res = await c.get(Uri.parse(url));
    if (res.statusCode != 200) {
      throw StateError('JWKS fetch failed: HTTP ${res.statusCode}');
    }
    final m =
        RegExp(r'max-age=(\d+)').firstMatch(res.headers['cache-control'] ?? '');
    final maxAge = Duration(seconds: m == null ? 3600 : int.parse(m[1]!));
    return (res.body, maxAge);
  };
}

/// Caches RSA signing keys by `kid`, honouring the response max-age. An
/// unknown kid triggers a refetch, rate-limited to one per [minRefetch].
class JwksCache {
  JwksCache(this._fetch,
      {DateTime Function()? clock,
      this.minRefetch = const Duration(seconds: 30)})
      : _clock = clock ?? DateTime.now;

  final JwksFetcher _fetch;
  final DateTime Function() _clock;
  final Duration minRefetch;

  Map<String, RSAPublicKey> _keys = {};
  DateTime? _expiresAt;
  DateTime? _lastFetch;
  Future<void>? _inflight;
  int fetchCount = 0;

  Future<RSAPublicKey?> key(String kid) async {
    final now = _clock();
    final stale = _expiresAt == null || now.isAfter(_expiresAt!);
    final unknown = !_keys.containsKey(kid);
    final mayRefetch =
        _lastFetch == null || now.difference(_lastFetch!) >= minRefetch;
    if (stale || (unknown && mayRefetch)) await _refresh();
    return _keys[kid];
  }

  Future<void> _refresh() => _inflight ??= () async {
        try {
          final (body, maxAge) = await _fetch();
          fetchCount++;
          _keys = parseJwks(body);
          _lastFetch = _clock();
          _expiresAt = _lastFetch!.add(maxAge);
        } finally {
          _inflight = null;
        }
      }();
}

Map<String, RSAPublicKey> parseJwks(String body) {
  final json = jsonDecode(body) as Map<String, dynamic>;
  final out = <String, RSAPublicKey>{};
  for (final k in (json['keys'] as List).cast<Map<String, dynamic>>()) {
    if (k['kty'] != 'RSA' || k['kid'] == null) continue;
    out[k['kid'] as String] =
        RSAPublicKey(b64uInt(k['n'] as String), b64uInt(k['e'] as String));
  }
  return out;
}

List<int> b64uDecode(String s) => base64Url.decode(base64Url.normalize(s));

BigInt b64uInt(String s) {
  var r = BigInt.zero;
  for (final b in b64uDecode(s)) {
    r = (r << 8) | BigInt.from(b);
  }
  return r;
}

String b64uEncodeInt(BigInt v) {
  final bytes = <int>[];
  var x = v;
  while (x > BigInt.zero) {
    bytes.insert(0, (x & BigInt.from(0xff)).toInt());
    x = x >> 8;
  }
  return base64Url.encode(bytes).replaceAll('=', '');
}
