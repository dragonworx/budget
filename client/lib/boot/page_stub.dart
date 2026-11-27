import 'package:flutter/services.dart';

/// Non-web (tests): no page to reload.
void reloadPage() {}

bool get pageVisible => true;

void onPageVisible(void Function() f) {}

final _hidden = <Object, void Function()>{};

/// Tests: listeners registered with [onPageHidden].
Object onPageHidden(void Function() f) {
  final handle = Object();
  _hidden[handle] = f;
  return handle;
}

void offPageHidden(Object handle) => _hidden.remove(handle);

/// Tests: simulate the page being hidden (tab / app switch, unload).
void firePageHidden() {
  for (final f in [..._hidden.values]) {
    f();
  }
}

/// Non-web: no keepalive fetch; callers fall back to a normal request.
bool keepaliveRequest(
  String method,
  String url,
  Map<String, String> headers,
  String body,
) => false;

final _session = <String, String>{};
String? sessionGet(String key) => _session[key];
void sessionSet(String key, String value) => _session[key] = value;

final _local = <String, String>{};
String? localGet(String key) => _local[key];
void localSet(String key, String value) => _local[key] = value;
void localRemove(String key) => _local.remove(key);
List<String> localKeys() => _local.keys.toList();

/// Tests: forget everything saved with [localSet].
void clearLocal() => _local.clear();

/// Tests: set to simulate the OS "reduce motion" setting.
bool prefersReducedMotionForTest = false;
bool get prefersReducedMotion => prefersReducedMotionForTest;

/// Tests: how many times a new-event tap primed the soft keyboard.
int primeSoftKeyboardCalls = 0;

/// Web: focuses a hidden input inside the tap so phones raise the keyboard.
void primeSoftKeyboard({bool decimal = false, String? via}) =>
    primeSoftKeyboardCalls++;

/// Web: moves that input's focus to Flutter's text-editing field.
void handoffSoftKeyboard() {}

/// Web: capture-phase listener so the proxy is focused in the tap itself.
void installSoftKeyboardPrimer() {}

/// Web: skip the New event / New stream open animation on iOS Safari.
bool get instantSoftKeyboardOpen => false;

/// Tests: currently registered keyboard-primer hotspots, by id.
final kbHotspots = <String, KbHotspotReg>{};

class KbHotspotReg {
  const KbHotspotReg({
    required this.id,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.kind,
  });
  final String id;
  final double left, top, width, height;
  final String kind;
}

/// Web: screen rect of a New event / New stream / FAB / day-add control.
void registerKbHotspot({
  required String id,
  required double left,
  required double top,
  required double width,
  required double height,
  required String kind,
}) {
  kbHotspots[id] = KbHotspotReg(
    id: id,
    left: left,
    top: top,
    width: width,
    height: height,
    kind: kind,
  );
}

/// Web: drop a previously registered hotspot.
void unregisterKbHotspot(String id) => kbHotspots.remove(id);

/// Tests: how many times the keyboard proxy was released.
int releaseSoftKeyboardCalls = 0;

/// Web: blur the keyboard proxy. No-op in tests.
void releaseSoftKeyboard() => releaseSoftKeyboardCalls++;

/// Tests: taps on Amount that would unstick a blocked primer handoff.
int softKeyboardFieldPointerCalls = 0;

/// Web: a pointer on Amount drops a stuck focus patch so the field can
/// take focus. No-op in tests besides the counter.
void onSoftKeyboardFieldPointer() => softKeyboardFieldPointerCalls++;

/// Web: receive text typed into the keyboard proxy so Amount/Name stay in sync.
void Function(String text)? softKeyboardTextHandler;
void setSoftKeyboardTextHandler(void Function(String text)? handler) {
  softKeyboardTextHandler = handler;
}

/// Tests: text still sitting in the keyboard proxy, applied by [flushSoftKeyboard].
String? pendingSoftKeyboardText;

/// Tests: how many times the proxy was flushed into the field.
int flushSoftKeyboardCalls = 0;

/// Web / iOS: copy the in-progress keyboard value into the field and blur.
void flushSoftKeyboard() {
  flushSoftKeyboardCalls++;
  final text = pendingSoftKeyboardText;
  pendingSoftKeyboardText = null;
  if (text != null) softKeyboardTextHandler?.call(text);
}

/// Non-web (tests): the platform clipboard (mock it with
/// `SystemChannels.platform`); a platform error is a [ClipboardReadException].
Future<String?> readClipboardText() async {
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  } on PlatformException catch (e) {
    throw ClipboardReadException(e.message ?? e.code);
  }
}

/// The clipboard could not be read (denied, unavailable or failed).
class ClipboardReadException implements Exception {
  const ClipboardReadException(this.message);
  final String message;
  @override
  String toString() => message;
}

bool get coarsePointer => false;
