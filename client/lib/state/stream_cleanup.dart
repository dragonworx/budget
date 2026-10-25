import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart'
    as page;
import 'providers.dart';

/// After a stream is deleted (here or on another device): nothing keeps
/// showing it or data derived from it.
///
/// * every stream's events, balances, insights and scenarios refetch
///   (its transfers' far sides in other streams changed: kept as plain rows
///   or deleted), and the streams list drops it;
/// * this browser forgets it: its saved view, its "combine with" choices,
///   and the stream in every other stream's "combine with" set.
///
/// Leaving the stream if it is on screen is the caller's (routing) job.
void forgetDeletedStream(
  void Function(ProviderOrFamily) invalidate,
  String streamId, {
  String? userId,
}) {
  invalidate(streamProvider);
  invalidate(eventsProvider);
  invalidate(balanceProvider);
  invalidate(todayBalanceProvider);
  invalidate(insightsProvider);
  invalidate(scenariosProvider);
  invalidate(scenarioResultsProvider);
  forgetStreamLocally(streamId, userId: userId);
}

final _forgotten = <String>{};

/// True once [streamId] was deleted / found gone in this session: its page,
/// still closing, must not write its view or combine choices back.
bool isForgottenStream(String streamId) => _forgotten.contains(streamId);

/// Tests: start a session with nothing forgotten.
void resetForgottenStreams() => _forgotten.clear();

/// Drops [streamId] from this browser's local storage: its own saved view and
/// combine set, and its id from other streams' combine sets (any user).
void forgetStreamLocally(String streamId, {String? userId}) {
  _forgotten.add(streamId);
  for (final key in page.localKeys()) {
    final parts = key.split(':');
    if (parts.length != 3) continue;
    final (kind, uid, pid) = (parts[0], parts[1], parts[2]);
    if (kind != 'budget_view' && kind != 'budget_combine') continue;
    if (userId != null && uid != userId) continue;
    if (pid == streamId) {
      page.localRemove(key);
      continue;
    }
    if (kind != 'budget_combine') continue;
    final raw = page.localGet(key);
    if (raw == null || !raw.contains(streamId)) continue;
    try {
      final ids = [for (final v in jsonDecode(raw) as List) '$v'];
      ids.remove(streamId);
      page.localSet(key, jsonEncode(ids..sort()));
    } catch (_) {
      page.localRemove(key);
    }
  }
}
