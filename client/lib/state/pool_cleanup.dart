import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart'
    as page;
import 'providers.dart';

/// After a pool is deleted (here or on another device): nothing keeps
/// showing it or data derived from it.
///
/// * every pool's transactions, balances, insights and scenarios refetch
///   (its transfers' far sides in other pools changed: kept as plain rows
///   or deleted), and the pools list drops it;
/// * this browser forgets it: its saved view, its "combine with" choices,
///   and the pool in every other pool's "combine with" set.
///
/// Leaving the pool if it is on screen is the caller's (routing) job.
void forgetDeletedPool(
  void Function(ProviderOrFamily) invalidate,
  String poolId, {
  String? userId,
}) {
  invalidate(poolProvider);
  invalidate(transactionsProvider);
  invalidate(balanceProvider);
  invalidate(todayBalanceProvider);
  invalidate(insightsProvider);
  invalidate(scenariosProvider);
  invalidate(scenarioResultsProvider);
  forgetPoolLocally(poolId, userId: userId);
}

final _forgotten = <String>{};

/// True once [poolId] was deleted / found gone in this session: its page,
/// still closing, must not write its view or combine choices back.
bool isForgottenPool(String poolId) => _forgotten.contains(poolId);

/// Tests: start a session with nothing forgotten.
void resetForgottenPools() => _forgotten.clear();

/// Drops [poolId] from this browser's local storage: its own saved view and
/// combine set, and its id from other pools' combine sets (any user).
void forgetPoolLocally(String poolId, {String? userId}) {
  _forgotten.add(poolId);
  for (final key in page.localKeys()) {
    final parts = key.split(':');
    if (parts.length != 3) continue;
    final (kind, uid, pid) = (parts[0], parts[1], parts[2]);
    if (kind != 'budget_view' && kind != 'budget_combine') continue;
    if (userId != null && uid != userId) continue;
    if (pid == poolId) {
      page.localRemove(key);
      continue;
    }
    if (kind != 'budget_combine') continue;
    final raw = page.localGet(key);
    if (raw == null || !raw.contains(poolId)) continue;
    try {
      final ids = [for (final v in jsonDecode(raw) as List) '$v'];
      ids.remove(poolId);
      page.localSet(key, jsonEncode(ids..sort()));
    } catch (_) {
      page.localRemove(key);
    }
  }
}
