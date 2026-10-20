import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'page_stub.dart' if (dart.library.js_interop) 'page_web.dart' as page;

/// Reloads the page (web); no-op elsewhere.
void reloadPage() => page.reloadPage();

/// The build this client was compiled as (`--dart-define=BUILD_ID=…`, set by
/// the production image). Empty in dev and tests: the check is off.
const String buildId = String.fromEnvironment('BUILD_ID');

/// Stale-client guard. A tab left open across a deploy keeps running the old
/// app, which then calls API routes that no longer exist. The image writes
/// `/build.json` (`{"build": "<id>"}`) next to the app; when it no longer
/// matches [current] the page reloads into the new version:
///
/// - at once when the tab comes back into view, or when the API answers in
///   a way only an outdated client sees ([suspect]: 404/410 "client
///   outdated", HTML instead of JSON);
/// - otherwise (periodic check while in use) [onUpdateAvailable] offers a
///   Reload, and the next return to the tab reloads.
///
/// Auto-reloads are spaced at least a minute apart (no loop if a cache
/// briefly serves the old file).
class AppVersion {
  AppVersion({
    required this.current,
    http.Client? client,
    Uri? url,
    void Function()? reload,
    this.now = DateTime.now,
  }) : _client = client ?? http.Client(),
       _url = url ?? Uri.parse('/build.json'),
       _reload = reload ?? page.reloadPage;

  final String current;
  final http.Client _client;
  final Uri _url;
  final void Function() _reload;
  final DateTime Function() now;

  /// Shown when an update is found while the user is working.
  void Function()? onUpdateAvailable;

  bool stale = false;
  bool _checking = false;
  Timer? _timer;

  static const _reloadKey = 'budget_reload_at';

  bool get enabled => current.isNotEmpty;

  /// Fetches `/build.json` (never cached). True when a newer build is live.
  Future<bool> check() async {
    if (!enabled) return false;
    if (stale) return true;
    if (_checking) return false;
    _checking = true;
    try {
      final r = await _client
          .get(
            _url.replace(
              queryParameters: {'t': '${now().millisecondsSinceEpoch}'},
            ),
            headers: const {'Cache-Control': 'no-cache'},
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return false;
      final live = (jsonDecode(r.body) as Map)['build']?.toString() ?? '';
      stale = live.isNotEmpty && live != current;
      return stale;
    } catch (_) {
      return false; // offline / server restarting: try again later
    } finally {
      _checking = false;
    }
  }

  /// Reloads if a newer build is live (spaced a minute apart). True when it
  /// reloaded.
  Future<bool> reloadIfStale() async {
    if (!await check()) return false;
    final last = int.tryParse(page.sessionGet(_reloadKey) ?? '') ?? 0;
    final t = now().millisecondsSinceEpoch;
    if (t - last < 60000) {
      onUpdateAvailable?.call();
      return false;
    }
    page.sessionSet(_reloadKey, '$t');
    _reload();
    return true;
  }

  /// The API answered as if this client were outdated.
  void suspect() => unawaited(reloadIfStale());

  /// Periodic check + check on return to the tab.
  void start({Duration every = const Duration(minutes: 5)}) {
    if (!enabled) return;
    page.onPageVisible(() => unawaited(reloadIfStale()));
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) async {
      if (await check()) {
        if (!page.pageVisible) {
          await reloadIfStale();
        } else {
          onUpdateAvailable?.call();
        }
      }
    });
  }

  void stop() => _timer?.cancel();
}
