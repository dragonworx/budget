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

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return AccountRepository(ref.watch(apiClientProvider));
});

final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  return TransactionRepository(ref.watch(apiClientProvider));
});

/// Every account I can open: mine first (display order), then those shared
/// with me. Accounts are top level (no projects).
final accountsProvider =
    AsyncNotifierProvider<AccountsNotifier, List<Account>>(AccountsNotifier.new);

class AccountsNotifier extends AsyncNotifier<List<Account>> {
  /// The account I opened last, if still accessible (from the last fetch).
  String? lastAccountId;

  Future<List<Account>> _fetch() async {
    final list = await ref.read(accountRepositoryProvider).list();
    lastAccountId = list.lastAccountId;
    return list.accounts;
  }

  @override
  Future<List<Account>> build() => _fetch();

  Future<void> refresh() async {
    state = AsyncLoading<List<Account>>().copyWithPrevious(state);
    state = await AsyncValue.guard(_fetch);
  }

  Future<Account> create(Account draft) async {
    final created = await ref.read(accountRepositoryProvider).create(draft);
    final current = state.valueOrNull ?? [];
    final mine = [for (final a in current) if (!a.shared) a];
    final shared = [for (final a in current) if (a.shared) a];
    state = AsyncData([...mine, created, ...shared]);
    return created;
  }

  Future<void> updateAccount(Account account, {bool force = false}) async {
    final updated = await ref
        .read(accountRepositoryProvider)
        .update(account, force: force);
    // A seed move also shifts the far side of this account's transfers.
    ref.invalidate(transactionsProvider);
    ref.invalidate(balanceProvider);
    ref.invalidate(todayBalanceProvider);
    ref.invalidate(insightsProvider);
    ref.invalidate(accountProvider(account.id));
    final current = state.valueOrNull ?? [];
    state = AsyncData([
      for (final a in current)
        a.id == account.id
            ? updated.copyWith(role: a.role).withSharing(a)
            : a,
    ]);
  }

  Future<void> delete(String id) async {
    await ref.read(accountRepositoryProvider).delete(id);
    final current = state.valueOrNull ?? [];
    state = AsyncData(current.where((a) => a.id != id).toList());
  }
}

/// Whether this session has already landed (sign-in opens the last-used
/// account once; later visits to the accounts home just show the list).
final landedProvider = StateProvider<bool>((ref) => false);

/// One account, with my role on it (the server reports it).
final accountProvider = FutureProvider.family<Account, String>((ref, id) {
  return ref.read(accountRepositoryProvider).get(id);
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
  Future<List<Transaction>> build(String accountId) {
    return ref.read(transactionRepositoryProvider).listForAccount(accountId);
  }

  Future<void> refresh() async {
    state = AsyncLoading<List<Transaction>>().copyWithPrevious(state);
    state = await AsyncValue.guard(
      () => ref.read(transactionRepositoryProvider).listForAccount(arg),
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

  /// A transfer changed: the other account's list and every balance
  /// (both sides move) are stale.
  void _touchPeer(TransferLink? link) {
    if (link == null) return;
    ref.invalidate(transactionsProvider(link.peerAccountId));
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
        .listForAccount(arg);
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
        .listForAccount(arg);
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
    final account = await ref
        .read(accountRepositoryProvider)
        .reorderTransactions(arg, transactionIds);
    ref.invalidate(accountProvider(arg));
    final byId = {for (final s in state.valueOrNull ?? []) s.id: s};
    state = AsyncData([
      for (final id in account.transactionOrder)
        if (byId.containsKey(id)) byId.remove(id)!,
      ...byId.values,
    ]);
  }
}

class BalanceQuery {
  const BalanceQuery({
    required this.accountId,
    required this.from,
    required this.to,
  });

  final String accountId;
  final DateTime from;
  final DateTime to;

  @override
  bool operator ==(Object other) {
    return other is BalanceQuery &&
        other.accountId == accountId &&
        other.from == from &&
        other.to == to;
  }

  @override
  int get hashCode => Object.hash(accountId, from, to);
}

final balanceProvider = FutureProvider.family<BalanceSeries, BalanceQuery>((
  ref,
  query,
) {
  return ref
      .read(accountRepositoryProvider)
      .balance(query.accountId, from: query.from, to: query.to);
});

/// Closing balance today for an account (null when there are no points).
final todayBalanceProvider = FutureProvider.family<Decimal?, String>((
  ref,
  accountId,
) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final series = await ref.watch(
    balanceProvider(BalanceQuery(accountId: accountId, from: today, to: today))
        .future,
  );
  return series.points.isEmpty ? null : series.points.last.closingBalance;
});

/// Lowest point over the next year and the runway (first alert / below
/// zero dates within five years), from today.
final insightsProvider = FutureProvider.family<BalanceInsights, String>((
  ref,
  accountId,
) {
  return ref
      .read(accountRepositoryProvider)
      .insights(accountId, DateTime.now());
});

/// Saved what-if scenarios for an account.
final scenariosProvider = FutureProvider.family<List<Scenario>, String>((
  ref,
  accountId,
) {
  return ref.read(accountRepositoryProvider).scenarios(accountId);
});

/// Each scenario with its solve (null when excluded or unsolvable). Watches
/// [insightsProvider] so every data change (which invalidates insights)
/// re-solves the scenarios against the new baseline.
final scenarioResultsProvider =
    FutureProvider.family<List<(Scenario, GoalResult?)>, String>((
      ref,
      accountId,
    ) async {
      final list = await ref.watch(scenariosProvider(accountId).future);
      await ref.watch(insightsProvider(accountId).future);
      final repo = ref.read(accountRepositoryProvider);
      return Future.wait([
        for (final s in list)
          s.included
              ? repo
                    .goal(accountId, s.request)
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

/// The account's effective role (owner, or the share's role).
Role accountRole(WidgetRef ref, String accountId) {
  final a = ref.watch(accountProvider(accountId)).valueOrNull;
  return a?.role ?? Role.owner;
}
