import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../features/planning/goal_models.dart';
import '../data/repositories.dart';
import '../data/sharing.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient();
  ref.onDispose(client.close);
  return client;
});

final poolRepositoryProvider = Provider<PoolRepository>((ref) {
  return PoolRepository(ref.watch(apiClientProvider));
});

final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  return TransactionRepository(ref.watch(apiClientProvider));
});

/// Every pool I can open: mine first (display order), then those shared
/// with me. Pools are top level (no projects).
final poolsProvider =
    AsyncNotifierProvider<PoolsNotifier, List<Pool>>(PoolsNotifier.new);

class PoolsNotifier extends AsyncNotifier<List<Pool>> {
  /// The pool I opened last, if still accessible (from the last fetch).
  String? lastPoolId;

  Future<List<Pool>> _fetch() async {
    final list = await ref.read(poolRepositoryProvider).list();
    lastPoolId = list.lastPoolId;
    return list.pools;
  }

  @override
  Future<List<Pool>> build() => _fetch();

  Future<void> refresh() async {
    state = AsyncLoading<List<Pool>>().copyWithPrevious(state);
    state = await AsyncValue.guard(_fetch);
  }

  Future<Pool> create(Pool draft) async {
    final created = await ref.read(poolRepositoryProvider).create(draft);
    final current = state.valueOrNull ?? [];
    final mine = [for (final a in current) if (!a.shared) a];
    final shared = [for (final a in current) if (a.shared) a];
    state = AsyncData([...mine, created, ...shared]);
    return created;
  }

  Future<void> updatePool(Pool pool, {bool force = false}) async {
    final updated = await ref
        .read(poolRepositoryProvider)
        .update(pool, force: force);
    // A seed move also shifts the far side of this pool's transfers.
    ref.invalidate(transactionsProvider);
    ref.invalidate(balanceProvider);
    ref.invalidate(todayBalanceProvider);
    ref.invalidate(insightsProvider);
    ref.invalidate(poolProvider(pool.id));
    final current = state.valueOrNull ?? [];
    state = AsyncData([
      for (final a in current)
        a.id == pool.id
            ? updated.copyWith(role: a.role).withSharing(a)
            : a,
    ]);
  }

  Future<void> delete(String id) async {
    await ref.read(poolRepositoryProvider).delete(id);
    final current = state.valueOrNull ?? [];
    state = AsyncData(current.where((a) => a.id != id).toList());
  }
}

/// Whether this session has already landed (sign-in opens the last-used
/// pool once; later visits to the pools home just show the list).
final landedProvider = StateProvider<bool>((ref) => false);

/// One pool, with my role on it (the server reports it).
final poolProvider = FutureProvider.family<Pool, String>((ref, id) {
  return ref.read(poolRepositoryProvider).get(id);
});

final transactionsProvider =
    AsyncNotifierProvider.family<
      TransactionsNotifier,
      List<Transaction>,
      String
    >(TransactionsNotifier.new);

class TransactionsNotifier
    extends FamilyAsyncNotifier<List<Transaction>, String> {
  @override
  Future<List<Transaction>> build(String poolId) {
    return ref.read(transactionRepositoryProvider).listForPool(poolId);
  }

  Future<void> refresh() async {
    state = AsyncLoading<List<Transaction>>().copyWithPrevious(state);
    state = await AsyncValue.guard(
      () => ref.read(transactionRepositoryProvider).listForPool(arg),
    );
  }

  Future<Transaction> create(Transaction draft) async {
    final created = await ref
        .read(transactionRepositoryProvider)
        .create(arg, draft);
    final current = state.valueOrNull ?? [];
    state = AsyncData([...current, created]);
    _touchPeer(created.transfer);
    return created;
  }

  Future<void> updateTransaction(
    Transaction transaction, {
    bool force = false,
  }) async {
    final updated = await ref
        .read(transactionRepositoryProvider)
        .update(transaction, force: force);
    final current = state.valueOrNull ?? [];
    final before = current.where((s) => s.id == transaction.id).firstOrNull;
    state = AsyncData([
      for (final s in current) s.id == transaction.id ? updated : s,
    ]);
    _touchPeer(before?.transfer);
    _touchPeer(updated.transfer);
  }

  /// A transfer changed: the other pool's list and every balance
  /// (both sides move) are stale.
  void _touchPeer(TransferLink? link) {
    if (link == null) return;
    ref.invalidate(transactionsProvider(link.peerPoolId));
    ref.invalidate(balanceProvider);
    ref.invalidate(todayBalanceProvider);
    ref.invalidate(insightsProvider);
  }

  Future<void> delete(String id) async {
    await ref.read(transactionRepositoryProvider).delete(id);
    final current = state.valueOrNull ?? [];
    final gone = current.where((s) => s.id == id).firstOrNull;
    state = AsyncData(current.where((s) => s.id != id).toList());
    _touchPeer(gone?.transfer);
  }

  Future<void> setSkip(
    String transactionId,
    DateTime date, {
    required bool skipped,
  }) async {
    await ref
        .read(transactionRepositoryProvider)
        .skipOccurrence(transactionId, date, skipped: skipped);
    final t = (state.valueOrNull ?? [])
        .where((s) => s.id == transactionId)
        .firstOrNull;
    _touchPeer(t?.transfer);
  }

  /// Once-off override of one occurrence (see
  /// [TransactionRepository.setOverride]).
  Future<Transaction> setOverride(
    String transactionId,
    DateTime date, {
    required TransactionDirection direction,
    required Decimal amount,
    int? version,
  }) async {
    final updated = await ref
        .read(transactionRepositoryProvider)
        .setOverride(
          transactionId,
          date,
          direction: direction,
          amount: amount,
          version: version,
        );
    _replace(updated);
    return updated;
  }

  /// Clears one override ([date]) or all of them; refreshes the series.
  Future<void> clearOverrides(String transactionId, {DateTime? date}) async {
    await ref
        .read(transactionRepositoryProvider)
        .clearOverrides(transactionId, date: date);
    final fresh = await ref
        .read(transactionRepositoryProvider)
        .listForPool(arg);
    final before = (state.valueOrNull ?? [])
        .where((s) => s.id == transactionId)
        .firstOrNull;
    state = AsyncData(fresh);
    _touchPeer(before?.transfer);
  }

  /// "From now on" split; reloads the list (a new series appears).
  Future<({Transaction original, Transaction? created})> split(
    Transaction edited,
    DateTime date, {
    bool force = false,
  }) async {
    final r = await ref
        .read(transactionRepositoryProvider)
        .split(edited, date, force: force);
    final fresh = await ref
        .read(transactionRepositoryProvider)
        .listForPool(arg);
    state = AsyncData(fresh);
    _touchPeer(r.original.transfer);
    return r;
  }

  void _replace(Transaction updated) {
    final current = state.valueOrNull ?? [];
    state = AsyncData([
      for (final s in current) s.id == updated.id ? updated : s,
    ]);
    _touchPeer(updated.transfer);
  }

  Future<void> reorder(List<String> transactionIds) async {
    final pool = await ref
        .read(poolRepositoryProvider)
        .reorderTransactions(arg, transactionIds);
    ref.invalidate(poolProvider(arg));
    final byId = {for (final s in state.valueOrNull ?? []) s.id: s};
    state = AsyncData([
      for (final id in pool.transactionOrder)
        if (byId.containsKey(id)) byId.remove(id)!,
      ...byId.values,
    ]);
  }
}

class BalanceQuery {
  const BalanceQuery({
    required this.poolId,
    required this.from,
    required this.to,
  });

  final String poolId;
  final DateTime from;
  final DateTime to;

  @override
  bool operator ==(Object other) {
    return other is BalanceQuery &&
        other.poolId == poolId &&
        other.from == from &&
        other.to == to;
  }

  @override
  int get hashCode => Object.hash(poolId, from, to);
}

final balanceProvider = FutureProvider.family<BalanceSeries, BalanceQuery>((
  ref,
  query,
) {
  return ref
      .read(poolRepositoryProvider)
      .balance(query.poolId, from: query.from, to: query.to);
});

/// Closing balance today for a pool (null when there are no points).
final todayBalanceProvider = FutureProvider.family<Decimal?, String>((
  ref,
  poolId,
) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final series = await ref.watch(
    balanceProvider(BalanceQuery(poolId: poolId, from: today, to: today))
        .future,
  );
  return series.points.isEmpty ? null : series.points.last.closingBalance;
});

/// Lowest point over the next year and the runway (first alert / below
/// zero dates within five years), from today.
final insightsProvider = FutureProvider.family<BalanceInsights, String>((
  ref,
  poolId,
) {
  return ref
      .read(poolRepositoryProvider)
      .insights(poolId, DateTime.now());
});

/// Saved what-if scenarios for a pool.
final scenariosProvider = FutureProvider.family<List<Scenario>, String>((
  ref,
  poolId,
) {
  return ref.read(poolRepositoryProvider).scenarios(poolId);
});

/// Each scenario with its solve (null when excluded or unsolvable). Watches
/// [insightsProvider] so every data change (which invalidates insights)
/// re-solves the scenarios against the new baseline.
final scenarioResultsProvider =
    FutureProvider.family<List<(Scenario, GoalResult?)>, String>((
      ref,
      poolId,
    ) async {
      final list = await ref.watch(scenariosProvider(poolId).future);
      await ref.watch(insightsProvider(poolId).future);
      final repo = ref.read(poolRepositoryProvider);
      return Future.wait([
        for (final s in list)
          s.included
              ? repo
                    .goal(poolId, s.request)
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

/// The pool's effective role (owner, or the share's role).
Role poolRole(WidgetRef ref, String poolId) {
  final a = ref.watch(poolProvider(poolId)).valueOrNull;
  return a?.role ?? Role.owner;
}
