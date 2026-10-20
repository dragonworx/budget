import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:decimal/decimal.dart';

/// A pool for tests (owned by me unless [shared]).
Pool testPool(
  String id,
  String name, {
  bool shared = false,
  Role role = Role.owner,
  String ownerName = 'Me',
}) => Pool(
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

/// In-memory `/api/pools` (list, last-used, create, get).
class FakePoolRepository extends PoolRepository {
  FakePoolRepository({List<Pool>? pools, this.lastPoolId})
    : pools = pools ?? [],
      super(ApiClient());

  final List<Pool> pools;
  String? lastPoolId;
  int lists = 0;
  final created = <Pool>[];

  @override
  Future<PoolList> list() async {
    lists++;
    return PoolList(
      List.of(pools),
      lastPoolId: pools.any((a) => a.id == lastPoolId)
          ? lastPoolId
          : null,
    );
  }

  @override
  Future<Pool> create(Pool draft) async {
    final a = draft.copyWith(id: 'new-${created.length + 1}', ownerId: 'u1');
    created.add(a);
    pools.add(a);
    return a;
  }

  final opened = <String>[];

  @override
  Future<void> markOpened(String id) async {
    opened.add(id);
    lastPoolId = id;
  }

  @override
  Future<Pool> get(String id) async {
    final a = pools.where((a) => a.id == id).firstOrNull;
    if (a == null) throw ApiException('pool not found', statusCode: 404);
    lastPoolId = id;
    return a;
  }
}
