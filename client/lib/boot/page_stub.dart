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

/// Tests: forget everything saved with [localSet].
void clearLocal() => _local.clear();

/// Tests: set to simulate the OS "reduce motion" setting.
bool prefersReducedMotionForTest = false;
bool get prefersReducedMotion => prefersReducedMotionForTest;

/// Tests: how many times a new-transaction tap primed the soft keyboard.
int primeSoftKeyboardCalls = 0;

/// Web: focuses a hidden input inside the tap so phones raise the keyboard.
void primeSoftKeyboard() => primeSoftKeyboardCalls++;

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
