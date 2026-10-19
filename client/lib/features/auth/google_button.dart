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
  });

  final String clientId;
  final ValueChanged<String> onCredential;
  final double width;

  @override
  Widget build(BuildContext context) =>
      impl.buildGoogleButton(clientId, onCredential, width);
}

void disableGoogleAutoSelect() => impl.disableAutoSelect();
