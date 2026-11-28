// An in-memory CategoryRepository for widget tests: one category per
// distinct event name (as migration 024 makes them), plus any created.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/stack_lanes.dart';

String fakeCategoryId(String name) =>
    'cat-${normalizeCategoryName(name).toLowerCase()}';

class FakeCategoryRepository extends CategoryRepository {
  FakeCategoryRepository([this.events, this.always = const []])
    : super(ApiClient());

  /// Names of categories every stream has (after the derived ones).
  final List<String> always;

  /// Where the derived categories come from (null: only [extra]).
  final EventRepository? events;

  /// Created (or seeded) categories, per stream.
  final extra = <String, List<Category>>{};

  /// Edits by id (name / colour / hidden).
  final edits = <String, Category>{};
  final deletedIds = <String>{};
  final calls = <String>[];

  @override
  Future<List<Category>> list(String streamId) async {
    final out = <Category>[];
    final seen = <String>{};
    void add(Category c) {
      if (deletedIds.contains(c.id) || !seen.add(c.id)) return;
      out.add(edits[c.id] ?? c);
    }

    final evs = events == null
        ? const <BudgetEvent>[]
        : await events!.listForStream(streamId);
    for (final e in evs) {
      final id = e.categoryId ?? fakeCategoryId(e.name);
      add(
        Category(
          id: id,
          streamId: streamId,
          name: normalizeCategoryName(e.name),
          color: e.color ?? colorToHex(laneColors[out.length % 12]),
          eventCount: evs
              .where((x) => (x.categoryId ?? fakeCategoryId(x.name)) == id)
              .length,
        ),
      );
    }
    for (final n in always) {
      add(
        Category(
          id: fakeCategoryId(n),
          streamId: streamId,
          name: n,
          color: colorToHex(laneColors[out.length % 12]),
        ),
      );
    }
    for (final c in extra[streamId] ?? const <Category>[]) {
      final i = out.indexWhere((x) => x.id == c.id);
      if (i >= 0) {
        final cur = out[i];
        out[i] = (edits[c.id] ?? c).copyWith(
          eventCount: cur.eventCount,
          eventCountSubtree: c.eventCountSubtree > cur.eventCount
              ? c.eventCountSubtree
              : cur.eventCount,
          parentId: c.parentId,
          clearParent: c.parentId == null,
          depth: c.depth,
        );
        continue;
      }
      add(c);
    }
    return out;
  }

  @override
  Future<Category> create(
    String streamId, {
    required String name,
    String? color,
    String? parentId,
    bool moveParentEvents = false,
  }) async {
    calls.add('create $name');
    final existing = await list(streamId);
    if (categoryNameProblem(name, existing) != null) {
      throw ApiException('Name taken', statusCode: 409);
    }
    final c = Category(
      id: fakeCategoryId(name),
      streamId: streamId,
      name: normalizeCategoryName(name),
      color: color ?? '#3D6FD8',
      parentId: parentId,
      depth: parentId == null ? 0 : 1,
    );
    (extra[streamId] ??= []).add(c);
    return c;
  }

  @override
  Future<Category> update(
    String streamId,
    String id, {
    String? name,
    String? color,
    bool? hidden,
    String? parentId,
    bool clearParent = false,
    int? sortOrder,
  }) async {
    calls.add('update $id ${name ?? ''} ${color ?? ''} ${hidden ?? ''}');
    final c = (await list(streamId)).firstWhere((c) => c.id == id);
    return edits[id] = c.copyWith(
      name: name,
      color: color,
      hidden: hidden,
      parentId: parentId,
      clearParent: clearParent,
      sortOrder: sortOrder,
    );
  }

  @override
  Future<List<Category>> reorder(
    String streamId, {
    String? parentId,
    required List<String> ids,
  }) async {
    calls.add('reorder ${parentId ?? 'top'} ${ids.join(',')}');
    var i = 0;
    for (final id in ids) {
      final c = (await list(streamId)).firstWhere((c) => c.id == id);
      edits[id] = c.copyWith(
        parentId: parentId,
        clearParent: parentId == null,
        sortOrder: i++,
        depth: parentId == null ? 0 : 1,
      );
    }
    return list(streamId);
  }

  Set<String> subtreeIds(List<Category> all, String id) {
    final ids = <String>{id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final c in all) {
        final p = c.parentId;
        if (p != null && ids.contains(p) && ids.add(c.id)) grew = true;
      }
    }
    return ids;
  }

  @override
  Future<({int events, int counterparts, int children})> deletePreview(
    String streamId,
    String id,
  ) async {
    final all = await list(streamId);
    final ids = subtreeIds(all, id);
    final events = all
        .where((c) => ids.contains(c.id))
        .fold<int>(0, (a, c) => a + c.eventCount);
    return (events: events, counterparts: 0, children: ids.length - 1);
  }

  final favorites = <String, List<String>>{};

  @override
  Future<List<String>> listFavorites(String streamId) async =>
      List.of(favorites[streamId] ?? const []);

  @override
  Future<List<String>> addFavorite(String streamId, String id) async {
    final list = favorites[streamId] ??= [];
    if (!list.contains(id)) list.add(id);
    return List.of(list);
  }

  @override
  Future<List<String>> removeFavorite(String streamId, String id) async {
    (favorites[streamId] ??= []).remove(id);
    return List.of(favorites[streamId] ?? const []);
  }

  @override
  Future<void> delete(String streamId, String id) async {
    calls.add('delete $id');
    final ids = subtreeIds(await list(streamId), id);
    deletedIds.addAll(ids);
  }

  @override
  Future<({String? batchId, List<String> deleted})> deleteEvents(
    String streamId,
    String id,
  ) async {
    calls.add('deleteEvents $id');
    return (batchId: 'batch-$id', deleted: <String>[]);
  }
}
