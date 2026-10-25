import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/saved_view.dart';
import 'package:decimal/decimal.dart';

/// A stream for tests (owned by me unless [shared]).
BudgetStream testStream(
  String id,
  String name, {
  bool shared = false,
  Role role = Role.owner,
  String ownerName = 'Me',
}) => BudgetStream(
  id: id,
  ownerId: shared ? 'other' : 'u1',
  name: name,
  seedBalance: Decimal.zero,
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
  role: shared ? role : Role.owner,
  shared: shared,
  owner: UserRef(
    id: shared ? 'other' : 'u1',
    email: '${ownerName.toLowerCase()}@example.com',
    name: ownerName,
  ),
);

/// In-memory `/api/streams` (list, last-used, create, get).
class FakeStreamRepository extends StreamRepository {
  FakeStreamRepository({List<BudgetStream>? streams, this.lastStreamId})
    : streams = streams ?? [],
      super(ApiClient());

  final List<BudgetStream> streams;
  String? lastStreamId;
  int lists = 0;
  final created = <BudgetStream>[];

  @override
  Future<StreamList> list() async {
    lists++;
    return StreamList(
      List.of(streams),
      lastStreamId: streams.any((a) => a.id == lastStreamId)
          ? lastStreamId
          : null,
    );
  }

  @override
  Future<BudgetStream> create(BudgetStream draft) async {
    final a = draft.copyWith(id: 'new-${created.length + 1}', ownerId: 'u1');
    created.add(a);
    streams.add(a);
    return a;
  }

  final opened = <String>[];

  /// Server-side saved views by stream id, and every save made.
  final views = <String, SavedView>{};
  final viewSaves = <(String, SavedView, bool)>[];

  @override
  Future<SavedView?> loadView(String id) async => views[id];

  @override
  Future<void> saveView(
    String id,
    SavedView view, {
    bool keepalive = false,
  }) async {
    viewSaves.add((id, view, keepalive));
    views[id] = view;
  }

  @override
  Future<void> markOpened(String id) async {
    opened.add(id);
    lastStreamId = id;
  }

  @override
  Future<BudgetStream> get(String id) async {
    final a = streams.where((a) => a.id == id).firstOrNull;
    if (a == null) throw ApiException('stream not found', statusCode: 404);
    lastStreamId = id;
    return a;
  }
}
