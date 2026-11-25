import 'models.dart';

/// True when [name] is the reserved Sync category (never nested).
bool isSyncCategoryName(String name) =>
    normalizeCategoryName(name).toLowerCase() == 'sync';

/// Sibling order: [Category.sortOrder], then natural name, then id.
int compareCategorySiblings(Category a, Category b) {
  final o = a.sortOrder.compareTo(b.sortOrder);
  if (o != 0) return o;
  final n = compareCategoryNames(a.name, b.name);
  if (n != 0) return n;
  return a.id.compareTo(b.id);
}

List<Category> siblingSorted(Iterable<Category> list) =>
    [...list]..sort(compareCategorySiblings);

/// Top-level categories of [all], in sibling order.
List<Category> rootCategories(Iterable<Category> all) =>
    siblingSorted(all.where((c) => c.parentId == null));

/// Direct children of [parentId] in sibling order.
List<Category> childCategories(Iterable<Category> all, String parentId) =>
    siblingSorted(all.where((c) => c.parentId == parentId));

Category? categoryById(Iterable<Category> all, String? id) {
  if (id == null) return null;
  for (final c in all) {
    if (c.id == id) return c;
  }
  return null;
}

/// Ancestors from the root down to [id], including [id].
List<Category> categoryPath(Iterable<Category> all, String id) {
  final byId = {for (final c in all) c.id: c};
  final c = byId[id];
  if (c == null) return const [];
  final chain = <Category>[c];
  var p = c.parentId;
  final seen = <String>{c.id};
  while (p != null && seen.add(p)) {
    final parent = byId[p];
    if (parent == null) break;
    chain.insert(0, parent);
    p = parent.parentId;
  }
  return chain;
}

/// "Utilities › Power".
String categoryPathLabel(
  Iterable<Category> all,
  String id, {
  String sep = ' › ',
}) => categoryPath(all, id).map((c) => c.name).join(sep);

/// Hidden itself, or a hidden ancestor (a hidden parent hides the branch
/// in transaction pickers).
bool hiddenInPicker(Iterable<Category> all, Category c) {
  if (c.hidden) return true;
  for (final step in categoryPath(all, c.id)) {
    if (step.hidden) return true;
  }
  return false;
}

/// Categories that may be chosen for a new event (hidden branches out).
List<Category> visibleForPicker(Iterable<Category> all) => [
  for (final c in all)
    if (!hiddenInPicker(all, c)) c,
];

/// Tree walk: each root, then its children (for the manager list).
List<Category> flattenedTree(Iterable<Category> all) {
  final out = <Category>[];
  void walk(Category c) {
    out.add(c);
    for (final ch in childCategories(all, c.id)) {
      walk(ch);
    }
  }

  for (final r in rootCategories(all)) {
    walk(r);
  }
  return out;
}

/// Whether [child] can be nested under [parent] (max depth 2, no Sync,
/// a parent with children stays top-level, no self).
bool canNestUnder(Iterable<Category> all, Category child, Category parent) {
  if (child.id == parent.id) return false;
  if (parent.parentId != null) return false;
  if (isSyncCategoryName(parent.name) || isSyncCategoryName(child.name)) {
    return false;
  }
  if (childCategories(all, child.id).isNotEmpty) return false;
  return true;
}

/// A category is visible as a "Move to…" parent target.
bool canMoveToParent(Iterable<Category> all, Category child, Category? parent) {
  if (parent == null) {
    return child.parentId != null && !isSyncCategoryName(child.name);
  }
  return canNestUnder(all, child, parent);
}
