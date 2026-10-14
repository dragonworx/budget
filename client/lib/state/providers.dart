import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../data/repositories.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient();
  ref.onDispose(client.close);
  return client;
});

final projectRepositoryProvider = Provider<ProjectRepository>((ref) {
  return ProjectRepository(ref.watch(apiClientProvider));
});

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return AccountRepository(ref.watch(apiClientProvider));
});

final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  return TransactionRepository(ref.watch(apiClientProvider));
});

final projectsProvider =
    AsyncNotifierProvider<ProjectsNotifier, List<Project>>(ProjectsNotifier.new);

class ProjectsNotifier extends AsyncNotifier<List<Project>> {
  @override
  Future<List<Project>> build() {
    return ref.read(projectRepositoryProvider).list();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(projectRepositoryProvider).list(),
    );
  }

  Future<Project> create(String name) async {
    final created = await ref.read(projectRepositoryProvider).create(name);
    final current = state.valueOrNull ?? [];
    state = AsyncData([...current, created]);
    return created;
  }

  Future<void> rename(String id, String name) async {
    final updated = await ref.read(projectRepositoryProvider).rename(id, name);
    final current = state.valueOrNull ?? [];
    state = AsyncData([
      for (final p in current) p.id == id ? updated : p,
    ]);
  }

  Future<void> delete(String id) async {
    await ref.read(projectRepositoryProvider).delete(id);
    final current = state.valueOrNull ?? [];
    state = AsyncData(current.where((p) => p.id != id).toList());
  }
}

final projectProvider = FutureProvider.family<Project, String>((ref, id) async {
  final cached = ref.watch(projectsProvider).valueOrNull;
  if (cached != null) {
    for (final project in cached) {
      if (project.id == id) return project;
    }
  }
  return ref.read(projectRepositoryProvider).get(id);
});

final accountsProvider =
    AsyncNotifierProvider.family<AccountsNotifier, List<Account>, String>(
  AccountsNotifier.new,
);

class AccountsNotifier extends FamilyAsyncNotifier<List<Account>, String> {
  @override
  Future<List<Account>> build(String projectId) {
    return ref.read(accountRepositoryProvider).listForProject(projectId);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(accountRepositoryProvider).listForProject(arg),
    );
  }

  Future<Account> create(Account draft) async {
    final created =
        await ref.read(accountRepositoryProvider).create(arg, draft);
    final current = state.valueOrNull ?? [];
    state = AsyncData([...current, created]);
    return created;
  }

  Future<void> updateAccount(Account account) async {
    final updated = await ref.read(accountRepositoryProvider).update(account);
    final current = state.valueOrNull ?? [];
    state = AsyncData([
      for (final a in current) a.id == account.id ? updated : a,
    ]);
  }

  Future<void> delete(String id) async {
    await ref.read(accountRepositoryProvider).delete(id);
    final current = state.valueOrNull ?? [];
    state = AsyncData(current.where((a) => a.id != id).toList());
  }
}

final accountProvider = FutureProvider.family<Account, String>((ref, id) {
  return ref.read(accountRepositoryProvider).get(id);
});

final transactionsProvider =
    AsyncNotifierProvider.family<TransactionsNotifier, List<Transaction>, String>(
  TransactionsNotifier.new,
);

class TransactionsNotifier extends FamilyAsyncNotifier<List<Transaction>, String> {
  @override
  Future<List<Transaction>> build(String accountId) {
    return ref.read(transactionRepositoryProvider).listForAccount(accountId);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(transactionRepositoryProvider).listForAccount(arg),
    );
  }

  Future<Transaction> create(Transaction draft) async {
    final created =
        await ref.read(transactionRepositoryProvider).create(arg, draft);
    final current = state.valueOrNull ?? [];
    state = AsyncData([...current, created]);
    return created;
  }

  Future<void> updateTransaction(Transaction transaction) async {
    final updated = await ref.read(transactionRepositoryProvider).update(transaction);
    final current = state.valueOrNull ?? [];
    state = AsyncData([
      for (final s in current) s.id == transaction.id ? updated : s,
    ]);
  }

  Future<void> delete(String id) async {
    await ref.read(transactionRepositoryProvider).delete(id);
    final current = state.valueOrNull ?? [];
    state = AsyncData(current.where((s) => s.id != id).toList());
  }

  Future<void> setSkip(
    String transactionId,
    DateTime date, {
    required bool skipped,
  }) async {
    await ref.read(transactionRepositoryProvider).skipOccurrence(
          transactionId,
          date,
          skipped: skipped,
        );
  }

  Future<void> reorder(List<String> transactionIds) async {
    final account =
        await ref.read(accountRepositoryProvider).reorderTransactions(arg, transactionIds);
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

final balanceProvider =
    FutureProvider.family<BalanceSeries, BalanceQuery>((ref, query) {
  return ref.read(accountRepositoryProvider).balance(
        query.accountId,
        from: query.from,
        to: query.to,
      );
});
