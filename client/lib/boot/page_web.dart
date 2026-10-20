import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Browser hooks for the version check.
void reloadPage() => web.window.location.reload();

bool get pageVisible => web.document.visibilityState == 'visible';

void onPageVisible(void Function() f) {
  web.document.addEventListener(
    'visibilitychange',
    ((web.Event _) {
      if (pageVisible) f();
    }).toJS,
  );
}

String? sessionGet(String key) => web.window.sessionStorage.getItem(key);
void sessionSet(String key, String value) =>
    web.window.sessionStorage.setItem(key, value);

/// Survives reloads and new tabs (per browser profile).
String? localGet(String key) => web.window.localStorage.getItem(key);
void localSet(String key, String value) =>
    web.window.localStorage.setItem(key, value);

/// The OS "reduce motion" setting (prefers-reduced-motion).
bool get prefersReducedMotion =>
    web.window.matchMedia('(prefers-reduced-motion: reduce)').matches;

web.HTMLInputElement? _keyboardPrimer;

/// Touch browsers (iOS Safari especially) only raise the soft keyboard
/// for a focus() made inside the user's tap. A new transaction's Name
/// field only exists a frame later, so focus a hidden input now, inside
/// the tap; Flutter's own input then takes over the focus (the keyboard
/// stays up). The primer removes itself once focus moves on, or after 2s.
void primeSoftKeyboard() {
  if (!web.window.matchMedia('(pointer: coarse)').matches) return;
  _keyboardPrimer?.remove();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'text'
    ..tabIndex = -1
    ..setAttribute('aria-hidden', 'true')
    ..setAttribute('autocomplete', 'off');
  // 16px: no iOS zoom-on-focus; fixed and transparent: never seen.
  input.style.cssText =
      'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;'
      'font-size:16px;border:0;padding:0;margin:0;pointer-events:none;';
  web.document.body?.append(input);
  _keyboardPrimer = input;
  void drop() {
    if (identical(_keyboardPrimer, input)) _keyboardPrimer = null;
    input.remove();
  }

  input.addEventListener('blur', ((web.Event _) => drop()).toJS);
  input.focus(web.FocusOptions(preventScroll: true));
  Timer(const Duration(seconds: 2), drop);
}
