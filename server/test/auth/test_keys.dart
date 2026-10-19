import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:budget_server/auth/jwks_cache.dart';
import 'package:pointycastle/export.dart';

/// Locally generated RSA key pair + JWT signer for verifier tests.
class TestKey {
  TestKey(this.kid) {
    final rnd = FortunaRandom()
      ..seed(KeyParameter(Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(256)))));
    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rnd));
    final pair = gen.generateKeyPair();
    publicKey = pair.publicKey;
    privateKey = pair.privateKey;
  }

  final String kid;
  late final RSAPublicKey publicKey;
  late final RSAPrivateKey privateKey;

  Map<String, String> get jwk => {
        'kty': 'RSA',
        'alg': 'RS256',
        'use': 'sig',
        'kid': kid,
        'n': b64uEncodeInt(publicKey.modulus!),
        'e': b64uEncodeInt(publicKey.exponent!),
      };

  String sign(Map<String, Object?> claims, {Map<String, Object?>? header}) {
    String enc(Object o) =>
        base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    final h = enc(header ?? {'alg': 'RS256', 'kid': kid, 'typ': 'JWT'});
    final p = enc(claims);
    final signer = Signer('SHA-256/RSA')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    final sig =
        signer.generateSignature(Uint8List.fromList(ascii.encode('$h.$p')))
            as RSASignature;
    return '$h.$p.${base64Url.encode(sig.bytes).replaceAll('=', '')}';
  }
}

String jwksJson(List<TestKey> keys) =>
    jsonEncode({'keys': keys.map((k) => k.jwk).toList()});

Map<String, Object?> goodClaims(String clientId, DateTime now,
        {String email = 'person@example.com'}) =>
    {
      'iss': 'https://accounts.google.com',
      'aud': clientId,
      'sub': 'sub-$email',
      'email': email,
      'email_verified': true,
      'name': 'Test Person',
      'picture': 'https://example.com/p.png',
      'iat': now.millisecondsSinceEpoch ~/ 1000,
      'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    };
