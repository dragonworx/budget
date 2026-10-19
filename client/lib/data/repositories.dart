import 'package:decimal/decimal.dart';
import 'api_client.dart';
import '../features/planning/goal_models.dart';
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

  Future<Project> rename(String id, String name, {int? version}) async {
    final data = await _api.patch(
      '/api/projects/$id',
      body: {'name': name, 'version': ?version},
    );
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

  /// With [force], the version is left out (last write wins).
  Future<Account> update(Account account, {bool force = false}) async {
    final body = account.toPatchJson();
    if (force) body.remove('version');
    final data = await _api.patch('/api/accounts/${account.id}', body: body);
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
      query: {'from': formatDate(from), 'to': formatDate(to)},
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

  Future<BalanceInsights> insights(
    String accountId,
    DateTime from, {
    int days = 365,
    int horizonDays = 1825,
  }) async {
    final data = await _api.get(
      '/api/accounts/$accountId/insights',
      query: {
        'from': formatDate(from),
        'days': '$days',
        'horizonDays': '$horizonDays',
      },
    );
    return BalanceInsights.fromJson(data as Map<String, dynamic>);
  }

  /// Solves one balance-goal unknown (`POST /accounts/:id/goal`).
  Future<List<Scenario>> scenarios(String accountId) async {
    final data = await _api.get('/api/accounts/$accountId/scenarios');
    return [
      for (final j in data as List)
        Scenario.fromJson(Map<String, dynamic>.from(j as Map)),
    ];
  }

  Future<Scenario> createScenario(
    String accountId, {
    required String name,
    required GoalRequest request,
  }) async {
    final data = await _api.post(
      '/api/accounts/$accountId/scenarios',
      body: {'name': name, 'request': request.toJson()},
    );
    return Scenario.fromJson(data as Map<String, dynamic>);
  }

  Future<Scenario> updateScenario(
    String accountId,
    String id, {
    String? name,
    bool? included,
    GoalRequest? request,
  }) async {
    final data = await _api.patch(
      '/api/accounts/$accountId/scenarios/$id',
      body: {
        'name': ?name,
        'included': ?included,
        if (request != null) 'request': request.toJson(),
      },
    );
    return Scenario.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteScenario(String accountId, String id) =>
      _api.delete('/api/accounts/$accountId/scenarios/$id');

  Future<GoalResult> goal(String accountId, GoalRequest request) async {
    final data = await _api.post(
      '/api/accounts/$accountId/goal',
      body: {...request.toJson(), 'today': formatDate(DateTime.now())},
    );
    return GoalResult.fromJson(data as Map<String, dynamic>);
  }

  /// Balance as if [extra] (unsaved) transactions were added.
  Future<BalanceSeries> project(
    String accountId,
    List<Transaction> extra, {
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _api.post(
      '/api/accounts/$accountId/project',
      body: {
        'from': formatDate(from),
        'to': formatDate(to),
        'transactions': [for (final t in extra) t.toCreateJson()],
      },
    );
    return BalanceSeries.fromJson(data);
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

  /// Sends the row version unless [force] (then last write wins).
  Future<Transaction> update(Transaction transaction, {bool force = false}) async {
    final data = await _api.patch(
      '/api/transactions/${transaction.id}',
      body: {
        ...transaction.toCreateJson(),
        if (!force && transaction.version != null)
          'version': transaction.version,
      },
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

  /// Once-off: [date]'s occurrence takes [amount] / [direction] instead of
  /// the series value. Sends [version] (stale: 409) unless null.
  Future<Transaction> setOverride(
    String transactionId,
    DateTime date, {
    required TransactionDirection direction,
    required Decimal amount,
    int? version,
  }) async {
    final data = await _api.put(
      '/api/transactions/$transactionId/overrides/${formatDate(date)}',
      body: {
        'direction': direction.toJson(),
        'amount': moneyToJson(amount),
        'version': ?version,
      },
    );
    return Transaction.fromJson(data as Map<String, dynamic>);
  }

  /// Clears the override on [date] (null: every override of the series),
  /// restoring the natural series value.
  Future<void> clearOverrides(String transactionId, {DateTime? date}) =>
      _api.delete(
        '/api/transactions/$transactionId/overrides'
        '${date == null ? '' : '/${formatDate(date)}'}',
      );

  /// "From now on": ends the series the day before [date] and starts a new
  /// one there with [edited]'s name, amount, direction, frequency and
  /// enabled flag, keeping the original end condition. Atomic server-side.
  /// Returns the shortened original and the new series (null when [date]
  /// is the first occurrence: then the whole series was updated).
  Future<({Transaction original, Transaction? created})> split(
    Transaction edited,
    DateTime date, {
    bool force = false,
  }) async {
    final data = await _api.post(
      '/api/transactions/${edited.id}/split',
      body: {
        'date': formatDate(date),
        'name': edited.name,
        'direction': edited.direction.toJson(),
        'amount': moneyToJson(edited.amount),
        'interval': ?edited.interval,
        'unit': ?edited.unit?.toJson(),
        'enabled': edited.enabled,
        if (!force && edited.version != null) 'version': edited.version,
      },
    ) as Map<String, dynamic>;
    final created = data['created'];
    return (
      original: Transaction.fromJson(data['original'] as Map<String, dynamic>),
      created: created is Map<String, dynamic>
          ? Transaction.fromJson(created)
          : null,
    );
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
    final nested =
        data['items'] ??
        data['data'] ??
        data['projects'] ??
        data['accounts'] ??
        data['transactions'] ??
        data['points'] ??
        data['balances'];
    if (nested is List) {
      return nested.cast<Map<String, dynamic>>();
    }
  }
  throw ApiException('Unexpected list response shape');
}
