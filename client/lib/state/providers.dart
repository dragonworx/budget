import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../features/planning/goal_models.dart';
import '../data/repositories.dart';
import '../data/sharing.dart';
import 'auth_providers.dart';
import 'stream_cleanup.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient();
  ref.onDispose(client.close);
  return client;
});

final streamRepositoryProvider = Provider<StreamRepository>((ref) {
  return StreamRepository(ref.watch(apiClientProvider));
});

final eventRepositoryProvider = Provider<EventRepository>((ref) {
  return EventRepository(ref.watch(apiClientProvider));
});

final categoryRepositoryProvider = Provider<CategoryRepository>((ref) {
  return CategoryRepository(ref.watch(apiClientProvider));
});

/// The categories a stream's events use, oldest first: since categories
/// are global per owner, every stream of one owner lists the same set (the
/// counts cover all those streams).
final categoriesProvider =
    AsyncNotifierProvider.family<CategoriesNotifier, List<Category>, String>(
      CategoriesNotifier.new,
    );

/// The category the last event saved in a stream used (this session): a
/// new event's default.
final lastCategoryProvider = StateProvider.family<String?, String>(
  (ref, streamId) => null,
);

class CategoriesNotifier extends FamilyAsyncNotifier<List<Category>, String> {
  @override
  Future<List<Category>> build(String streamId) {
    return ref.read(categoryRepositoryProvider).list(streamId);
  }

  CategoryRepository get _repo => ref.read(categoryRepositoryProvider);

  /// Throws [ApiException] 409 when the name is taken.
  Future<Category> create(String name, {String? color}) async {
    final c = await _repo.create(arg, name: name, color: color);
    state = AsyncData([...state.valueOrNull ?? const <Category>[], c]);
    _refetchAll();
    return c;
  }

  /// Rename / recolour / show-hide: the events wear the category's name and
  /// colour, and a hidden one leaves the balance, so those reload too.
  Future<Category> edit(
    String id, {
    String? name,
    String? color,
    bool? hidden,
  }) async {
    final c = await _repo.update(
      arg,
      id,
      name: name,
      color: color,
      hidden: hidden,
    );
    state = AsyncData([
      for (final x in state.valueOrNull ?? const <Category>[])
        x.id == id ? c : x,
    ]);
    _dataChanged();
    _refetchAll();
    return c;
  }

  /// Deletes the category with all its events (and their transfer sides).
  Future<void> delete(String id) async {
    await _repo.delete(arg, id);
    state = AsyncData([
      for (final x in state.valueOrNull ?? const <Category>[])
        if (x.id != id) x,
    ]);
    _dataChanged(orderToo: true);
  }

  /// Deletes every event of [id], keeping the category. Returns the batch
  /// id for [undoDeleteEvents] (null: nothing was deleted).
  Future<String?> deleteEvents(String id) async {
    final r = await _repo.deleteEvents(arg, id);
    _dataChanged(orderToo: true);
    return r.batchId;
  }

  /// Brings back what [deleteEvents] deleted (same ids, list positions).
  Future<void> undoDeleteEvents(String batchId) async {
    await ref.read(eventRepositoryProvider).undoEndAllOn(arg, batchId);
    _dataChanged(orderToo: true);
  }

  void _dataChanged({bool orderToo = false}) {
    // Every stream: categories (and so their events) span all the owner's
    // streams, and transfers' other sides live in other streams.
    ref.invalidate(eventsProvider);
    ref.invalidate(balanceProvider);
    ref.invalidate(todayBalanceProvider);
    ref.invalidate(insightsProvider);
    if (orderToo) {
      ref.invalidate(streamProvider);
      _refetchAll();
    }
  }

  /// Every stream of the owner lists this same set: refetch them all
  /// (this one included; it keeps its value while reloading).
  void _refetchAll() => ref.invalidate(categoriesProvider);
}

/// Every stream I can open: mine first (display order), then those shared
/// with me. Streams are top level (no projects).
final streamsProvider =
    AsyncNotifierProvider<StreamsNotifier, List<BudgetStream>>(
      StreamsNotifier.new,
    );

class StreamsNotifier extends AsyncNotifier<List<BudgetStream>> {
  /// The stream I opened last, if still accessible (from the last fetch).
  String? lastStreamId;

  Future<List<BudgetStream>> _fetch() async {
    final list = await ref.read(streamRepositoryProvider).list();
    lastStreamId = list.lastStreamId;
    return list.streams;
  }

  @override
  Future<List<BudgetStream>> build() => _fetch();

  Future<void> refresh() async {
    state = AsyncLoading<List<BudgetStream>>().copyWithPrevious(state);
    state = await AsyncValue.guard(_fetch);
  }

  Future<BudgetStream> create(BudgetStream draft) async {
    final created = await ref.read(streamRepositoryProvider).create(draft);
    final current = state.valueOrNull ?? [];
    final mine = [
      for (final a in current)
        if (!a.shared) a,
    ];
    final shared = [
      for (final a in current)
        if (a.shared) a,
    ];
    state = AsyncData([...mine, created, ...shared]);
    return created;
  }

  Future<void> updateStream(BudgetStream stream, {bool force = false}) async {
    final updated = await ref
        .read(streamRepositoryProvider)
        .update(stream, force: force);
    // A seed move also shifts the far side of this stream's transfers.
    ref.invalidate(eventsProvider);
    ref.invalidate(balanceProvider);
    ref.invalidate(todayBalanceProvider);
    ref.invalidate(insightsProvider);
    ref.invalidate(streamProvider(stream.id));
    final current = state.valueOrNull ?? [];
    state = AsyncData([
      for (final a in current)
        a.id == stream.id ? updated.copyWith(role: a.role).withSharing(a) : a,
    ]);
  }

  Future<void> delete(
    String id, {
    StreamDeleteTransfers transfers = StreamDeleteTransfers.keep,
  }) async {
    await ref.read(streamRepositoryProvider).delete(id, transfers: transfers);
    final current = state.valueOrNull ?? [];
    state = AsyncData(current.where((a) => a.id != id).toList());
    if (lastStreamId == id) lastStreamId = null;
    forgetDeletedStream(
      ref.invalidate,
      id,
      userId: ref.read(authProvider).valueOrNull?.user?.id,
    );
  }
}

/// Whether this session has already landed (sign-in opens the last-used
/// stream once; later visits to the streams home just show the list).
final landedProvider = StateProvider<bool>((ref) => false);

/// One stream, with my role on it (the server reports it).
final streamProvider = FutureProvider.family<BudgetStream, String>((ref, id) {
  return ref.read(streamRepositoryProvider).get(id);
});

final eventsProvider =
    AsyncNotifierProvider.family<EventsNotifier, List<BudgetEvent>, String>(
      EventsNotifier.new,
    );

class EventsNotifier extends FamilyAsyncNotifier<List<BudgetEvent>, String> {
  @override
  Future<List<BudgetEvent>> build(String streamId) {
    return ref.read(eventRepositoryProvider).listForStream(streamId);
  }

  Future<void> refresh() async {
    state = AsyncLoading<List<BudgetEvent>>().copyWithPrevious(state);
    state = await AsyncValue.guard(
      () => ref.read(eventRepositoryProvider).listForStream(arg),
    );
  }

  Future<BudgetEvent> create(
    BudgetEvent draft, {
    ({String name, String? color})? newCategory,
  }) async {
    final created = await ref
        .read(eventRepositoryProvider)
        .create(arg, draft, newCategory: newCategory);
    final current = state.valueOrNull ?? [];
    state = AsyncData([...current, created]);
    _touchPeer(created.transfer);
    _categoriesMayChange(created.transfer);
    return created;
  }

  Future<void> updateEvent(BudgetEvent event, {bool force = false}) async {
    final updated = await ref
        .read(eventRepositoryProvider)
        .update(event, force: force);
    final current = state.valueOrNull ?? [];
    final before = current.where((s) => s.id == event.id).firstOrNull;
    state = AsyncData([
      for (final s in current) s.id == event.id ? updated : s,
    ]);
    _touchPeer(before?.transfer);
    _touchPeer(updated.transfer);
    _categoriesMayChange(updated.transfer);
  }

  /// A write can create a category (a plan's own, a transfer's far side's
  /// same-named one) and moves the per-category counts (which span all the
  /// owner's streams): refetch every list.
  void _categoriesMayChange([TransferLink? link]) =>
      ref.invalidate(categoriesProvider);

  /// Includes / excludes several series at once (the list's checkbox
  /// paint-drag): the requests run together and the list updates once.
  /// Returns the ids that failed (unchanged here) and the first error.
  Future<({Set<String> failed, Object? error})> setEnabledMany(
    Map<String, bool> changes,
  ) async {
    final repo = ref.read(eventRepositoryProvider);
    final failed = <String>{};
    Object? error;
    final done = <String, BudgetEvent>{};
    await Future.wait([
      for (final e in changes.entries)
        () async {
          try {
            done[e.key] = await repo.setEnabled(e.key, e.value);
          } catch (err) {
            failed.add(e.key);
            error ??= err;
          }
        }(),
    ]);
    if (done.isNotEmpty) {
      final current = state.valueOrNull ?? [];
      state = AsyncData([for (final s in current) done[s.id] ?? s]);
      for (final t in done.values) {
        _touchPeer(t.transfer);
      }
    }
    return (failed: failed, error: error);
  }

  /// A transfer changed: the other stream's list and every balance
  /// (both sides move) are stale.
  void _touchPeer(TransferLink? link) {
    if (link == null) return;
    ref.invalidate(eventsProvider(link.peerStreamId));
    ref.invalidate(balanceProvider);
    ref.invalidate(todayBalanceProvider);
    ref.invalidate(insightsProvider);
  }

  Future<void> delete(String id) async {
    await ref.read(eventRepositoryProvider).delete(id);
    final current = state.valueOrNull ?? [];
    final gone = current.where((s) => s.id == id).firstOrNull;
    state = AsyncData(current.where((s) => s.id != id).toList());
    _touchPeer(gone?.transfer);
    _categoriesMayChange();
  }

  Future<void> setSkip(
    String eventId,
    DateTime date, {
    required bool skipped,
  }) async {
    await ref
        .read(eventRepositoryProvider)
        .skipOccurrence(eventId, date, skipped: skipped);
    final t = (state.valueOrNull ?? [])
        .where((s) => s.id == eventId)
        .firstOrNull;
    _touchPeer(t?.transfer);
  }

  /// Once-off override of one occurrence (see
  /// [EventRepository.setOverride]).
  Future<BudgetEvent> setOverride(
    String eventId,
    DateTime date, {
    required EventDirection direction,
    required Decimal amount,
    int? version,
  }) async {
    final updated = await ref
        .read(eventRepositoryProvider)
        .setOverride(
          eventId,
          date,
          direction: direction,
          amount: amount,
          version: version,
        );
    _replace(updated);
    return updated;
  }

  /// Clears one override ([date]) or all of them; refreshes the series.
  Future<void> clearOverrides(String eventId, {DateTime? date}) async {
    await ref.read(eventRepositoryProvider).clearOverrides(eventId, date: date);
    final fresh = await ref.read(eventRepositoryProvider).listForStream(arg);
    final before = (state.valueOrNull ?? [])
        .where((s) => s.id == eventId)
        .firstOrNull;
    state = AsyncData(fresh);
    _touchPeer(before?.transfer);
  }

  /// "From now on" split; reloads the list (a new series appears).
  Future<({BudgetEvent original, BudgetEvent? created})> split(
    BudgetEvent edited,
    DateTime date, {
    bool force = false,
  }) async {
    final r = await ref
        .read(eventRepositoryProvider)
        .split(edited, date, force: force);
    final fresh = await ref.read(eventRepositoryProvider).listForStream(arg);
    state = AsyncData(fresh);
    _touchPeer(r.original.transfer);
    _categoriesMayChange();
    return r;
  }

  /// The day pick's ✂ (see [EventRepository.endAllOn]); reloads the list
  /// and every stream a transfer touched.
  Future<
    ({
      String? batchId,
      List<String> ended,
      List<String> deleted,
      List<String> blocked,
    })
  >
  endAllOn(DateTime day, {List<String>? ids}) async {
    final before = state.valueOrNull ?? const <BudgetEvent>[];
    final r = await ref
        .read(eventRepositoryProvider)
        .endAllOn(arg, day, ids: ids);
    final touched = {...r.ended, ...r.deleted};
    await _reloadAfterBatch([
      for (final t in before)
        if (touched.contains(t.id)) t.transfer,
    ]);
    return r;
  }

  /// Undo of [endAllOn]'s batch [batchId].
  Future<void> undoEndAllOn(String batchId) async {
    final before = state.valueOrNull ?? const <BudgetEvent>[];
    await ref.read(eventRepositoryProvider).undoEndAllOn(arg, batchId);
    await _reloadAfterBatch([for (final t in before) t.transfer]);
    // Restored rows (deleted by the batch) can be transfers too.
    for (final t in state.valueOrNull ?? const <BudgetEvent>[]) {
      _touchPeer(t.transfer);
    }
  }

  Future<void> _reloadAfterBatch(Iterable<TransferLink?> links) async {
    state = AsyncData(
      await ref.read(eventRepositoryProvider).listForStream(arg),
    );
    // The list order is the stream's (restored on undo).
    ref.invalidate(streamProvider(arg));
    _categoriesMayChange();
    for (final l in links) {
      _touchPeer(l);
    }
  }

  void _replace(BudgetEvent updated) {
    final current = state.valueOrNull ?? [];
    state = AsyncData([
      for (final s in current) s.id == updated.id ? updated : s,
    ]);
    _touchPeer(updated.transfer);
  }

  Future<void> reorder(List<String> eventIds) async {
    final stream = await ref
        .read(streamRepositoryProvider)
        .reorderEvents(arg, eventIds);
    ref.invalidate(streamProvider(arg));
    final byId = {
      for (final s in state.valueOrNull ?? const <BudgetEvent>[]) s.id: s,
    };
    state = AsyncData([
      for (final id in stream.eventOrder)
        if (byId.containsKey(id)) byId.remove(id)!,
      ...byId.values,
    ]);
  }
}

class BalanceQuery {
  const BalanceQuery({
    required this.streamId,
    required this.from,
    required this.to,
  });

  final String streamId;
  final DateTime from;
  final DateTime to;

  @override
  bool operator ==(Object other) {
    return other is BalanceQuery &&
        other.streamId == streamId &&
        other.from == from &&
        other.to == to;
  }

  @override
  int get hashCode => Object.hash(streamId, from, to);
}

final balanceProvider = FutureProvider.family<BalanceSeries, BalanceQuery>((
  ref,
  query,
) {
  return ref
      .read(streamRepositoryProvider)
      .balance(query.streamId, from: query.from, to: query.to);
});

/// Closing balance today for a stream (null when there are no points).
final todayBalanceProvider = FutureProvider.family<Decimal?, String>((
  ref,
  streamId,
) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final series = await ref.watch(
    balanceProvider(BalanceQuery(streamId: streamId, from: today, to: today))
        .future,
  );
  return series.points.isEmpty ? null : series.points.last.closingBalance;
});

/// Lowest point over the next year and the runway (first alert / below
/// zero dates within five years), from today.
final insightsProvider = FutureProvider.family<BalanceInsights, String>((
  ref,
  streamId,
) {
  return ref.read(streamRepositoryProvider).insights(streamId, DateTime.now());
});

/// Saved what-if scenarios for a stream.
final scenariosProvider = FutureProvider.family<List<Scenario>, String>((
  ref,
  streamId,
) {
  return ref.read(streamRepositoryProvider).scenarios(streamId);
});

/// Each scenario with its solve (null when excluded or unsolvable). Watches
/// [insightsProvider] so every data change (which invalidates insights)
/// re-solves the scenarios against the new baseline.
final scenarioResultsProvider =
    FutureProvider.family<List<(Scenario, GoalResult?)>, String>((
      ref,
      streamId,
    ) async {
      final list = await ref.watch(scenariosProvider(streamId).future);
      await ref.watch(insightsProvider(streamId).future);
      final repo = ref.read(streamRepositoryProvider);
      return Future.wait([
        for (final s in list)
          s.included
              ? repo
                    .goal(streamId, s.request)
                    .then<(Scenario, GoalResult?)>((r) => (s, r))
                    .catchError((Object _) => (s, null))
              : Future.value((s, null)),
      ]);
    });

final sharingRepositoryProvider = Provider<SharingRepository>((ref) {
  return SharingRepository(ref.watch(apiClientProvider));
});

/// Pending invites addressed to the signed-in user's email.
final myInvitesProvider = FutureProvider<List<Invite>>((ref) {
  return ref.read(sharingRepositoryProvider).myInvites();
});

/// The stream's effective role (owner, or the share's role).
Role streamRole(WidgetRef ref, String streamId) {
  final a = ref.watch(streamProvider(streamId)).valueOrNull;
  return a?.role ?? Role.owner;
}
