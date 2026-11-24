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

web.HTMLInputElement? _keyboardPrimer;
Timer? _handoffTimer;
int _handoffTries = 0;
bool _primerInstalled = false;
bool _handoffDone = false;
String? _variant;

/// Flutter web's editing input is either a semantics text-field
/// (Safari / iOS) or a node under `flt-text-editing-host`.
const _flutterInputSelector =
    'input[data-semantics-role="text-field"],'
    'textarea[data-semantics-role="text-field"],'
    'flt-text-editing-host input,flt-text-editing-host textarea,'
    'input.flt-text-editing,textarea.flt-text-editing';

/// In-app strategy from `?kb=` (search or hash query). Default `a`.
///
/// * a — prime on pointerdown/touchstart (before Flutter's
///   preventDefault), skip the open animation, hand off to Flutter's
///   field, re-assert proxy focus if something steals it.
/// * b — same prime and instant open, but do not hand off (keeps the
///   proxy focused; tests whether the handoff is what dismisses the
///   keyboard).
/// * c — previous approach: prime on touchend/click, instant open,
///   hand off.
/// * d — no proxy; just skip the open animation and requestFocus on
///   the first frame.
String get softKeyboardVariant => _variant ??= _readKbParam() ?? 'a';

/// Skip the New event / New stream open animation on touch web so the
/// field can exist as soon as possible after the tap.
bool get instantSoftKeyboardOpen => _shouldPrimeKeyboard;

String? _readKbParam() {
  String? from(String raw) {
    final q = raw.startsWith('?') ? raw.substring(1) : raw;
    if (q.isEmpty) return null;
    final params = Uri.splitQueryString(q);
    final v = params['kb']?.toLowerCase();
    if (v == 'a' || v == 'b' || v == 'c' || v == 'd') return v;
    return null;
  }

  final loc = web.window.location;
  final search = from(loc.search);
  if (search != null) return search;
  final hash = loc.hash;
  final qi = hash.indexOf('?');
  if (qi >= 0) return from(hash.substring(qi));
  return null;
}

void _kbLog(String ev, [web.Element? el]) {
  final a = el ?? web.document.activeElement;
  final tag = a?.nodeName ?? '';
  final typ = a?.getAttribute('type') ?? '';
  final mode = a?.getAttribute('inputmode') ?? '';
  final ph = a?.getAttribute('placeholder') ?? '';
  final role = a?.getAttribute('data-semantics-role') ?? '';
  final line = '$ev tag=$tag type=$typ mode=$mode ph=$ph role=$role';
  final root = web.document.documentElement;
  if (root == null) return;
  final prev = root.getAttribute('data-kb') ?? '';
  root.setAttribute('data-kb', prev.isEmpty ? line : '$prev||$line');
}

/// Install capture-phase listeners so the proxy is focused inside the
/// trusted gesture, *before* Flutter's Dart handler and (for `a`/`b`)
/// before the engine's pointerdown preventDefault + Timer(0) view
/// focus, which can void iOS's keyboard permission. Call once from
/// main().
void installSoftKeyboardPrimer() {
  if (_primerInstalled) return;
  _primerInstalled = true;
  // Force a read so the badge and listeners agree on the variant.
  final v = softKeyboardVariant;
  if (!_shouldPrimeKeyboard) return;
  void badge() => _showVariantBadge(v);
  if (web.document.body != null) {
    badge();
  } else {
    web.window.addEventListener('load', ((web.Event _) => badge()).toJS);
  }
  if (v == 'd') return;
  void listen(String type, {bool reassert = false}) {
    web.document.addEventListener(
      type,
      ((web.Event e) {
        if (reassert) {
          if (_keyboardPrimer != null && !_handoffDone) {
            primeSoftKeyboard(via: '$type-capture');
          }
          return;
        }
        final kind = _kindFromEvent(e);
        if (kind == null) return;
        primeSoftKeyboard(decimal: kind == 'decimal', via: '$type-capture');
      }).toJS,
      true.toJS,
    );
  }

  if (v == 'c') {
    listen('touchend');
    listen('click');
  } else {
    // a, b: focus on the events that start the gesture, before the
    // engine preventDefault's pointerdown on the Flutter view.
    listen('pointerdown');
    listen('touchstart');
    // Re-assert in the same gesture if Timer(0) already ran between
    // down and up (it usually has not; this is still a trusted event).
    listen('pointerup', reassert: true);
    listen('touchend', reassert: true);
  }
}

void _showVariantBadge(String v) {
  const labels = {
    'a': 'kb=a · pointerdown + handoff',
    'b': 'kb=b · pointerdown, keep proxy',
    'c': 'kb=c · touchend + handoff',
    'd': 'kb=d · instant open, no proxy',
  };
  final existing = web.document.getElementById('kb-variant-badge');
  existing?.remove();
  final el = web.document.createElement('div') as web.HTMLElement
    ..id = 'kb-variant-badge'
    ..textContent = labels[v] ?? 'kb=$v';
  el.style.cssText =
      'position:fixed;top:6px;left:6px;z-index:2147483646;'
      'font:12px/1.3 -apple-system,system-ui,sans-serif;'
      'background:#0e1a22;color:#b8f3e4;border:1px solid #2a9d8f;'
      'border-radius:8px;padding:5px 8px;opacity:0.92;'
      'pointer-events:none;';
  web.document.body?.append(el);
}

String? _kindFromEvent(web.Event e) {
  web.Node? node = e.target as web.Node?;
  var depth = 0;
  while (node != null && depth < 30) {
    depth++;
    final name = node.nodeName;
    if (name != '#text' &&
        name != '#document' &&
        name != 'HTML' &&
        name != 'BODY' &&
        name != 'FLUTTER-VIEW') {
      final el = node as web.Element;
      final aria = el.getAttribute('aria-label') ?? '';
      final kind = _primeKindFromLabel(aria);
      if (kind != null) return kind;
      if (name == 'SPAN' ||
          name == 'BUTTON' ||
          name == 'A' ||
          name == 'FLT-SEMANTICS' ||
          name.startsWith('FLT-SEMANTIC')) {
        final text = el.textContent ?? '';
        if (text.length < 80) {
          final k = _primeKindFromLabel(text);
          if (k != null) return k;
        }
      }
    }
    node = node.parentNode;
  }
  return null;
}

String? _primeKindFromLabel(String raw) {
  final line = raw.trim().split('\n').first.trim().toLowerCase();
  if (line.isEmpty) return null;
  if (line == 'new stream' || line.startsWith('new stream ')) {
    return 'text';
  }
  if (line == 'new' ||
      line == 'new event' ||
      line == 'new event from here' ||
      line.startsWith('new event ') ||
      line.startsWith('add an event')) {
    return 'decimal';
  }
  return null;
}

/// Touch browsers (iOS Safari especially) only raise the soft keyboard
/// for a focus() made inside the user's gesture. Flutter's text-editing
/// input does not exist yet, so a proxy input is focused now; once
/// Flutter has created its own, [handoffSoftKeyboard] moves focus to
/// it (iOS keeps the keyboard open when focus moves input-to-input),
/// unless variant `b` keeps the proxy.
///
/// The proxy is a real, in-viewport 16px field (not a 1x1 opacity-0
/// node: iOS ignores those). It stays until the handoff, not until
/// the first blur — dropping it before Flutter's input exists is
/// what left a painted caret with no system keyboard.
void primeSoftKeyboard({bool decimal = false, String? via}) {
  if (!_shouldPrimeKeyboard) return;
  if (softKeyboardVariant == 'd') return;
  _handoffTimer?.cancel();
  _handoffTries = 0;
  _handoffDone = false;
  final src = via ?? 'dart';
  final existing = _keyboardPrimer;
  if (existing != null && existing.isConnected) {
    if (decimal) existing.inputMode = 'decimal';
    existing.focus(web.FocusOptions(preventScroll: true));
    _kbLog('prime-reuse via=$src');
    return;
  }
  existing?.remove();
  web.document.documentElement?.setAttribute('data-kb', '');
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
  input.style.cssText =
      'position:fixed;left:0;bottom:0;width:100%;height:40px;'
      'font-size:16px;line-height:40px;border:0;padding:0;margin:0;'
      'background:transparent;color:transparent;caret-color:transparent;'
      'opacity:0.02;z-index:99999;outline:none;pointer-events:none;';
  web.document.body?.append(input);
  _keyboardPrimer = input;
  input.addEventListener('blur', ((web.Event _) => _onPrimerBlur()).toJS);
  input.focus(web.FocusOptions(preventScroll: true));
  _kbLog('prime via=$src');
  Timer(const Duration(seconds: 20), () {
    if (identical(_keyboardPrimer, input)) _dropPrimer();
  });
}

void _onPrimerBlur() {
  final input = _keyboardPrimer;
  if (input == null || _handoffDone) return;
  final active = web.document.activeElement;
  if (active != null && _isFlutterField(active)) {
    if (softKeyboardVariant != 'b') {
      _kbLog('blur-to-field', active);
      scheduleMicrotask(_dropPrimer);
    }
    return;
  }
  // Engine Timer(0) requestViewFocusChange / safeBlur often moves
  // focus to flutter-view. Pull it back so a keyboard that already
  // opened stays up, and so later handoff is still input-to-input.
  scheduleMicrotask(() {
    if (_keyboardPrimer == null || _handoffDone) return;
    final now = web.document.activeElement;
    if (now != null && _isFlutterField(now)) return;
    if (!identical(web.document.activeElement, input)) {
      input.focus(web.FocusOptions(preventScroll: true));
      _kbLog('guard-refocus');
    }
  });
}

/// Move focus from the proxy to Flutter's text-editing input, once
/// that node exists. Safe to call on every requestFocus; it no-ops
/// when nothing was primed (desktop, edit views, or variants b/d).
void handoffSoftKeyboard() {
  if (_keyboardPrimer == null) return;
  if (softKeyboardVariant == 'b' || softKeyboardVariant == 'd') return;
  if (_tryHandoff()) return;
  _handoffTimer?.cancel();
  _handoffTries = 0;
  _handoffTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
    _handoffTries++;
    if (_tryHandoff() || _handoffTries > 60) t.cancel();
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

bool _tryHandoff() {
  final active = web.document.activeElement;
  if (active != null && _isFlutterField(active)) {
    _kbLog('handoff-already', active);
    scheduleMicrotask(_dropPrimer);
    return true;
  }
  final list = web.document.querySelectorAll(_flutterInputSelector);
  web.Element? next;
  for (var i = 0; i < list.length; i++) {
    final node = list.item(i);
    if (node == null || node.nodeName == '#text') continue;
    final el = node as web.Element;
    if (_isPrimer(el)) continue;
    next = el;
    break;
  }
  if (next == null) {
    _kbLog('handoff-wait');
    return false;
  }
  (next as web.HTMLElement).focus(web.FocusOptions(preventScroll: true));
  _kbLog('handoff', next);
  scheduleMicrotask(_dropPrimer);
  return true;
}

void _dropPrimer() {
  _handoffTimer?.cancel();
  _handoffTimer = null;
  _handoffDone = true;
  final input = _keyboardPrimer;
  _keyboardPrimer = null;
  input?.remove();
  _kbLog('drop');
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
