import 'package:decimal/decimal.dart';

import 'api_client.dart';
import '../features/planning/goal_models.dart';
import '../features/timeline/saved_view.dart';
import 'models.dart';
import '../features/loans/loan_models.dart';

/// `GET /api/streams`: accessible streams (mine first, then shared).
class StreamList {
  const StreamList(this.streams, {this.lastStreamId});
  final List<BudgetStream> streams;
  final String? lastStreamId;
}

class StreamRepository {
  StreamRepository(this._api);

  final ApiClient _api;

  /// My streams and those shared with me, plus the one I opened last
  /// (null when none or no longer accessible).
  Future<StreamList> list() async {
    final data = await _api.get('/api/streams');
    final last = data is Map<String, dynamic> ? data['lastStreamId'] : null;
    return StreamList(
      _asList(data).map(BudgetStream.fromJson).toList(),
      lastStreamId: last?.toString(),
    );
  }

  Future<BudgetStream> get(String id) async {
    final data = await _api.get('/api/streams/$id');
    return BudgetStream.fromJson(data as Map<String, dynamic>);
  }

  /// Remember [id] as my last-opened stream (the next sign-in lands there).
  Future<void> markOpened(String id) async {
    await _api.post('/api/streams/$id/opened');
  }

  /// My saved timeline view of stream [id] (null: none saved yet).
  Future<SavedView?> loadView(String id) async {
    final data = await _api.get('/api/streams/$id/view');
    return data is Map ? SavedView.fromJson(data['view']) : null;
  }

  /// Saves my timeline view of stream [id]. [keepalive]: the page may be
  /// going away (hide / unload), so the request must outlive it.
  Future<void> saveView(
    String id,
    SavedView view, {
    bool keepalive = false,
  }) async {
    if (keepalive) {
      _api.putKeepalive('/api/streams/$id/view', view.toJson());
      return;
    }
    await _api.put('/api/streams/$id/view', body: view.toJson());
  }

  Future<BudgetStream> create(BudgetStream draft) async {
    final data = await _api.post('/api/streams', body: draft.toCreateJson());
    return BudgetStream.fromJson(data as Map<String, dynamic>);
  }

  /// With [force], the version is left out (last write wins).
  Future<BudgetStream> update(BudgetStream stream, {bool force = false}) async {
    final body = stream.toPatchJson();
    if (force) body.remove('version');
    final data = await _api.patch('/api/streams/${stream.id}', body: body);
    return BudgetStream.fromJson(data as Map<String, dynamic>);
  }

  /// Deletes the stream and its events; [transfers] says what happens
  /// to the far side of its transfers in other streams.
  Future<void> delete(
    String id, {
    StreamDeleteTransfers transfers = StreamDeleteTransfers.keep,
  }) => _api.delete('/api/streams/$id?transfers=${transfers.name}');

  Future<BalanceSeries> balance(
    String streamId, {
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _api.get(
      '/api/streams/$streamId/balance',
      query: {'from': formatDate(from), 'to': formatDate(to)},
    );
    return BalanceSeries.fromJson(data);
  }

  Future<BudgetStream> reorderEvents(
    String streamId,
    List<String> eventIds,
  ) async {
    final data = await _api.patch(
      '/api/streams/$streamId/reorder-events',
      body: {'eventIds': eventIds},
    );
    return BudgetStream.fromJson(data as Map<String, dynamic>);
  }

  Future<BalanceInsights> insights(
    String streamId,
    DateTime from, {
    int days = 365,
    int horizonDays = 1825,
  }) async {
    final data = await _api.get(
      '/api/streams/$streamId/insights',
      query: {
        'from': formatDate(from),
        'days': '$days',
        'horizonDays': '$horizonDays',
      },
    );
    return BalanceInsights.fromJson(data as Map<String, dynamic>);
  }

  /// Solves one balance-goal unknown (`POST /streams/:id/goal`).
  Future<List<Scenario>> scenarios(String streamId) async {
    final data = await _api.get('/api/streams/$streamId/scenarios');
    return [
      for (final j in data as List)
        Scenario.fromJson(Map<String, dynamic>.from(j as Map)),
    ];
  }

  Future<Scenario> createScenario(
    String streamId, {
    required String name,
    required GoalRequest request,
  }) async {
    final data = await _api.post(
      '/api/streams/$streamId/scenarios',
      body: {'name': name, 'request': request.toJson()},
    );
    return Scenario.fromJson(data as Map<String, dynamic>);
  }

  Future<Scenario> updateScenario(
    String streamId,
    String id, {
    String? name,
    bool? included,
    GoalRequest? request,
  }) async {
    final data = await _api.patch(
      '/api/streams/$streamId/scenarios/$id',
      body: {
        'name': ?name,
        'included': ?included,
        if (request != null) 'request': request.toJson(),
      },
    );
    return Scenario.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteScenario(String streamId, String id) =>
      _api.delete('/api/streams/$streamId/scenarios/$id');

  Future<GoalResult> goal(String streamId, GoalRequest request) async {
    final data = await _api.post(
      '/api/streams/$streamId/goal',
      body: {...request.toJson(), 'today': formatDate(DateTime.now())},
    );
    return GoalResult.fromJson(data as Map<String, dynamic>);
  }

  /// Balance as if [extra] (unsaved) events were added.
  Future<BalanceSeries> project(
    String streamId,
    List<BudgetEvent> extra, {
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _api.post(
      '/api/streams/$streamId/project',
      body: {
        'from': formatDate(from),
        'to': formatDate(to),
        'events': [for (final t in extra) t.toCreateJson()],
      },
    );
    return BalanceSeries.fromJson(data);
  }

  /// The stream's loan summary (`GET /streams/:id/loan-summary`, spec
  /// 002 §8) as of [from] (default today); null when it has no loan.
  Future<LoanSummary?> loanSummary(String streamId, {DateTime? from}) async {
    try {
      final data = await _api.get(
        '/api/streams/$streamId/loan-summary',
        query: {'from': formatDate(from ?? DateTime.now())},
      );
      return LoanSummary.fromJson(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// The summary of an unsaved loan [draft] (spec 003 §7: the editor's
  /// live preview), standing in for the saved [replacesEventId]:
  /// `POST /project` with `loanSummaryFrom` and a one-day window.
  Future<LoanSummary?> previewLoan(
    String streamId,
    BudgetEvent draft, {
    String? replacesEventId,
    DateTime? today,
  }) async {
    final day = formatDate(today ?? DateTime.now());
    final data = await _api.post(
      '/api/streams/$streamId/project',
      body: {
        'from': day,
        'to': day,
        'loanSummaryFrom': day,
        'events': [
          {...draft.toCreateJson(), 'replacesEventId': ?replacesEventId},
        ],
      },
    );
    final s = (data as Map)['loanSummary'];
    return s is Map<String, dynamic> ? LoanSummary.fromJson(s) : null;
  }

  Future<SolveResult> solve(String streamId, SolveRequest request) async {
    final data = await _api.post(
      '/api/streams/$streamId/solve',
      body: request.toJson(),
    );
    return SolveResult.fromJson(data as Map<String, dynamic>);
  }
}

/// A stream's categories (`/api/streams/:id/categories`).
class CategoryRepository {
  CategoryRepository(this._api);

  final ApiClient _api;

  Future<List<Category>> list(String streamId) async {
    final data = await _api.get('/api/streams/$streamId/categories');
    final raw = data is Map ? data['categories'] : data;
    return [
      for (final j in (raw as List?) ?? const [])
        Category.fromJson(Map<String, dynamic>.from(j as Map)),
    ];
  }

  /// Throws [ApiException] 409 when the name is taken.
  Future<Category> create(
    String streamId, {
    required String name,
    String? color,
  }) async {
    final data = await _api.post(
      '/api/streams/$streamId/categories',
      body: {'name': name, 'color': ?color},
    );
    return Category.fromJson(data as Map<String, dynamic>);
  }

  Future<Category> update(
    String streamId,
    String id, {
    String? name,
    String? color,
    bool? hidden,
  }) async {
    final data = await _api.patch(
      '/api/streams/$streamId/categories/$id',
      body: {'name': ?name, 'color': ?color, 'hidden': ?hidden},
    );
    return Category.fromJson(data as Map<String, dynamic>);
  }

  /// How many events deleting [id] removes (`events` in it, `counterparts`:
  /// transfers' other sides in other streams).
  Future<({int events, int counterparts})> deletePreview(
    String streamId,
    String id,
  ) async {
    final data = await _api.get(
      '/api/streams/$streamId/categories/$id/delete-preview',
    ) as Map<String, dynamic>;
    return (
      events: (data['events'] as num?)?.toInt() ?? 0,
      counterparts: (data['counterparts'] as num?)?.toInt() ?? 0,
    );
  }

  /// Deletes the category and all its events (and their transfer sides).
  Future<void> delete(String streamId, String id) =>
      _api.delete('/api/streams/$streamId/categories/$id');

  /// Deletes all events of [id], keeping the category. Returns the undo
  /// batch (see [EventRepository.undoEndAllOn]) and the deleted ids.
  Future<({String? batchId, List<String> deleted})> deleteEvents(
    String streamId,
    String id,
  ) async {
    final data = await _api.delete(
      '/api/streams/$streamId/categories/$id/events',
    ) as Map<String, dynamic>?;
    return (
      batchId: data?['batchId'] as String?,
      deleted: [
        for (final x in (data?['deletedEvents'] as List?) ?? const [])
          x as String,
      ],
    );
  }
}

class EventRepository {
  EventRepository(this._api);

  final ApiClient _api;

  Future<List<BudgetEvent>> listForStream(String streamId) async {
    final data = await _api.get('/api/streams/$streamId/events');
    return _asList(data).map(BudgetEvent.fromJson).toList();
  }

  /// With [newCategory] the event goes into a new category of that name
  /// (a plan's own; 409 when the name is taken), else into its
  /// `categoryId` (or its name's category).
  Future<BudgetEvent> create(
    String streamId,
    BudgetEvent draft, {
    ({String name, String? color})? newCategory,
  }) async {
    final data = await _api.post(
      '/api/streams/$streamId/events',
      body: {
        ...draft.toCreateJson(),
        if (newCategory != null)
          'newCategory': {
            'name': newCategory.name,
            'color': ?newCategory.color,
          },
      },
    );
    return BudgetEvent.fromJson(data as Map<String, dynamic>);
  }

  /// Sends the row version unless [force] (then last write wins).
  Future<BudgetEvent> update(BudgetEvent event, {bool force = false}) async {
    final data = await _api.patch(
      '/api/events/${event.id}',
      body: {
        ...event.toCreateJson(),
        // A patch keeps omitted fields: send the schedule's unset ones as
        // null so switching end mode (count ↔ date ↔ never) or to once
        // clears the other field instead of failing validation.
        'interval': event.interval,
        'unit': event.unit?.toJson(),
        'endDate': event.endDate == null ? null : formatDate(event.endDate!),
        'occurrenceCount': event.occurrenceCount,
        if (!force && event.version != null) 'version': event.version,
      },
    );
    return BudgetEvent.fromJson(data as Map<String, dynamic>);
  }

  /// Includes / excludes a series in the balance: patches only `enabled`
  /// (no version), so it never clobbers or conflicts with other edits.
  Future<BudgetEvent> setEnabled(String id, bool enabled) async {
    final data = await _api.patch(
      '/api/events/$id',
      body: {'enabled': enabled},
    );
    return BudgetEvent.fromJson(data as Map<String, dynamic>);
  }

  Future<void> delete(String id) => _api.delete('/api/events/$id');

  /// Bulk import of a pasted `EventImport[]` (raw text; fences are
  /// stripped server-side). Its day offsets count from [root], the day
  /// selected on the timeline; the server validates and resolves them.
  /// With [dryRun] only validates and previews.
  /// Throws [ApiException] (status 400, `details` per-item issues) if invalid.
  Future<Map<String, dynamic>> import(
    String streamId,
    String raw, {
    required DateTime root,
    bool dryRun = false,
  }) async {
    final q = [if (dryRun) 'dryRun=true', 'root=${importRootParam(root)}'];
    final data = await _api.post(
      '/api/streams/$streamId/events/import?${q.join('&')}',
      body: raw,
    );
    return data as Map<String, dynamic>;
  }

  /// Undo of an import: deletes exactly [ids] (its `createdIds`) in one DB
  /// event. Returns `{deleted, deletedIds, missing}`; ids already
  /// gone are listed in `missing`, not an error.
  Future<Map<String, dynamic>> undoImport(
    String streamId,
    List<String> ids,
  ) async {
    final data = await _api.post(
      '/api/streams/$streamId/events/import/undo',
      body: {'ids': ids},
    );
    return data as Map<String, dynamic>;
  }

  /// Once-off: [date]'s occurrence takes [amount] / [direction] instead of
  /// the series value. Sends [version] (stale: 409) unless null.
  Future<BudgetEvent> setOverride(
    String eventId,
    DateTime date, {
    required EventDirection direction,
    required Decimal amount,
    int? version,
  }) async {
    final data = await _api.put(
      '/api/events/$eventId/overrides/${formatDate(date)}',
      body: {
        'direction': direction.toJson(),
        'amount': moneyToJson(amount),
        'version': ?version,
      },
    );
    return BudgetEvent.fromJson(data as Map<String, dynamic>);
  }

  /// Clears the override on [date] (null: every override of the series),
  /// restoring the natural series value.
  Future<void> clearOverrides(String eventId, {DateTime? date}) => _api.delete(
    '/api/events/$eventId/overrides'
    '${date == null ? '' : '/${formatDate(date)}'}',
  );

  /// "From now on": ends the series the day before [date] and starts a new
  /// one there with [edited]'s name, amount, direction, frequency and
  /// enabled flag, keeping the original end condition. Atomic server-side.
  /// Returns the shortened original and the new series (null when [date]
  /// is the first occurrence: then the whole series was updated).
  Future<({BudgetEvent original, BudgetEvent? created})> split(
    BudgetEvent edited,
    DateTime date, {
    bool force = false,
  }) async {
    final data = await _api.post(
      '/api/events/${edited.id}/split',
      body: {
        'date': formatDate(date),
        'name': edited.name,
        'direction': edited.direction.toJson(),
        'amount': moneyToJson(edited.amount),
        'interval': ?edited.interval,
        'unit': ?edited.unit?.toJson(),
        // The new series' rule with its days (wins over interval / unit).
        if (edited.recurrenceMode == RecurrenceMode.every)
          'frequency': edited.frequency.toJson(),
        'enabled': edited.enabled,
        // The new series' category (its colour comes with it).
        'categoryId': ?edited.categoryId,
        if (!force && edited.version != null) 'version': edited.version,
      },
    ) as Map<String, dynamic>;
    final created = data['created'];
    return (
      original: BudgetEvent.fromJson(data['original'] as Map<String, dynamic>),
      created: created is Map<String, dynamic>
          ? BudgetEvent.fromJson(created)
          : null,
    );
  }

  /// The day pick's ✂: ends every event of [streamId] ([ids] only) on
  /// [day] in one server transaction (series end on [day], events starting
  /// after it are deleted, both sides of transfers). Returns the batch id
  /// for [undoEndAllOn] (null: nothing changed) and what was done; transfers
  /// into a stream I can't edit are left alone (`blocked`).
  Future<
    ({
      String? batchId,
      List<String> ended,
      List<String> deleted,
      List<String> blocked,
    })
  >
  endAllOn(String streamId, DateTime day, {List<String>? ids}) async {
    final data = await _api.post(
      '/api/streams/$streamId/events/trim',
      body: {'date': formatDate(day), 'ids': ?ids},
    ) as Map<String, dynamic>;
    List<String> list(String k) => [
      for (final x in (data[k] as List?) ?? const []) x as String,
    ];
    return (
      batchId: data['batchId'] as String?,
      ended: list('ended'),
      deleted: list('deleted'),
      blocked: list('blocked'),
    );
  }

  /// Undoes [endAllOn]'s batch: everything comes back as it was.
  Future<void> undoEndAllOn(String streamId, String batchId) => _api.post(
    '/api/streams/$streamId/events/trim/undo',
    body: {'batchId': batchId},
  );

  Future<void> skipOccurrence(
    String eventId,
    DateTime date, {
    bool skipped = true,
  }) async {
    await _api.put(
      '/api/events/$eventId/skips/${formatDate(date)}',
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
        data['streams'] ??
        data['events'] ??
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

/// Deleting a stream: the far side of each of its transfers (in another stream)
/// is kept there as a plain debit / credit, or deleted.
enum StreamDeleteTransfers { keep, delete }
