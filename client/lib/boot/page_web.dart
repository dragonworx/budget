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

/// [f] runs whenever the page is hidden or unloaded (tab switch, app
/// switch, close, navigation away). Returns a handle for [offPageHidden].
Object onPageHidden(void Function() f) {
  final vis = ((web.Event _) {
    if (!pageVisible) f();
  }).toJS;
  final hide = ((web.Event _) => f()).toJS;
  web.document.addEventListener('visibilitychange', vis);
  web.window.addEventListener('pagehide', hide);
  return (vis, hide);
}

void offPageHidden(Object handle) {
  final (vis, hide) = handle as (JSFunction, JSFunction);
  web.document.removeEventListener('visibilitychange', vis);
  web.window.removeEventListener('pagehide', hide);
}

/// A request that outlives the page (fetch keepalive), for last-moment
/// saves on hide/unload. Fire and forget. Returns false where unsupported.
bool keepaliveRequest(
  String method,
  String url,
  Map<String, String> headers,
  String body,
) {
  final h = web.Headers();
  headers.forEach((k, v) => h.set(k, v));
  web.window
      .fetch(
        url.toJS,
        web.RequestInit(
          method: method,
          headers: h,
          body: body.toJS,
          keepalive: true,
          credentials: 'include',
        ),
      )
      .toDart
      .then((_) {}, onError: (Object _) {});
  return true;
}

String? sessionGet(String key) => web.window.sessionStorage.getItem(key);
void sessionSet(String key, String value) =>
    web.window.sessionStorage.setItem(key, value);

/// Survives reloads and new tabs (per browser profile).
String? localGet(String key) => web.window.localStorage.getItem(key);
void localSet(String key, String value) =>
    web.window.localStorage.setItem(key, value);
void localRemove(String key) => web.window.localStorage.removeItem(key);

/// Every key in local storage.
List<String> localKeys() {
  final s = web.window.localStorage;
  return [for (var i = 0; i < s.length; i++) ?s.key(i)];
}

/// The OS "reduce motion" setting (prefers-reduced-motion).
bool get prefersReducedMotion =>
    web.window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/// iOS Safari / CriOS only raises the soft keyboard for a `focus()` that
/// happens synchronously inside `touchend` or `click`, on an `<input>`
/// that was already in the DOM and laid out before the gesture started.
/// Flutter's canvas is the event target, so a capture-phase listener
/// hit-tests registered button rects, focuses a pre-created hidden
/// proxy, and blocks Flutter's editing input from stealing focus until
/// the keyboard is up (`visualViewport` shrink). Focus then moves
/// input-to-input; typing on the proxy is synced into the Dart
/// controller until that handoff.
web.HTMLInputElement? _keyboardPrimer;
Timer? _handoffTimer;
int _handoffTries = 0;
bool _primerInstalled = false;
bool _handoffDone = false;
bool _handoffRafPending = false;
bool _focusPatched = false;
bool _viewFocusBlocked = false;
String? _armedKind;
final _hotspots = <String, _KbHotspot>{};

/// Flutter web's editing input is either a semantics text-field
/// (Safari / iOS) or a node under `flt-text-editing-host`.
const _flutterInputSelector =
    'input[data-semantics-role="text-field"],'
    'textarea[data-semantics-role="text-field"],'
    'flt-text-editing-host input,flt-text-editing-host textarea,'
    'input.flt-text-editing,textarea.flt-text-editing';

/// Skip the New event / New stream open animation on touch web so the
/// field can exist as soon as possible after the tap. Desktop keeps
/// the usual animation and autofocus.
bool get instantSoftKeyboardOpen => _shouldPrimeKeyboard;

/// Install capture-phase listeners. Call once from main().
void installSoftKeyboardPrimer() {
  if (_primerInstalled) return;
  _primerInstalled = true;
  if (!_shouldPrimeKeyboard) return;
  _installFocusPatch();
  // The proxy must already be in the DOM and laid out before the first
  // tap. Creating it inside the gesture is why the first device tap
  // never raised the keyboard (later taps reused the existing node).
  if (web.document.body != null) {
    _ensurePrimer();
  } else {
    web.window.addEventListener(
      'load',
      ((web.Event _) => _ensurePrimer()).toJS,
    );
  }
  _listen('pointerdown', armOnly: true);
  _listen('touchstart', armOnly: true);
  _listen('touchend', prime: true);
  _listen('click', prime: true);
  // After touchend focus, a compatibility mousedown on the canvas can
  // move focus to <body>. Cancel it while the proxy is held.
  web.document.addEventListener(
    'mousedown',
    ((web.Event e) {
      if (_keyboardPrimer == null || _handoffDone || !_viewFocusBlocked) {
        return;
      }
      if (e.cancelable) e.preventDefault();
    }).toJS,
    true.toJS,
  );
}

void _listen(String type, {bool prime = false, bool armOnly = false}) {
  web.document.addEventListener(
    type,
    ((web.Event e) {
      final point = _eventPoint(e);
      final hit = point == null ? null : _hitHotspot(point.x, point.y);
      if (armOnly) {
        // A miss starts a new gesture: do not prime later events from
        // a leftover kind (that used to open the keyboard on a tap
        // anywhere after the first button press).
        if (hit == null) {
          if (type == 'pointerdown' || type == 'touchstart') {
            _armedKind = null;
          }
          return;
        }
        _armViewFocusBlock();
        _armedKind = hit.kind;
        // Set inputmode now so the proxy is already decimal (or text)
        // before touchend focus().
        _ensurePrimer(decimal: hit.kind == 'decimal');
        // Suppress compatibility mouse events that would blur the
        // proxy after the touchend focus.
        if (e.cancelable) e.preventDefault();
        return;
      }
      // Prime only if THIS gesture started on a New / FAB hotspot.
      // Never retarget a later click onto a hotspot that appeared under
      // the finger after the Transactions overlay opened: on a phone the
      // + New button sits where the list-icon tap was, and the
      // compatibility click would otherwise focus the hidden decimal
      // proxy and raise the number pad on an empty list.
      if (prime) {
        if (_armedKind == null) return;
        primeSoftKeyboard(decimal: _armedKind == 'decimal', via: type);
      }
    }).toJS,
    true.toJS,
  );
}

class _KbHotspot {
  _KbHotspot({
    required this.id,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.kind,
  });

  final String id;
  final double left;
  final double top;
  final double width;
  final double height;
  final String kind;

  bool contains(double x, double y, {double pad = 12}) =>
      x >= left - pad &&
      x <= left + width + pad &&
      y >= top - pad &&
      y <= top + height + pad;
}

/// Screen rect of a New event / New stream / FAB / day-add control.
/// The capture listener hit-tests the touch against these rects so it
/// can focus the proxy inside the gesture, without waiting for Dart
/// onTap and without walking event.target (on a real iPhone that is
/// the Flutter glass pane, not a labelled semantics node).
void registerKbHotspot({
  required String id,
  required double left,
  required double top,
  required double width,
  required double height,
  required String kind,
}) {
  _hotspots[id] = _KbHotspot(
    id: id,
    left: left,
    top: top,
    width: width,
    height: height,
    kind: kind,
  );
}

void unregisterKbHotspot(String id) {
  _hotspots.remove(id);
}

_KbHotspot? _hitHotspot(double x, double y) {
  _KbHotspot? best;
  var bestArea = double.infinity;
  for (final h in _hotspots.values) {
    if (!h.contains(x, y)) continue;
    final area = h.width * h.height;
    if (area < bestArea) {
      best = h;
      bestArea = area;
    }
  }
  return best;
}

({double x, double y})? _eventPoint(web.Event e) {
  if (e.isA<web.TouchEvent>()) {
    final te = e as web.TouchEvent;
    final list = te.changedTouches.length > 0 ? te.changedTouches : te.touches;
    if (list.length > 0) {
      final t = list.item(0);
      if (t != null) {
        return (x: t.clientX.toDouble(), y: t.clientY.toDouble());
      }
    }
    return null;
  }
  if (e.isA<web.MouseEvent>()) {
    final m = e as web.MouseEvent;
    return (x: m.clientX.toDouble(), y: m.clientY.toDouble());
  }
  return null;
}

/// Patch HTMLElement.focus / blur so Flutter's view-root focus
/// (Timer(0) requestViewFocusChange, safeBlur) and a raw blur()
/// cannot take focus off the proxy. A blur followed by refocus
/// can dismiss the iOS keyboard, so we skip the steal rather than
/// repairing it afterwards. The Flutter field is allowed through
/// only once [handoffSoftKeyboard] sets the block to `handoff`.
void _installFocusPatch() {
  if (_focusPatched) return;
  _focusPatched = true;
  final script = web.document.createElement('script') as web.HTMLScriptElement;
  script.text = [
    '(function () {',
    '  if (window.__kbFocusPatched) return;',
    '  window.__kbFocusPatched = true;',
    "  var attr = 'data-kb-block';",
    "  var primerSel = '[data-kb-primer=\"1\"]';",
    '  function blocked() {',
    '    var root = document.documentElement;',
    '    return root && root.getAttribute(attr) === "1";',
    '  }',
    '  function primer() { return document.querySelector(primerSel); }',
    '  function handingOff() {',
    '    var root = document.documentElement;',
    '    return root && root.getAttribute(attr) === "handoff";',
    '  }',
    '  function allowed(el) {',
    '    if (!el) return false;',
    '    if (el === primer()) return true;',
    '    if (!handingOff()) return false;',
    '    var role = el.getAttribute && el.getAttribute("data-semantics-role");',
    '    var cls = (el.className && String(el.className)) || "";',
    '    if (role === "text-field") return true;',
    '    if (cls.indexOf("flt-text-editing") !== -1) return true;',
    '    if (el.closest && el.closest("flt-text-editing-host")) return true;',
    '    return false;',
    '  }',
    '  var origFocus = HTMLElement.prototype.focus;',
    '  HTMLElement.prototype.focus = function (opts) {',
    '    if (blocked() && primer() && !allowed(this)) return;',
    '    return origFocus.call(this, opts);',
    '  };',
    '  var origBlur = HTMLElement.prototype.blur;',
    '  HTMLElement.prototype.blur = function () {',
    '    if (blocked() && this === primer()) return;',
    '    return origBlur.call(this);',
    '  };',
    '})();',
  ].join('\n');
  (web.document.head ?? web.document.documentElement)?.append(script);
}

void _armViewFocusBlock() {
  if (_viewFocusBlocked) return;
  _viewFocusBlocked = true;
  web.document.documentElement?.setAttribute('data-kb-block', '1');
}

void _disarmViewFocusBlock() {
  _viewFocusBlocked = false;
  _armedKind = null;
  web.document.documentElement?.removeAttribute('data-kb-block');
}

String _primerCss() =>
    'position:fixed;left:0;bottom:0;width:100%;height:40px;'
    'font-size:16px;line-height:40px;border:0;padding:0;margin:0;'
    'background:transparent;color:transparent;caret-color:transparent;'
    'opacity:0.02;z-index:99999;outline:none;pointer-events:none;';

void Function(String text)? _proxyTextHandler;
double? _viewportAtPrime;
bool _kbViewportHooked = false;
Timer? _inputModeLock;

void _applyInputMode(web.Element el, String mode) {
  if (mode.isEmpty) return;
  el.setAttribute('inputmode', mode);
  if (el.isA<web.HTMLInputElement>()) {
    (el as web.HTMLInputElement).inputMode = mode;
  } else if (el.isA<web.HTMLTextAreaElement>()) {
    (el as web.HTMLTextAreaElement).inputMode = mode;
  }
}

/// Flutter's iOS semantics input is `type=text` and strips `inputmode`
/// on each update, which would swap the decimal pad for the
/// alphanumeric keyboard after handoff. Keep the proxy's mode on the
/// target while it stays focused.
void _lockHandoffInputMode(web.Element el, String mode) {
  _applyInputMode(el, mode);
  _inputModeLock?.cancel();
  _inputModeLock = Timer.periodic(const Duration(milliseconds: 50), (t) {
    final current = web.document.activeElement;
    if (current == null || !_isFlutterField(current)) {
      t.cancel();
      return;
    }
    if (current.getAttribute('inputmode') != mode) {
      _applyInputMode(current, mode);
    }
  });
}

void setSoftKeyboardTextHandler(void Function(String text)? handler) {
  _proxyTextHandler = handler;
}

void _noteViewport() {
  final vv = web.window.visualViewport;
  _viewportAtPrime = (vv?.height ?? web.window.innerHeight).toDouble();
}

bool _keyboardIsUp() {
  final start = _viewportAtPrime;
  if (start == null) return false;
  final now = (web.window.visualViewport?.height ?? web.window.innerHeight)
      .toDouble();
  return start - now > 80;
}

void _onProxyTyped(String text) {
  _proxyTextHandler?.call(text);
  final field = _findFlutterField();
  if (field == null) return;
  if (field.isA<web.HTMLInputElement>()) {
    final inp = field as web.HTMLInputElement;
    if (inp.value != text) {
      inp.value = text;
      inp.dispatchEvent(web.Event('input'));
    }
  } else if (field.isA<web.HTMLTextAreaElement>()) {
    final area = field as web.HTMLTextAreaElement;
    if (area.value != text) {
      area.value = text;
      area.dispatchEvent(web.Event('input'));
    }
  }
}

/// Create (or reuse) the standing proxy. Does not focus it.
web.HTMLInputElement? _ensurePrimer({bool decimal = false}) {
  var existing = _keyboardPrimer;
  if (existing == null || !existing.isConnected) {
    final listed = web.document.querySelector('[data-kb-primer="1"]');
    if (listed != null && listed.isA<web.HTMLInputElement>()) {
      existing = listed as web.HTMLInputElement;
    }
  }
  if (existing != null && existing.isConnected) {
    existing.inputMode = decimal ? 'decimal' : 'text';
    existing.style.cssText = _primerCss();
    _keyboardPrimer = existing;
    return existing;
  }
  existing?.remove();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'text'
    ..inputMode = decimal ? 'decimal' : 'text'
    ..tabIndex = -1
    ..setAttribute('data-kb-primer', '1')
    ..setAttribute('autocomplete', 'off')
    ..setAttribute('autocorrect', 'off')
    ..setAttribute('autocapitalize', 'none')
    ..setAttribute('spellcheck', 'false')
    ..enterKeyHint = 'done';
  input.style.cssText = _primerCss();
  web.document.body?.append(input);
  _keyboardPrimer = input;
  input.addEventListener('blur', ((web.Event _) => _onPrimerBlur()).toJS);
  input.addEventListener(
    'input',
    ((web.Event _) => _onProxyTyped(input.value)).toJS,
  );
  return input;
}

void primeSoftKeyboard({bool decimal = false, String? via}) {
  if (!_shouldPrimeKeyboard) return;
  final input = _ensurePrimer(decimal: decimal);
  if (input == null) return;
  // Dart onPointerUp / showDialog must not focus: on CriOS that ran
  // at pointerup, before touchend. Capture-phase touchend/click owns
  // focus().
  if (via == null || via == 'dart') return;
  _handoffTimer?.cancel();
  _inputModeLock?.cancel();
  _handoffTries = 0;
  _handoffDone = false;
  _handoffRafPending = false;
  _noteViewport();
  input.focus(web.FocusOptions(preventScroll: true));
}

void _onPrimerBlur() {
  final input = _keyboardPrimer;
  if (input == null || _handoffDone) return;
  final active = web.document.activeElement;
  if (active != null && _isFlutterField(active)) {
    scheduleMicrotask(_dropPrimer);
    return;
  }
  // _tryHandoff sets data-kb-block=handoff, then focuses the field.
  // During that transition WebKit reports activeElement as <body>.
  final block = web.document.documentElement?.getAttribute('data-kb-block');
  if (block == 'handoff') return;
}

/// Move focus from the proxy to Flutter's text-editing input, once
/// the keyboard is visibly up (visualViewport shrink). Safe to call
/// on every requestFocus; it no-ops when nothing was primed (desktop,
/// edit views). Until then, typed text is synced into the Dart
/// controller via [setSoftKeyboardTextHandler].
void handoffSoftKeyboard() {
  if (_keyboardPrimer == null) return;
  if (_handoffDone) return;
  if (_handoffRafPending) return;
  _handoffRafPending = true;
  _noteViewport();
  if (!_kbViewportHooked) {
    _kbViewportHooked = true;
    web.window.visualViewport?.addEventListener(
      'resize',
      ((web.Event _) {
        if (_handoffDone || _keyboardPrimer == null) return;
        if (_keyboardIsUp()) _tryHandoff();
      }).toJS,
    );
  }
  _handoffTimer?.cancel();
  _handoffTries = 0;
  _handoffTimer = Timer.periodic(const Duration(milliseconds: 50), (t) {
    if (_handoffDone || _keyboardPrimer == null) {
      t.cancel();
      _handoffRafPending = false;
      return;
    }
    if (_keyboardIsUp()) {
      _tryHandoff();
      t.cancel();
      _handoffRafPending = false;
      return;
    }
    _handoffTries++;
    // Give the keyboard time to appear; then hand off anyway so
    // desktop / WebKit emulation (no visualViewport shrink) still
    // reaches the Flutter field.
    if (_handoffTries >= 16) {
      _tryHandoff();
      t.cancel();
      _handoffRafPending = false;
    }
  });
}

bool _isPrimer(web.Element el) =>
    identical(el, _keyboardPrimer) || el.getAttribute('data-kb-primer') == '1';

bool _isFlutterField(web.Element el) {
  if (_isPrimer(el)) return false;
  if (el.getAttribute('data-semantics-role') == 'text-field') return true;
  final cls = el.getAttribute('class') ?? '';
  if (cls.contains('flt-text-editing')) return true;
  var p = el.parentElement;
  while (p != null) {
    if (p.nodeName == 'FLT-TEXT-EDITING-HOST') return true;
    p = p.parentElement;
  }
  return false;
}

web.Element? _findFlutterField() {
  final list = web.document.querySelectorAll(_flutterInputSelector);
  for (var i = 0; i < list.length; i++) {
    final node = list.item(i);
    if (node == null || node.nodeName == '#text') continue;
    final el = node as web.Element;
    if (_isPrimer(el)) continue;
    return el;
  }
  return null;
}

/// Make the semantics input a keyboard-worthy target (attached, not
/// display:none, non-zero size, font-size 16, not fully transparent)
/// so the handoff is a direct input→input focus, not proxy→body.
bool _prepareHandoffTarget(web.Element el) {
  if (!el.isConnected) return false;
  if (el.getAttribute('disabled') != null) return false;
  final he = el as web.HTMLElement;
  final st = web.window.getComputedStyle(he);
  if (st.display == 'none' || st.visibility == 'hidden') return false;
  he.style.fontSize = '16px';
  if (he.offsetWidth < 16) he.style.minWidth = '16px';
  if (he.offsetHeight < 16) he.style.minHeight = '16px';
  if (st.opacity == '0') he.style.opacity = '0.02';
  final mode = _keyboardPrimer?.inputMode ?? '';
  if (mode.isNotEmpty) _applyInputMode(he, mode);
  return he.offsetWidth >= 16 && he.offsetHeight >= 16;
}

bool _tryHandoff() {
  if (_handoffDone || _keyboardPrimer == null) return true;
  final active = web.document.activeElement;
  if (active != null && _isFlutterField(active)) {
    final mode = _keyboardPrimer?.inputMode ?? '';
    if (mode.isNotEmpty) _lockHandoffInputMode(active, mode);
    scheduleMicrotask(_dropPrimer);
    return true;
  }
  final next = _findFlutterField();
  if (next == null) return false;
  if (!_prepareHandoffTarget(next)) return false;
  // Copy anything already typed on the proxy, then allow this field
  // through the focus patch (block=handoff) and move focus directly.
  final typed = _keyboardPrimer?.value ?? '';
  if (typed.isNotEmpty) _onProxyTyped(typed);
  web.document.documentElement?.setAttribute('data-kb-block', 'handoff');
  (next as web.HTMLElement).focus(web.FocusOptions(preventScroll: true));
  final mode = _keyboardPrimer?.inputMode ?? '';
  final now = web.document.activeElement;
  if (now != null && _isFlutterField(now)) {
    if (mode.isNotEmpty) _lockHandoffInputMode(now, mode);
    scheduleMicrotask(_dropPrimer);
    return true;
  }
  return false;
}

void _dropPrimer() {
  _handoffTimer?.cancel();
  _handoffTimer = null;
  _handoffDone = true;
  _disarmViewFocusBlock();
  final input = _keyboardPrimer;
  if (input != null) {
    // Keep the standing proxy in the DOM so the next first tap does
    // not have to create it inside the gesture.
    input.value = '';
  }
}

/// Drop a primed proxy so the iOS keyboard hides. Used when the
/// Transactions list (or any view with no text field) is shown, so a
/// leftover or mistaken prime cannot leave the decimal pad up.
///
/// Disarms the focus patch first: while `data-kb-block` is set, the
/// patched `blur()` on the proxy is a no-op.
void releaseSoftKeyboard() {
  _handoffTimer?.cancel();
  _handoffTimer = null;
  _inputModeLock?.cancel();
  _handoffRafPending = false;
  _handoffDone = true;
  _disarmViewFocusBlock();
  final input = _keyboardPrimer;
  if (input == null) return;
  input.value = '';
  input.blur();
}

bool get _shouldPrimeKeyboard {
  final w = web.window;
  if (w.matchMedia('(pointer: coarse)').matches) return true;
  if (w.navigator.maxTouchPoints > 0 && w.matchMedia('(hover: none)').matches) {
    return true;
  }
  return false;
}

/// The clipboard's text, read with `navigator.clipboard.readText()`. Call it
/// synchronously from the tap (iOS Safari only allows the read inside the
/// user's gesture, and then shows its own "Paste" button to confirm).
/// Throws a [ClipboardReadException] when the read is denied or the
/// browser has no clipboard API (e.g. an insecure origin).
Future<String?> readClipboardText() async {
  final web.Clipboard? clip = web.window.navigator.clipboard as web.Clipboard?;
  if (clip == null) {
    throw const ClipboardReadException('This browser can’t read the clipboard');
  }
  try {
    final text = await clip.readText().toDart;
    return text.toDart;
  } catch (e) {
    throw ClipboardReadException('$e');
  }
}

/// The clipboard could not be read (denied, unavailable or failed).
class ClipboardReadException implements Exception {
  const ClipboardReadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The primary pointer is a finger (phones, tablets).
bool get coarsePointer => web.window.matchMedia('(pointer: coarse)').matches;
