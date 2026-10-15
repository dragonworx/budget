import 'api_client.dart';
import 'models.dart';

class ProjectRepository {
  ProjectRepository(this._api);

  final ApiClient _api;

  Future<List<Project>> list() async {
    final data = await _api.get('/api/projects');
    return _asList(data).map(Project.fromJson).toList();
  }

  Future<Project> get(String id) async {
    final data = await _api.get('/api/projects/$id');
    return Project.fromJson(data as Map<String, dynamic>);
  }

  Future<Project> create(String name) async {
    final data = await _api.post('/api/projects', body: {'name': name});
    return Project.fromJson(data as Map<String, dynamic>);
  }

  Future<Project> rename(String id, String name) async {
    final data = await _api.patch('/api/projects/$id', body: {'name': name});
    return Project.fromJson(data as Map<String, dynamic>);
  }

  Future<void> delete(String id) => _api.delete('/api/projects/$id');
}

class AccountRepository {
  AccountRepository(this._api);

  final ApiClient _api;

  Future<List<Account>> listForProject(String projectId) async {
    final data = await _api.get('/api/projects/$projectId/accounts');
    return _asList(data).map(Account.fromJson).toList();
  }

  Future<Account> get(String id) async {
    final data = await _api.get('/api/accounts/$id');
    return Account.fromJson(data as Map<String, dynamic>);
  }

  Future<Account> create(String projectId, Account draft) async {
    final data = await _api.post(
      '/api/projects/$projectId/accounts',
      body: draft.toCreateJson(),
    );
    return Account.fromJson(data as Map<String, dynamic>);
  }

  Future<Account> update(Account account) async {
    final data = await _api.patch(
      '/api/accounts/${account.id}',
      body: account.toPatchJson(),
    );
    return Account.fromJson(data as Map<String, dynamic>);
  }

  Future<void> delete(String id) => _api.delete('/api/accounts/$id');

  Future<BalanceSeries> balance(
    String accountId, {
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _api.get(
      '/api/accounts/$accountId/balance',
      query: {
        'from': formatDate(from),
        'to': formatDate(to),
      },
    );
    return BalanceSeries.fromJson(data);
  }

  Future<Account> reorderTransactions(
    String accountId,
    List<String> transactionIds,
  ) async {
    final data = await _api.patch(
      '/api/accounts/$accountId/reorder-transactions',
      body: {'transactionIds': transactionIds},
    );
    return Account.fromJson(data as Map<String, dynamic>);
  }

  Future<SolveResult> solve(String accountId, SolveRequest request) async {
    final data = await _api.post(
      '/api/accounts/$accountId/solve',
      body: request.toJson(),
    );
    return SolveResult.fromJson(data as Map<String, dynamic>);
  }
}

class TransactionRepository {
  TransactionRepository(this._api);

  final ApiClient _api;

  Future<List<Transaction>> listForAccount(String accountId) async {
    final data = await _api.get('/api/accounts/$accountId/transactions');
    return _asList(data).map(Transaction.fromJson).toList();
  }

  Future<Transaction> create(String accountId, Transaction draft) async {
    final data = await _api.post(
      '/api/accounts/$accountId/transactions',
      body: draft.toCreateJson(),
    );
    return Transaction.fromJson(data as Map<String, dynamic>);
  }

  Future<Transaction> update(Transaction transaction) async {
    final data = await _api.patch(
      '/api/transactions/${transaction.id}',
      body: transaction.toCreateJson(),
    );
    return Transaction.fromJson(data as Map<String, dynamic>);
  }

  Future<void> delete(String id) => _api.delete('/api/transactions/$id');

  /// Bulk import of a pasted `TransactionImport[]` (raw text; fences are
  /// stripped server-side). With [dryRun] only validates and previews.
  /// Throws [ApiException] (status 400, `details` per-item issues) if invalid.
  Future<Map<String, dynamic>> import(
    String accountId,
    String raw, {
    bool dryRun = false,
  }) async {
    final data = await _api.post(
      '/api/accounts/$accountId/transactions/import${dryRun ? '?dryRun=true' : ''}',
      body: raw,
    );
    return data as Map<String, dynamic>;
  }

  Future<void> skipOccurrence(
    String transactionId,
    DateTime date, {
    bool skipped = true,
  }) async {
    await _api.put(
      '/api/transactions/$transactionId/skips/${formatDate(date)}',
      body: {'skipped': skipped},
    );
  }
}

List<Map<String, dynamic>> _asList(dynamic data) {
  if (data == null) return const [];
  if (data is List) {
    return data.cast<Map<String, dynamic>>();
  }
  if (data is Map<String, dynamic>) {
    final nested = data['items'] ?? data['data'] ?? data['projects'] ??
        data['accounts'] ?? data['transactions'] ?? data['points'] ?? data['balances'];
    if (nested is List) {
      return nested.cast<Map<String, dynamic>>();
    }
  }
  throw ApiException('Unexpected list response shape');
}
