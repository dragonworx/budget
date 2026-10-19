import 'package:budget_server/auth/allowlist.dart';
import 'package:budget_server/config.dart';
import 'package:test/test.dart';

void main() {
  Config c(Map<String, String> e) => Config.fromEnvironment(e);
  const secret = '0123456789abcdef0123456789abcdef0123';

  test('defaults: admin musicartscience, dev bypass off, invites bypass on',
      () {
    final x = c({});
    expect(x.adminEmails, ['musicartscience@gmail.com']);
    expect(x.devBypass, isFalse);
    expect(x.invitesBypassAllowlist, isTrue);
    expect(x.isProduction, isFalse);
    x.validate();
  });

  test('dev bypass can never run in production', () {
    final x = c({
      'APP_ENV': 'production',
      'AUTH_DEV_BYPASS': 'true',
      'SESSION_SECRET': secret,
      'GOOGLE_CLIENT_ID': 'id',
      'PUBLIC_ORIGIN': 'https://b.example.com',
    });
    expect(x.validate, throwsStateError);
  });

  test('production requires secret, client id and https origin', () {
    final ok = {
      'APP_ENV': 'production',
      'SESSION_SECRET': secret,
      'GOOGLE_CLIENT_ID': 'id',
      'PUBLIC_ORIGIN': 'https://b.example.com',
    };
    c(ok).validate();
    expect(c({...ok, 'SESSION_SECRET': ''}).validate, throwsStateError);
    expect(c({...ok, 'GOOGLE_CLIENT_ID': ''}).validate, throwsStateError);
    expect(c({...ok, 'PUBLIC_ORIGIN': 'http://b.example.com'}).validate,
        throwsStateError);
    expect(c(ok).allowedOrigins, {'https://b.example.com'});
    expect(c(ok).secureCookies, isTrue);
  });

  test('lists are parsed and lowercased', () {
    final x = c({
      'ADMIN_EMAILS': 'A@x.com, b@y.com',
      'AUTH_ALLOWLIST': '@Family.org,friend@z.com',
      'PUBLIC_ORIGIN': 'https://dev.ngrok.app/',
    });
    expect(x.adminEmails, ['a@x.com', 'b@y.com']);
    expect(x.primaryAdminEmail, 'a@x.com');
    expect(x.publicOrigin, 'https://dev.ngrok.app');
    expect(x.allowedOrigins, contains('http://localhost:8000'));
  });

  test('allowlist patterns: exact and @domain', () {
    final p = ['friend@z.com', '@family.org'];
    expect(matchesPattern('Friend@Z.com', p), isTrue);
    expect(matchesPattern('mum@family.org', p), isTrue);
    expect(matchesPattern('mum@notfamily.org', p), isFalse);
    expect(matchesPattern('x@z.com', p), isFalse);
  });
}
