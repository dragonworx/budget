import 'package:flutter/widgets.dart';

import 'google_button_stub.dart'
    if (dart.library.js_interop) 'google_button_web.dart'
    as impl;

/// "Sign in with Google" button (Google Identity Services). Calls
/// [onCredential] with the ID token. Renders nothing off the web.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.clientId,
    required this.onCredential,
    this.width = 280,
    this.uxMode = 'auto',
  });

  final String clientId;

  /// `popup`, `redirect` or `auto`; see [effectiveGoogleUxMode].
  final String uxMode;
  final ValueChanged<String> onCredential;
  final double width;

  @override
  Widget build(BuildContext context) =>
      impl.buildGoogleButton(clientId, onCredential, width, uxMode);
}

void disableGoogleAutoSelect() => impl.disableAutoSelect();

/// Whether this page runs as a home-screen app or inside another app's
/// browser (Gmail, Messenger, WhatsApp, Instagram...), where a sign-in
/// popup can't report back and is left on a blank page.
bool googlePopupUnreliable() => impl.popupUnreliable();

/// Whether the page is inside another app's embedded browser, which Google
/// may refuse to sign in from at all.
bool inAppBrowser() => impl.inAppBrowser();

/// `auto` becomes `redirect` where popups are unreliable, else `popup`.
String effectiveGoogleUxMode(String mode, {required bool popupUnreliable}) =>
    switch (mode) {
      'popup' || 'redirect' => mode,
      _ => popupUnreliable ? 'redirect' : 'popup',
    };
