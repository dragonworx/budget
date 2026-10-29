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
      add(c);
    }
    return out;
  }

  @override
  Future<Category> create(
    String streamId, {
    required String name,
    String? color,
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
  }) async {
    calls.add('update $id ${name ?? ''} ${color ?? ''} ${hidden ?? ''}');
    final c = (await list(streamId)).firstWhere((c) => c.id == id);
    return edits[id] = c.copyWith(name: name, color: color, hidden: hidden);
  }

  @override
  Future<({int events, int counterparts})> deletePreview(
    String streamId,
    String id,
  ) async {
    final c = (await list(streamId)).firstWhere((c) => c.id == id);
    return (events: c.eventCount, counterparts: 0);
  }

  @override
  Future<void> delete(String streamId, String id) async {
    calls.add('delete $id');
    deletedIds.add(id);
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
