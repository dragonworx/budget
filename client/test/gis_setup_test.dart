import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Google Identity Services setup that only exists as JS/config.
void main() {
  final html = File('web/index.html').readAsStringSync();

  test('popup mode: credential callback, FedCM for button and prompt', () {
    final popup = RegExp(r"\{client_id:clientId,callback:[^}]*\}[^}]*\}")
        .firstMatch(html)
        ?.group(0);
    expect(popup, isNotNull);
    expect(popup, contains("ux_mode:'popup'"));
    expect(popup, contains('use_fedcm_for_button:true'));
    expect(popup, contains('use_fedcm_for_prompt:true'));
  });

  test('redirect mode posts to the exact registered login_uri', () {
    expect(
      html,
      contains(
        "ux_mode:'redirect',login_uri:location.origin+'/api/auth/google/redirect'}",
      ),
    );
  });

  test('web container keeps the popup opener (COOP allow-popups)', () {
    final caddy = File('../deploy/Caddyfile').readAsStringSync();
    expect(
      caddy,
      contains('Cross-Origin-Opener-Policy same-origin-allow-popups'),
    );
    expect(caddy, isNot(contains('Cross-Origin-Opener-Policy same-origin\n')));
  });
}
