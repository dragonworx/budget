import 'package:decimal/decimal.dart';

import 'api_client.dart';
import '../features/planning/goal_models.dart';
import '../features/timeline/saved_view.dart';
import 'models.dart';

/// `GET /api/pools`: accessible pools (mine first, then shared).
class PoolList {
  const PoolList(this.pools, {this.lastPoolId});
  final List<Pool> pools;
  final String? lastPoolId;
}

class PoolRepository {
  PoolRepository(this._api);

  final ApiClient _api;

  /// My pools and those shared with me, plus the one I opened last
  /// (null when none or no longer accessible).
  Future<PoolList> list() async {
    final data = await _api.get('/api/pools');
    final last = data is Map<String, dynamic> ? data['lastPoolId'] : null;
    return PoolList(
      _asList(data).map(Pool.fromJson).toList(),
      lastPoolId: last?.toString(),
    );
  }

  Future<Pool> get(String id) async {
    final data = await _api.get('/api/pools/$id');
    return Pool.fromJson(data as Map<String, dynamic>);
  }

  /// Remember [id] as my last-opened pool (the next sign-in lands there).
  Future<void> markOpened(String id) async {
    await _api.post('/api/pools/$id/opened');
  }

  /// My saved timeline view of pool [id] (null: none saved yet).
  Future<SavedView?> loadView(String id) async {
    final data = await _api.get('/api/pools/$id/view');
    return data is Map ? SavedView.fromJson(data['view']) : null;
  }

  /// Saves my timeline view of pool [id]. [keepalive]: the page may be
  /// going away (hide / unload), so the request must outlive it.
  Future<void> saveView(
    String id,
    SavedView view, {
    bool keepalive = false,
  }) async {
    if (keepalive) {
      _api.putKeepalive('/api/pools/$id/view', view.toJson());
      return;
    }
    await _api.put('/api/pools/$id/view', body: view.toJson());
  }

  Future<Pool> create(Pool draft) async {
    final data = await _api.post('/api/pools', body: draft.toCreateJson());
    return Pool.fromJson(data as Map<String, dynamic>);
  }

  /// With [force], the version is left out (last write wins).
  Future<Pool> update(Pool pool, {bool force = false}) async {
    final body = pool.toPatchJson();
    if (force) body.remove('version');
    final data = await _api.patch('/api/pools/${pool.id}', body: body);
    return Pool.fromJson(data as Map<String, dynamic>);
  }

  /// Deletes the pool and its transactions; [transfers] says what happens
  /// to the far side of its transfers in other pools.
  Future<void> delete(
    String id, {
    PoolDeleteTransfers transfers = PoolDeleteTransfers.keep,
  }) => _api.delete('/api/pools/$id?transfers=${transfers.name}');

  Future<BalanceSeries> balance(
    String poolId, {
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _api.get(
      '/api/pools/$poolId/balance',
      query: {'from': formatDate(from), 'to': formatDate(to)},
    );
    return BalanceSeries.fromJson(data);
  }

  Future<Pool> reorderTransactions(
    String poolId,
    List<String> transactionIds,
  ) async {
    final data = await _api.patch(
      '/api/pools/$poolId/reorder-transactions',
      body: {'transactionIds': transactionIds},
    );
    return Pool.fromJson(data as Map<String, dynamic>);
  }

  Future<BalanceInsights> insights(
    String poolId,
    DateTime from, {
    int days = 365,
    int horizonDays = 1825,
  }) async {
    final data = await _api.get(
      '/api/pools/$poolId/insights',
      query: {
        'from': formatDate(from),
        'days': '$days',
        'horizonDays': '$horizonDays',
      },
    );
    return BalanceInsights.fromJson(data as Map<String, dynamic>);
  }

  /// Solves one balance-goal unknown (`POST /pools/:id/goal`).
  Future<List<Scenario>> scenarios(String poolId) async {
    final data = await _api.get('/api/pools/$poolId/scenarios');
    return [
      for (final j in data as List)
        Scenario.fromJson(Map<String, dynamic>.from(j as Map)),
    ];
  }

  Future<Scenario> createScenario(
    String poolId, {
    required String name,
    required GoalRequest request,
  }) async {
    final data = await _api.post(
      '/api/pools/$poolId/scenarios',
      body: {'name': name, 'request': request.toJson()},
    );
    return Scenario.fromJson(data as Map<String, dynamic>);
  }

  Future<Scenario> updateScenario(
    String poolId,
    String id, {
    String? name,
    bool? included,
    GoalRequest? request,
  }) async {
    final data = await _api.patch(
      '/api/pools/$poolId/scenarios/$id',
      body: {
        'name': ?name,
        'included': ?included,
        if (request != null) 'request': request.toJson(),
      },
    );
    return Scenario.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteScenario(String poolId, String id) =>
      _api.delete('/api/pools/$poolId/scenarios/$id');

  Future<GoalResult> goal(String poolId, GoalRequest request) async {
    final data = await _api.post(
      '/api/pools/$poolId/goal',
      body: {...request.toJson(), 'today': formatDate(DateTime.now())},
    );
    return GoalResult.fromJson(data as Map<String, dynamic>);
  }

  /// Balance as if [extra] (unsaved) transactions were added.
  Future<BalanceSeries> project(
    String poolId,
    List<Transaction> extra, {
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _api.post(
      '/api/pools/$poolId/project',
      body: {
        'from': formatDate(from),
        'to': formatDate(to),
        'transactions': [for (final t in extra) t.toCreateJson()],
      },
    );
    return BalanceSeries.fromJson(data);
  }

  Future<SolveResult> solve(String poolId, SolveRequest request) async {
    final data = await _api.post(
      '/api/pools/$poolId/solve',
      body: request.toJson(),
    );
    return SolveResult.fromJson(data as Map<String, dynamic>);
  }
}

class TransactionRepository {
  TransactionRepository(this._api);

  final ApiClient _api;

  Future<List<Transaction>> listForPool(String poolId) async {
    final data = await _api.get('/api/pools/$poolId/transactions');
    return _asList(data).map(Transaction.fromJson).toList();
  }

  Future<Transaction> create(String poolId, Transaction draft) async {
    final data = await _api.post(
      '/api/pools/$poolId/transactions',
      body: draft.toCreateJson(),
    );
    return Transaction.fromJson(data as Map<String, dynamic>);
  }

  /// Sends the row version unless [force] (then last write wins).
  Future<Transaction> update(
    Transaction transaction, {
    bool force = false,
  }) async {
    final data = await _api.patch(
      '/api/transactions/${transaction.id}',
      body: {
        ...transaction.toCreateJson(),
        // A patch keeps omitted fields: send the schedule's unset ones as
        // null so switching end mode (count ↔ date ↔ never) or to once
        // clears the other field instead of failing validation.
        'interval': transaction.interval,
        'unit': transaction.unit?.toJson(),
        'endDate': transaction.endDate == null
            ? null
            : formatDate(transaction.endDate!),
        'occurrenceCount': transaction.occurrenceCount,
        if (!force && transaction.version != null)
          'version': transaction.version,
      },
    );
    return Transaction.fromJson(data as Map<String, dynamic>);
  }

  Future<void> delete(String id) => _api.delete('/api/transactions/$id');

  /// Bulk import of a pasted `TransactionImport[]` (raw text; fences are
  /// stripped server-side). Its day offsets count from [root], the day
  /// selected on the timeline; the server validates and resolves them.
  /// With [dryRun] only validates and previews.
  /// Throws [ApiException] (status 400, `details` per-item issues) if invalid.
  Future<Map<String, dynamic>> import(
    String poolId,
    String raw, {
    required DateTime root,
    bool dryRun = false,
  }) async {
    final q = [if (dryRun) 'dryRun=true', 'root=${importRootParam(root)}'];
    final data = await _api.post(
      '/api/pools/$poolId/transactions/import?${q.join('&')}',
      body: raw,
    );
    return data as Map<String, dynamic>;
  }

  /// Undo of an import: deletes exactly [ids] (its `createdIds`) in one DB
  /// transaction. Returns `{deleted, deletedIds, missing}`; ids already
  /// gone are listed in `missing`, not an error.
  Future<Map<String, dynamic>> undoImport(
    String poolId,
    List<String> ids,
  ) async {
    final data = await _api.post(
      '/api/pools/$poolId/transactions/import/undo',
      body: {'ids': ids},
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
        data['pools'] ??
        data['transactions'] ??
        data['points'] ??
        data['balances'];
    if (nested is List) {
      return nested.cast<Map<String, dynamic>>();
    }
  }
  throw ApiException('Unexpected list response shape');
}

/// [day]'s calendar date as `YYYY-MM-DD`, read from its fields (never via
/// UTC conversion), so a local midnight on a DST change day keeps its date.
String importRootParam(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// Deleting a pool: the far side of each of its transfers (in another pool)
/// is kept there as a plain debit / credit, or deleted.
enum PoolDeleteTransfers { keep, delete }
