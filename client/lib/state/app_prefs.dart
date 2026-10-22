import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart'
    as page;

/// Small typed app preferences for this device (browser local storage),
/// not synced to the server. Keys live under a versioned prefix so a later
/// format change can move to `v2` without reading stale values.
///
/// Per-pool view state keeps its own storage (SavedViewStore etc.).
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

/// Keys (one place, so they don't collide).
abstract final class PrefKeys {
  /// Docked Transactions list width, logical px.
  static const dockedListWidth = 'timeline.dockedListWidth';
}
