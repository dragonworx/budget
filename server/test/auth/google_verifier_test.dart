import 'package:budget_server/auth/google_verifier.dart';
import 'package:budget_server/auth/jwks_cache.dart';
import 'package:test/test.dart';

import 'test_keys.dart';

void main() {
  const clientId = 'test-client.apps.googleusercontent.com';
  final k1 = TestKey('k1');
  final k2 = TestKey('k2');
  final other = TestKey('k1'); // same kid, different key (forgery)
  var now = DateTime.utc(2026, 10, 19, 2);
  var served = [k1];

  late JwksCache cache;
  late GoogleIdTokenVerifier v;
  setUp(() {
    now = DateTime.utc(2026, 10, 19, 2);
    served = [k1];
    cache = JwksCache(() async => (jwksJson(served), const Duration(hours: 1)),
        clock: () => now);
    v = GoogleIdTokenVerifier(
        clientId: clientId, jwks: cache, clock: () => now);
  });

  Matcher rejects(String reason) => throwsA(
      isA<TokenInvalid>().having((e) => e.reason, 'reason', contains(reason)));

  test('accepts a valid token and lowercases email', () async {
    final id = await v.verify(
        k1.sign(goodClaims(clientId, now, email: 'Person@Example.com')));
    expect(id.email, 'person@example.com');
    expect(id.sub, 'sub-Person@Example.com');
    expect(id.name, 'Test Person');
  });

  test('accepts the bare issuer form', () async {
    final c = goodClaims(clientId, now)..['iss'] = 'accounts.google.com';
    expect((await v.verify(k1.sign(c))).email, 'person@example.com');
  });

  test('rejects wrong audience, issuer, expiry, unverified email', () async {
    expect(v.verify(k1.sign(goodClaims('other', now))), rejects('audience'));
    expect(v.verify(k1.sign(goodClaims(clientId, now)..['iss'] = 'evil.com')),
        rejects('issuer'));
    final expired = goodClaims(clientId, now)
      ..['exp'] =
          now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
              1000;
    expect(v.verify(k1.sign(expired)), rejects('expired'));
    expect(
        v.verify(
            k1.sign(goodClaims(clientId, now)..['email_verified'] = false)),
        rejects('verified'));
    final future = goodClaims(clientId, now)
      ..['iat'] =
          now.add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000;
    expect(v.verify(k1.sign(future)), rejects('future'));
  });

  test('allows 60s clock skew on exp', () async {
    final c = goodClaims(clientId, now)
      ..['exp'] =
          now.subtract(const Duration(seconds: 30)).millisecondsSinceEpoch ~/
              1000;
    expect((await v.verify(k1.sign(c))).email, isNotEmpty);
  });

  test('rejects forged signature, tampered payload, alg none, malformed',
      () async {
    expect(
        v.verify(other.sign(goodClaims(clientId, now))), rejects('signature'));
    final t = k1.sign(goodClaims(clientId, now)).split('.');
    final t2 =
        k1.sign(goodClaims(clientId, now, email: 'admin@x.com')).split('.');
    expect(v.verify('${t[0]}.${t2[1]}.${t[2]}'), rejects('signature'));
    expect(
        v.verify(k1.sign(goodClaims(clientId, now),
            header: {'alg': 'none', 'kid': 'k1'})),
        rejects('alg'));
    expect(v.verify('abc'), rejects('malformed'));
    expect(v.verify('a.b.c'), rejects('malformed'));
  });

  test('unknown kid refetches JWKS (key rotation)', () async {
    await v.verify(k1.sign(goodClaims(clientId, now)));
    expect(cache.fetchCount, 1);
    served = [k1, k2];
    now = now.add(const Duration(minutes: 1));
    expect(
        (await v.verify(k2.sign(goodClaims(clientId, now)))).email, isNotEmpty);
    expect(cache.fetchCount, 2);
    // A bogus kid does not hammer Google: rate-limited refetch.
    expect(v.verify(TestKey('zz').sign(goodClaims(clientId, now))),
        rejects('kid'));
    await Future<void>.delayed(Duration.zero);
    expect(cache.fetchCount, 2);
  });

  test('cache honours max-age', () async {
    await v.verify(k1.sign(goodClaims(clientId, now)));
    await v.verify(k1.sign(goodClaims(clientId, now)));
    expect(cache.fetchCount, 1);
    now = now.add(const Duration(hours: 2));
    await v.verify(k1.sign(goodClaims(clientId, now)));
    expect(cache.fetchCount, 2);
  });

  test('empty client id is refused', () async {
    final v2 =
        GoogleIdTokenVerifier(clientId: '', jwks: cache, clock: () => now);
    expect(
        v2.verify(k1.sign(goodClaims('', now))), rejects('GOOGLE_CLIENT_ID'));
  });
}
