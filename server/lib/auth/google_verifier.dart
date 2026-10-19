import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'jwks_cache.dart';

class GoogleIdentity {
  GoogleIdentity(
      {required this.sub, required this.email, this.name, this.picture});
  final String sub;
  final String email;
  final String? name;
  final String? picture;
}

class TokenInvalid implements Exception {
  TokenInvalid(this.reason);
  final String reason;
  @override
  String toString() => 'invalid Google ID token: $reason';
}

/// Verifies a Google Identity Services ID token (RS256 JWT) against Google's
/// JWKS: signature, `aud`, `iss`, `exp`/`iat` (60 s skew) and `email_verified`.
class GoogleIdTokenVerifier {
  GoogleIdTokenVerifier(
      {required this.clientId, required this.jwks, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final String clientId;
  final JwksCache jwks;
  final DateTime Function() _clock;
  static const skew = Duration(seconds: 60);
  static const issuers = {'accounts.google.com', 'https://accounts.google.com'};

  Future<GoogleIdentity> verify(String token) async {
    if (clientId.isEmpty) throw TokenInvalid('GOOGLE_CLIENT_ID not configured');
    final parts = token.split('.');
    if (parts.length != 3) throw TokenInvalid('malformed');
    final Map<String, dynamic> header, claims;
    try {
      header = jsonDecode(utf8.decode(b64uDecode(parts[0])));
      claims = jsonDecode(utf8.decode(b64uDecode(parts[1])));
    } catch (_) {
      throw TokenInvalid('malformed');
    }
    if (header['alg'] != 'RS256') throw TokenInvalid('unsupported alg');
    final kid = header['kid'];
    if (kid is! String) throw TokenInvalid('missing kid');
    final key = await jwks.key(kid);
    if (key == null) throw TokenInvalid('unknown kid');

    final signer = Signer('SHA-256/RSA')
      ..init(false, PublicKeyParameter<RSAPublicKey>(key));
    final ok = () {
      try {
        return signer.verifySignature(
            Uint8List.fromList(ascii.encode('${parts[0]}.${parts[1]}')),
            RSASignature(Uint8List.fromList(b64uDecode(parts[2]))));
      } catch (_) {
        return false;
      }
    }();
    if (!ok) throw TokenInvalid('bad signature');

    final aud = claims['aud'];
    final audOk = aud == clientId || (aud is List && aud.contains(clientId));
    if (!audOk) throw TokenInvalid('wrong audience');
    if (!issuers.contains(claims['iss'])) throw TokenInvalid('wrong issuer');
    final now = _clock();
    final exp = claims['exp'];
    if (exp is! num) throw TokenInvalid('missing exp');
    if (now.isAfter(_epoch(exp).add(skew))) throw TokenInvalid('expired');
    final iat = claims['iat'];
    if (iat is num && _epoch(iat).isAfter(now.add(skew))) {
      throw TokenInvalid('issued in the future');
    }
    final email = claims['email'];
    if (email is! String || email.isEmpty) throw TokenInvalid('no email');
    final verified = claims['email_verified'];
    if (!(verified == true || verified == 'true')) {
      throw TokenInvalid('email not verified');
    }
    final sub = claims['sub'];
    if (sub is! String || sub.isEmpty) throw TokenInvalid('no sub');
    return GoogleIdentity(
        sub: sub,
        email: email.toLowerCase(),
        name: claims['name'] as String?,
        picture: claims['picture'] as String?);
  }

  static DateTime _epoch(num s) =>
      DateTime.fromMillisecondsSinceEpoch((s * 1000).toInt(), isUtc: true);
}
