import 'dart:async';
import 'dart:convert';
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
Timer? _debugPostTimer;
int _handoffTries = 0;
bool _primerInstalled = false;
bool _handoffDone = false;
bool _handoffRafPending = false;
bool _focusPatched = false;
bool _viewFocusBlocked = false;
String? _armedKind;
String? _variant;
bool? _kbdebug;
final _hotspots = <String, _KbHotspot>{};
final _overlays = <String, web.HTMLInputElement>{};
String? _lastRectsLog;
const _compiledBuildId = String.fromEnvironment('BUILD_ID');

/// Flutter web's editing input is either a semantics text-field
/// (Safari / iOS) or a node under `flt-text-editing-host`.
const _flutterInputSelector =
    'input[data-semantics-role="text-field"],'
    'textarea[data-semantics-role="text-field"],'
    'flt-text-editing-host input,flt-text-editing-host textarea,'
    'input.flt-text-editing,textarea.flt-text-editing';

/// In-app strategy from `?kb=` (search or hash query). Default `a`.
///
/// * a — default. Capture-phase touchend/pointerup/click primes the
///   proxy when the point hits a registered New-event / New-stream /
///   FAB / day-add rect (not by walking event.target). Flutter's
///   Timer(0) view-focus steal is blocked from pointerdown. After one
///   requestAnimationFrame, focus moves to Flutter's field.
/// * b — previous default: prime on pointerdown/touchstart and hand
///   off (does not open the keyboard on a real iPhone).
/// * c — same prime as a, but the proxy stays focused (no handoff).
/// * d — a real transparent `<input>` sits on each hotspot so the
///   finger lands on a native field; then rAF-handoff to Flutter's
///   field. This is the HtmlElementView-style fallback.
/// * e — like a, but the proxy is a fully visible (opacity 1, 16px
///   font, normal size) input parked just off-screen, focused in the
///   same touchend, then handed off.
String get softKeyboardVariant {
  if (_variant != null) return _variant!;
  final v = _readFlag('kb');
  _variant = (v == 'a' || v == 'b' || v == 'c' || v == 'd' || v == 'e')
      ? v
      : 'a';
  return _variant!;
}

/// When the URL has `?kbdebug=1`, POST the focus log to `/api/kbdebug`.
bool get kbDebugEnabled => _kbdebug ??= _readFlag('kbdebug') == '1';

/// Skip the New event / New stream open animation on touch web so the
/// field can exist as soon as possible after the tap.
bool get instantSoftKeyboardOpen => _shouldPrimeKeyboard;

String? _readFlag(String name) {
  String? from(String raw) {
    final q = raw.startsWith('?') ? raw.substring(1) : raw;
    if (q.isEmpty) return null;
    return Uri.splitQueryString(q)[name]?.toLowerCase();
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
  final ms = web.window.performance.now().toStringAsFixed(0);
  final line = '${ms}ms $ev ${_fieldSnap(a)}';
  final root = web.document.documentElement;
  if (root == null) return;
  final prev = root.getAttribute('data-kb') ?? '';
  var next = prev.isEmpty ? line : '$prev||$line';
  if (next.length > 12000) {
    final cut = next.indexOf('||', next.length - 12000);
    next = cut >= 0
        ? next.substring(cut + 2)
        : next.substring(next.length - 12000);
  }
  root.setAttribute('data-kb', next);
  if (kbDebugEnabled) _scheduleKbDebugPost();
}

String _fieldSnap(web.Element? a) {
  if (a == null) return 'tag=null';
  web.HTMLElement? he;
  web.CSSStyleDeclaration? st;
  if (a.nodeName != '#text' && a.nodeName != '#document') {
    he = a as web.HTMLElement;
    st = web.window.getComputedStyle(he);
  }
  return 'tag=${a.nodeName} type=${a.getAttribute('type') ?? ''} '
      'mode=${a.getAttribute('inputmode') ?? ''} '
      'ph=${a.getAttribute('placeholder') ?? ''} '
      'role=${a.getAttribute('data-semantics-role') ?? ''} '
      'ro=${a.getAttribute('readonly') ?? ''} '
      'dis=${a.getAttribute('disabled') ?? ''} '
      'w=${he?.offsetWidth ?? 0} h=${he?.offsetHeight ?? 0} '
      'op=${st?.opacity ?? ''} disp=${st?.display ?? ''} '
      'vis=${st?.visibility ?? ''} fs=${st?.fontSize ?? ''} '
      'conn=${a.isConnected}';
}

void _scheduleKbDebugPost() {
  _debugPostTimer?.cancel();
  _debugPostTimer = Timer(const Duration(milliseconds: 600), _postKbDebug);
}

void _postKbDebug() {
  final root = web.document.documentElement;
  final payload = jsonEncode({
    'v': 1,
    'build': _compiledBuildId,
    'kb': softKeyboardVariant,
    'ua': web.window.navigator.userAgent,
    'href': web.window.location.href,
    'active': _fieldSnap(web.document.activeElement),
    'log': root?.getAttribute('data-kb') ?? '',
    'rects': _rectsSummary(),
    'ts': DateTime.now().toUtc().toIso8601String(),
  });
  keepaliveRequest('POST', '/api/kbdebug', const {
    'content-type': 'application/json',
    'x-requested-with': 'budget-kbdebug',
  }, payload);
}

/// Install capture-phase listeners. Call once from main().
void installSoftKeyboardPrimer() {
  if (_primerInstalled) return;
  _primerInstalled = true;
  final v = softKeyboardVariant;
  if (kbDebugEnabled) {
    onPageHidden(_postKbDebug);
    final nav = web.window.navigator;
    _kbLog(
      'debug-on build=$_compiledBuildId kb=$v '
      'coarse=${web.window.matchMedia('(pointer: coarse)').matches} '
      'hoverNone=${web.window.matchMedia('(hover: none)').matches} '
      'maxTouch=${nav.maxTouchPoints} '
      'ua=${nav.userAgent}',
    );
  }
  if (!_shouldPrimeKeyboard) return;
  void badge() => _showVariantBadge(v);
  if (web.document.body != null) {
    badge();
  } else {
    web.window.addEventListener('load', ((web.Event _) => badge()).toJS);
  }
  _installFocusPatch();

  // Always observe these on capture so a miss still shows up in kbdebug.
  // Hit-testing uses registered rects (gesture-time), not event.target.
  if (v == 'b') {
    _listen('pointerdown', prime: true);
    _listen('touchstart', prime: true);
    _listen('pointerup', reassert: true);
    _listen('touchend', reassert: true);
    _listen('click', reassert: true);
    return;
  }

  // a, c, d, e: arm the steal-block on pointerdown/touchstart; prime
  // on touchend/pointerup/click. Variant d's overlay already receives
  // the tap natively; the listener still arms the block and logs.
  _listen('pointerdown', armOnly: true);
  _listen('touchstart', armOnly: true);
  _listen('touchend', prime: true);
  _listen('pointerup', prime: true);
  _listen('click', prime: true);
  // After touchend focus, a compatibility mousedown on the canvas can
  // move focus to <body>. Cancel it while the proxy is held. Not on
  // d: the overlay input needs its default mouse sequence.
  web.document.addEventListener(
    'mousedown',
    ((web.Event e) {
      if (!_stealBlockVariant || softKeyboardVariant == 'd') return;
      if (_keyboardPrimer == null || _handoffDone || !_viewFocusBlocked) {
        return;
      }
      if (e.cancelable) e.preventDefault();
      _kbLog('block-mousedown');
    }).toJS,
    true.toJS,
  );
}

bool get _stealBlockVariant {
  final v = softKeyboardVariant;
  return v == 'a' || v == 'c' || v == 'd' || v == 'e';
}

void _listen(
  String type, {
  bool prime = false,
  bool reassert = false,
  bool armOnly = false,
}) {
  web.document.addEventListener(
    type,
    ((web.Event e) {
      final point = _eventPoint(e);
      final targetName = _eventTargetName(e);
      final rectHit = point == null ? null : _hitHotspot(point.x, point.y);
      final labelHit = _kindFromEvent(e);
      final kind =
          rectHit?.kind ??
          labelHit ??
          ((prime || reassert) ? _armedKind : null);
      if (kbDebugEnabled) {
        final xy = point == null
            ? '-'
            : '${point.x.toStringAsFixed(0)},${point.y.toStringAsFixed(0)}';
        final hit = rectHit == null ? 'miss' : '${rectHit.id}/${rectHit.kind}';
        _kbLog(
          'ev=$type tgt=$targetName xy=$xy hit=$hit '
          'label=${labelHit ?? '-'} kind=${kind ?? '-'}',
        );
      }
      if (reassert) {
        if (_keyboardPrimer != null && !_handoffDone) {
          primeSoftKeyboard(via: '$type-capture');
        }
        return;
      }
      if (kind == null) return;
      if (armOnly) {
        if (_stealBlockVariant) {
          _armViewFocusBlock();
          _armedKind = kind;
          _kbLog('arm-block via=$type id=${rectHit?.id ?? 'label'}');
          // Same as kbtest 3a: suppress compatibility mouse events that
          // would blur the proxy after the touchend focus. Skip on d so
          // the overlay input can take focus natively.
          if (softKeyboardVariant != 'd' && e.cancelable) e.preventDefault();
        } else {
          _armedKind = kind;
        }
        return;
      }
      if (prime) {
        if (_stealBlockVariant) _armViewFocusBlock();
        _armedKind = kind;
        if (softKeyboardVariant == 'd') return;
        primeSoftKeyboard(decimal: kind == 'decimal', via: '$type-capture');
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
    this.onActivate,
  });

  final String id;
  final double left;
  final double top;
  final double width;
  final double height;
  final String kind;
  final void Function()? onActivate;

  bool contains(double x, double y, {double pad = 12}) =>
      x >= left - pad &&
      x <= left + width + pad &&
      y >= top - pad &&
      y <= top + height + pad;

  String get summary =>
      '$id:${left.toStringAsFixed(0)},${top.toStringAsFixed(0)},'
      '${width.toStringAsFixed(0)},${height.toStringAsFixed(0)},$kind';
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
  void Function()? onActivate,
}) {
  final prev = _hotspots[id];
  final next = _KbHotspot(
    id: id,
    left: left,
    top: top,
    width: width,
    height: height,
    kind: kind,
    onActivate: onActivate,
  );
  _hotspots[id] = next;
  final moved =
      prev == null ||
      prev.left != left ||
      prev.top != top ||
      prev.width != width ||
      prev.height != height ||
      prev.kind != kind;
  if (moved) _logRectsIfChanged();
  if (softKeyboardVariant == 'd' && _shouldPrimeKeyboard) {
    _syncOverlay(next);
  }
}

void unregisterKbHotspot(String id) {
  if (_hotspots.remove(id) == null) return;
  _removeOverlay(id);
  _logRectsIfChanged();
}

String _rectsSummary() => _hotspots.values.map((h) => h.summary).join(';');

void _logRectsIfChanged() {
  final s = _rectsSummary();
  if (s == _lastRectsLog) return;
  _lastRectsLog = s;
  _kbLog('rects n=${_hotspots.length} $s');
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

String _eventTargetName(web.Event e) {
  final t = e.target;
  if (t == null) return 'null';
  try {
    return (t as web.Node).nodeName;
  } catch (_) {
    return '?';
  }
}

double _overlayActivateAt = 0;

void _syncOverlay(_KbHotspot h) {
  var el = _overlays[h.id];
  if (el == null || !el.isConnected) {
    el?.remove();
    el = web.document.createElement('input') as web.HTMLInputElement
      ..type = 'text'
      ..inputMode = h.kind == 'decimal' ? 'decimal' : 'text'
      ..tabIndex = 0
      ..id = 'kb-hot-${h.id}'
      ..setAttribute('data-kb-hot', h.id)
      ..setAttribute('autocomplete', 'off')
      ..setAttribute('autocorrect', 'off')
      ..setAttribute('autocapitalize', 'none')
      ..setAttribute('spellcheck', 'false')
      ..enterKeyHint = 'done';
    el.addEventListener(
      'focus',
      ((web.Event _) {
        final cur = _hotspots[h.id];
        if (cur == null) return;
        _onOverlayFocus(cur, el!);
      }).toJS,
    );
    el.addEventListener(
      'touchend',
      ((web.Event _) {
        final cur = _hotspots[h.id];
        if (cur != null) _onOverlayActivate(cur);
      }).toJS,
    );
    el.addEventListener(
      'click',
      ((web.Event _) {
        final cur = _hotspots[h.id];
        if (cur != null) _onOverlayActivate(cur);
      }).toJS,
    );
    el.addEventListener('blur', ((web.Event ev) => _onPrimerBlur(ev)).toJS);
    web.document.body?.append(el);
    _overlays[h.id] = el;
  }
  el.inputMode = h.kind == 'decimal' ? 'decimal' : 'text';
  el.style.cssText =
      'position:fixed;left:${h.left}px;top:${h.top}px;'
      'width:${h.width}px;height:${h.height}px;'
      'font-size:16px;border:0;padding:0;margin:0;'
      'background:transparent;color:transparent;caret-color:transparent;'
      'opacity:0.02;z-index:2147483645;outline:none;pointer-events:auto;';
}

void _onOverlayFocus(_KbHotspot h, web.HTMLInputElement el) {
  _armViewFocusBlock();
  _handoffTimer?.cancel();
  _handoffTries = 0;
  _handoffDone = false;
  _handoffRafPending = false;
  _keyboardPrimer = el;
  el.setAttribute('data-kb-primer', '1');
  _kbLog('prime via=overlay-native id=${h.id}');
}

void _onOverlayActivate(_KbHotspot h) {
  final now = web.window.performance.now();
  if (now - _overlayActivateAt < 400) return;
  _overlayActivateAt = now;
  _kbLog('overlay-activate id=${h.id}');
  h.onActivate?.call();
}

void _removeOverlay(String id) {
  final el = _overlays.remove(id);
  if (identical(_keyboardPrimer, el)) _keyboardPrimer = null;
  el?.remove();
}

/// Patch HTMLElement.focus / blur so Flutter's view-root focus
/// (Timer(0) requestViewFocusChange, safeBlur) and a raw blur()
/// cannot take focus off the proxy. A blur followed by refocus
/// can dismiss the iOS keyboard, so we skip the steal rather than
/// repairing it afterwards. Also log focusin/focusout with
/// relatedTarget and a stack (for kbdebug).
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
    '  function allowed(el) {',
    '    if (!el) return false;',
    '    if (el === primer()) return true;',
    '    if (el.getAttribute && el.getAttribute("data-kb-hot")) return true;',
    '    var role = el.getAttribute && el.getAttribute("data-semantics-role");',
    '    var cls = (el.className && String(el.className)) || "";',
    '    if (role === "text-field") return true;',
    '    if (cls.indexOf("flt-text-editing") !== -1) return true;',
    '    if (el.closest && el.closest("flt-text-editing-host")) return true;',
    '    return false;',
    '  }',
    '  function log(line) {',
    '    var root = document.documentElement;',
    '    if (!root) return;',
    '    var prev = root.getAttribute("data-kb") || "";',
    '    root.setAttribute("data-kb", prev ? prev + "||" + line : line);',
    '  }',
    '  function snap(el) {',
    '    if (!el) return "null";',
    '    var role = (el.getAttribute && el.getAttribute("data-semantics-role")) || "";',
    '    var id = el.id ? ("#" + el.id) : "";',
    '    return (el.tagName || "?") + id + (role ? (" role=" + role) : "");',
    '  }',
    '  function stack() {',
    '    try { return String((new Error()).stack || "").replace(/\\s+/g, " ").slice(0, 360); }',
    '    catch (x) { return ""; }',
    '  }',
    '  var origFocus = HTMLElement.prototype.focus;',
    '  HTMLElement.prototype.focus = function (opts) {',
    '    if (blocked() && primer() && !allowed(this)) {',
    '      log("block-view-focus tag=" + (this.tagName || "") + " type= mode= ph= role=");',
    '      return;',
    '    }',
    '    return origFocus.call(this, opts);',
    '  };',
    '  var origBlur = HTMLElement.prototype.blur;',
    '  HTMLElement.prototype.blur = function () {',
    '    if (blocked() && this === primer()) {',
    '      log("block-primer-blur tag=" + (this.tagName || "") + " type= mode= ph= role= stack=" + stack());',
    '      return;',
    '    }',
    '    return origBlur.call(this);',
    '  };',
    '  document.addEventListener("focusout", function (e) {',
    '    var p = primer();',
    '    if (!p || e.target !== p) return;',
    '    var ms = (window.performance && performance.now()) ? performance.now().toFixed(0) : "0";',
    '    log(ms + "ms primer-focusout rel=" + snap(e.relatedTarget) + " stack=" + stack());',
    '  }, true);',
    '  document.addEventListener("focusin", function (e) {',
    '    if (!blocked()) return;',
    '    var ms = (window.performance && performance.now()) ? performance.now().toFixed(0) : "0";',
    '    log(ms + "ms focusin tag=" + snap(e.target) + " rel=" + snap(e.relatedTarget));',
    '  }, true);',
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

void _showVariantBadge(String v) {
  const labels = {
    'a': 'kb=a · rect touchend + rAF handoff',
    'b': 'kb=b · pointerdown + handoff',
    'c': 'kb=c · rect touchend, no handoff',
    'd': 'kb=d · input under finger + handoff',
    'e': 'kb=e · visible off-screen input + handoff',
  };
  final existing = web.document.getElementById('kb-variant-badge');
  existing?.remove();
  final el = web.document.createElement('div') as web.HTMLElement
    ..id = 'kb-variant-badge'
    ..textContent =
        '${labels[v] ?? 'kb=$v'}'
        '${_compiledBuildId.isEmpty ? '' : ' · $_compiledBuildId'}'
        '${kbDebugEnabled ? ' · debug' : ''}';
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

String _primerCss() {
  if (softKeyboardVariant == 'e') {
    // Visible, normal-size, 16px. Parked just above the viewport so
    // it is off-screen but not display:none / visibility:hidden /
    // opacity:0 (those are the cases iOS is known to ignore).
    return 'position:fixed;left:8px;top:-56px;width:calc(100% - 16px);height:40px;'
        'font-size:16px;line-height:40px;border:1px solid #94a3b8;padding:0 8px;margin:0;'
        'background:#fff;color:#111;caret-color:#111;'
        'opacity:1;z-index:99999;outline:none;pointer-events:none;';
  }
  return 'position:fixed;left:0;bottom:0;width:100%;height:40px;'
      'font-size:16px;line-height:40px;border:0;padding:0;margin:0;'
      'background:transparent;color:transparent;caret-color:transparent;'
      'opacity:0.02;z-index:99999;outline:none;pointer-events:none;';
}

/// iOS Safari only raises the soft keyboard for a focus() made inside
/// touchend/click (not pointerdown/touchstart). Flutter's field does
/// not exist yet, so a proxy is focused in that gesture; once Flutter
/// has created its own, [handoffSoftKeyboard] moves focus to it.
///
/// The proxy is a real, in-viewport 16px field (not a 1x1 opacity-0
/// node: iOS ignores those). It stays until the handoff. We block
/// engine view-focus steals so the proxy is not blurred (a blur then
/// refocus can dismiss the keyboard).
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
  input.addEventListener('blur', ((web.Event ev) => _onPrimerBlur(ev)).toJS);
  input.focus(web.FocusOptions(preventScroll: true));
  _kbLog('prime via=$src');
  Timer(const Duration(seconds: 20), () {
    if (identical(_keyboardPrimer, input)) _dropPrimer();
  });
}

void _onPrimerBlur([web.Event? e]) {
  final input = _keyboardPrimer;
  if (input == null || _handoffDone) return;
  final active = web.document.activeElement;
  String rel = 'null';
  if (e != null && e.isA<web.FocusEvent>()) {
    final rt = (e as web.FocusEvent).relatedTarget;
    if (rt != null) {
      try {
        rel = (rt as web.Node).nodeName;
      } catch (_) {
        rel = '?';
      }
    }
  }
  if (active != null && _isFlutterField(active)) {
    _kbLog('blur-to-field rel=$rel', active);
    if (softKeyboardVariant != 'b') {
      scheduleMicrotask(_dropPrimer);
    }
    return;
  }
  // _tryHandoff sets data-kb-block=handoff, then focuses the field.
  // During that transition WebKit reports activeElement as <body>.
  final block = web.document.documentElement?.getAttribute('data-kb-block');
  if (block == 'handoff') {
    _kbLog('blur-to-handoff rel=$rel', active);
    return;
  }
  // A blur here, before handoff, is the failure mode on iOS.
  _kbLog('primer-blur rel=$rel', active);
  // Variant b is the old pointerdown path, which re-asserted focus.
  // For a, we must not refocus: that can dismiss the keyboard.
  if (softKeyboardVariant != 'b') return;
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
/// when nothing was primed (desktop, edit views, variant c or d).
///
/// The focus itself is delayed by one animation frame so Safari can
/// finish the synthetic mouse/click events that follow touchend.
/// The proxy was already focused synchronously in that touchend.
void handoffSoftKeyboard() {
  if (_keyboardPrimer == null) return;
  if (softKeyboardVariant == 'c') return;
  if (_handoffDone) return;
  if (_handoffRafPending) return;
  _handoffRafPending = true;
  _kbLog('handoff-raf');
  web.window.requestAnimationFrame(
    ((num _) {
      _handoffRafPending = false;
      if (_tryHandoff()) return;
      _handoffTimer?.cancel();
      _handoffTries = 0;
      _handoffTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
        _handoffTries++;
        if (_tryHandoff() || _handoffTries > 60) t.cancel();
      });
    }).toJS,
  );
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
  he.setAttribute('data-kb-handoff', '1');
  he.style.fontSize = '16px';
  if (he.offsetWidth < 16) he.style.minWidth = '16px';
  if (he.offsetHeight < 16) he.style.minHeight = '16px';
  if (st.opacity == '0') he.style.opacity = '0.02';
  return he.offsetWidth >= 16 && he.offsetHeight >= 16;
}

bool _tryHandoff() {
  if (_handoffDone || _keyboardPrimer == null) return true;
  final active = web.document.activeElement;
  if (active != null && _isFlutterField(active)) {
    _kbLog('handoff-already', active);
    scheduleMicrotask(_dropPrimer);
    return true;
  }
  final next = _findFlutterField();
  if (next == null) {
    _kbLog('handoff-wait');
    return false;
  }
  if (!_prepareHandoffTarget(next)) {
    _kbLog('handoff-not-ready', next);
    return false;
  }
  // Keep data-kb-block=1 so a flutter-view steal cannot hop through
  // <body> while we move focus directly onto the field (already allowed
  // by the focus patch).
  (next as web.HTMLElement).focus(web.FocusOptions(preventScroll: true));
  final now = web.document.activeElement;
  if (now != null && _isFlutterField(now)) {
    _kbLog('handoff', now);
    scheduleMicrotask(_dropPrimer);
    return true;
  }
  _kbLog('handoff-miss', now);
  return false;
}

void _dropPrimer() {
  _handoffTimer?.cancel();
  _handoffTimer = null;
  _handoffDone = true;
  _disarmViewFocusBlock();
  final input = _keyboardPrimer;
  _keyboardPrimer = null;
  if (input != null && input.getAttribute('data-kb-hot') != null) {
    input.removeAttribute('data-kb-primer');
  } else {
    input?.remove();
  }
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
