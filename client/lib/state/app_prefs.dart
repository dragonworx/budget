import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart'
    as page;

/// Small typed app preferences for this device (browser local storage),
/// not synced to the server. Keys live under a versioned prefix so a later
/// format change can move to `v2` without reading stale values.
///
/// Per-stream view state keeps its own storage (SavedViewStore etc.).
class AppPrefs {
  const AppPrefs();

  static const prefix = 'budgie.prefs.v1.';

  String? getString(String key) => page.localGet('$prefix$key');
  void setString(String key, String value) =>
      page.localSet('$prefix$key', value);
  void remove(String key) => page.localRemove('$prefix$key');

  /// A finite number, else null (missing / unparsable).
  double? getDouble(String key) {
    final v = double.tryParse(getString(key) ?? '');
    return v != null && v.isFinite ? v : null;
  }

  void setDouble(String key, double value) => setString(key, '$value');

  bool? getBool(String key) => switch (getString(key)) {
    'true' => true,
    'false' => false,
    _ => null,
  };
  void setBool(String key, bool value) => setString(key, '$value');
}

const appPrefs = AppPrefs();

/// One-time move of this browser's stored keys from the Pools/Transactions
/// era to Streams/Events names (e.g. `budget_tx_docked` ->
/// `budget_events_docked`). Values are kept; an existing new key wins.
/// Safe to call on every start.
void migrateLegacyLocalKeys() {
  for (final key in page.localKeys()) {
    if (!key.startsWith('budget') && !key.startsWith('budgie.')) continue;
    final renamed = legacyLocalKey(key);
    if (renamed == null) continue;
    final value = page.localGet(key);
    if (value != null && page.localGet(renamed) == null) {
      page.localSet(renamed, value);
    }
    page.localRemove(key);
  }
}

/// The Streams/Events name for a pre-rename storage key, else null.
String? legacyLocalKey(String key) {
  if (key == 'budget_tx_docked') return 'budget_events_docked';
  final renamed = key
      .replaceAll('transaction', 'event')
      .replaceAll('Transaction', 'Event')
      .replaceAll('pool', 'stream')
      .replaceAll('Pool', 'Stream');
  return renamed == key ? null : renamed;
}

/// Keys (one place, so they don't collide).
abstract final class PrefKeys {
  /// Docked Events list width, logical px.
  static const dockedListWidth = 'timeline.dockedListWidth';

  /// Event ids hidden from the timeline (JSON list; see hidden_events.dart).
  static const hiddenEvents = 'timeline.hiddenEvents';
}
