import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:decimal/decimal.dart';

/// An account for tests (owned by me unless [shared]).
Account testAccount(
  String id,
  String name, {
  bool shared = false,
  Role role = Role.owner,
  String ownerName = 'Me',
}) => Account(
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

/// In-memory `/api/accounts` (list, last-used, create, get).
class FakeAccountRepository extends AccountRepository {
  FakeAccountRepository({List<Account>? accounts, this.lastAccountId})
    : accounts = accounts ?? [],
      super(ApiClient());

  final List<Account> accounts;
  String? lastAccountId;
  int lists = 0;
  final created = <Account>[];

  @override
  Future<AccountList> list() async {
    lists++;
    return AccountList(
      List.of(accounts),
      lastAccountId: accounts.any((a) => a.id == lastAccountId)
          ? lastAccountId
          : null,
    );
  }

  @override
  Future<Account> create(Account draft) async {
    final a = draft.copyWith(id: 'new-${created.length + 1}', ownerId: 'u1');
    created.add(a);
    accounts.add(a);
    return a;
  }

  final opened = <String>[];

  @override
  Future<void> markOpened(String id) async {
    opened.add(id);
    lastAccountId = id;
  }

  @override
  Future<Account> get(String id) async {
    final a = accounts.where((a) => a.id == id).firstOrNull;
    if (a == null) throw ApiException('account not found', statusCode: 404);
    lastAccountId = id;
    return a;
  }
}
