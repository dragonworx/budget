import '../state/app_prefs.dart';
import 'category_tree.dart';
import 'models.dart';

/// Device-local last category used in a stream (survives reloads).
String lastCategoryStorageKey(String streamId, {String? userId}) =>
    userId == null || userId.isEmpty
    ? 'lastCategory.$streamId'
    : 'lastCategory.$userId.$streamId';

String? readStoredLastCategory(String streamId, {String? userId}) =>
    appPrefs.getString(lastCategoryStorageKey(streamId, userId: userId));

void storeLastCategory(String streamId, String? id, {String? userId}) {
  final key = lastCategoryStorageKey(streamId, userId: userId);
  if (id == null || id.isEmpty) {
    appPrefs.remove(key);
  } else {
    appPrefs.setString(key, id);
  }
}

/// The category a new event should start on: [preferredId] (session or
/// stored) if it still exists, is visible, and is a leaf, else the
/// category of the most recently created event on the stream (events are
/// listed oldest-first) if that row is still a visible leaf, else the
/// first visible leaf in the owner's list order.
Category? defaultNewEventCategory({
  required Iterable<Category> categories,
  String? preferredId,
  Iterable<BudgetEvent> recentEvents = const [],
}) {
  final visible = visibleLeaves(categories);
  Category? by(String? id) =>
      id == null ? null : visible.where((c) => c.id == id).firstOrNull;
  final preferred = by(preferredId);
  if (preferred != null) return preferred;
  for (final e in recentEvents.toList().reversed) {
    final hit = by(e.categoryId);
    if (hit != null) return hit;
    final key = e.name.trim().toLowerCase();
    if (key.isEmpty) continue;
    final named = visible.where((c) => c.name.toLowerCase() == key).firstOrNull;
    if (named != null) return named;
  }
  return visible.isEmpty ? null : visible.first;
}
