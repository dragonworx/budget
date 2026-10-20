import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../config.dart';
import '../data/api_client.dart';
import '../data/http_client_stub.dart'
    if (dart.library.js_interop) '../data/http_client_web.dart'
    as platform;
import '../data/models.dart';
import '../data/realtime_service.dart';
import '../data/sharing.dart';
import '../features/admin/admin_page.dart';
import 'auth_providers.dart';
import 'providers.dart';

/// App-wide messenger so realtime notices show on any page.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

final realtimeServiceProvider = Provider<RealtimeService>((ref) {
  final s = RealtimeService(
    clientFactory: platform.createHttpClient,
    baseUrl: AppConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), ''),
    clientId: ApiClient.clientId,
  );
  ref.onDispose(s.dispose);
  return s;
});

/// Realtime runs in the browser build only (widget tests opt in).
final realtimeEnabledProvider = Provider<bool>((ref) => kIsWeb);

final realtimeStatusProvider = StateProvider<RealtimeStatus>(
  (ref) => RealtimeStatus.offline,
);

/// Latest remote change per entity id (for "Updated by X" banners).
final remoteChangesProvider = StateProvider<Map<String, ChangeEvent>>(
  (ref) => const {},
);

/// Owner / shares / invites of an account (the owner sees all), or null
/// when they can't be loaded. Used for the "Shared" badge and actor names.
final accountPeopleProvider = FutureProvider.family<ShareInfo?, String>((
  ref,
  accountId,
) async {
  try {
    return await ref
        .read(sharingRepositoryProvider)
        .load(ShareTarget.account(accountId, ''));
  } catch (_) {
    return null;
  }
});

/// Bumped on membership / share / invite events so open share dialogs reload.
final sharingEpochProvider = StateProvider<int>((ref) => 0);

/// Display name of [userId] as known on [accountId] (null when unknown).
String? actorName(WidgetRef ref, String? accountId, String? userId) {
  if (userId == null || accountId == null) return null;
  final info = ref.watch(accountPeopleProvider(accountId)).valueOrNull;
  for (final m in [...?info?.members, ...?info?.accountShares]) {
    if (m.userId == userId) return m.user.displayName;
  }
  final a = ref
      .watch(accountsProvider)
      .valueOrNull
      ?.where((a) => a.id == accountId)
      .firstOrNull;
  if (a?.owner?.id == userId) return a!.owner!.displayName;
  return null;
}

/// Starts / stops the stream with the session and turns events into
/// provider invalidations (plan §4c "Client mapping").
final realtimeControllerProvider = Provider<RealtimeController>((ref) {
  final c = RealtimeController(ref);
  ref.onDispose(c.dispose);
  return c;
});

class RealtimeController {
  RealtimeController(this.ref) {
    final s = ref.read(realtimeServiceProvider);
    s.onEvent = handle;
    s.onResync = (_) => refreshAll();
    s.onGoodbye = _goodbye;
    void sync() {
      final v = s.status.value;
      Future.microtask(() => ref.read(realtimeStatusProvider.notifier).state = v);
    }

    s.status.addListener(sync);
    _unlisten = () => s.status.removeListener(sync);
    ref.listen(authProvider, (_, next) {
      final signedIn = next.valueOrNull?.signedIn ?? false;
      if (signedIn && ref.read(realtimeEnabledProvider)) {
        s.start();
      } else {
        s.stop();
      }
    }, fireImmediately: true);
  }

  final Ref ref;
  late final void Function() _unlisten;

  void dispose() => _unlisten();

  String? get _me => ref.read(authProvider).valueOrNull?.user?.id;

  void _goodbye(String reason) {
    _notice(
      reason == 'account disabled'
          ? 'Your account was disabled by an admin'
          : 'Your session ended. Sign in again.',
    );
    ApiClient.onUnauthorized?.call();
  }

  /// Everything cached is stale (resync, error, long disconnect).
  void refreshAll() {
    ref.invalidate(accountsProvider);
    ref.invalidate(accountProvider);
    ref.invalidate(transactionsProvider);
    _balances();
    ref.invalidate(scenariosProvider);
    ref.invalidate(myInvitesProvider);
    ref.invalidate(accountPeopleProvider);
    ref.invalidate(adminUsersProvider);
    ref.invalidate(adminAllowlistProvider);
    ref.read(sharingEpochProvider.notifier).state++;
  }

  void _balances([String? accountId]) {
    if (accountId == null) {
      ref.invalidate(balanceProvider);
      ref.invalidate(todayBalanceProvider);
      ref.invalidate(insightsProvider);
      return;
    }
    // Balance queries are keyed by range too: refresh the whole family.
    ref.invalidate(balanceProvider);
    ref.invalidate(todayBalanceProvider(accountId));
    ref.invalidate(insightsProvider(accountId));
  }

  void _account(String id) {
    ref.invalidate(transactionsProvider(id));
    _balances(id);
  }

  void handle(ChangeEvent e) {
    final aid = e.accountId;
    if (e.entityId != null) {
      final n = ref.read(remoteChangesProvider.notifier);
      n.state = {...n.state, e.entityId!: e};
    }
    switch (e.kind) {
      case 'account':
        ref.invalidate(accountsProvider);
        if (aid != null) {
          ref.invalidate(accountProvider(aid));
          if (e.action == 'account.updated') _account(aid);
          if (e.action == 'account.deleted') {
            _leaveIfOn(accountId: aid, message: 'This account was deleted');
          }
        }
      case 'transaction':
      case 'transactions':
      case 'skip':
        if (aid != null) _account(aid);
        final peer = e.peerAccountId;
        if (peer != null) _account(peer);
      case 'scenario':
        if (aid != null) {
          ref.invalidate(scenariosProvider(aid));
          ref.invalidate(scenarioResultsProvider(aid));
        }
      case 'account_share':
      case 'invite':
        ref.invalidate(accountsProvider);
        ref.invalidate(myInvitesProvider);
        if (aid != null) {
          ref.invalidate(accountPeopleProvider(aid));
          ref.invalidate(accountProvider(aid));
        }
        ref.read(sharingEpochProvider.notifier).state++;
        final lost = e.action.endsWith('.revoked') || e.action.endsWith('.left');
        if (lost && e.subjectUserId != null && e.subjectUserId == _me && aid != null) {
          _leaveIfOn(accountId: aid, message: 'You no longer have access to that account');
        }
      case 'admin':
        ref.invalidate(adminUsersProvider);
        ref.invalidate(adminAllowlistProvider);
    }
  }

  void _leaveIfOn({required String accountId, required String message}) {
    final router = ref.read(routerProvider);
    final path = router.routerDelegate.currentConfiguration.uri.path;
    final m = RegExp(r'^/accounts/([^/]+)/').firstMatch(path);
    if (m == null || m.group(1) != accountId) return;
    router.go(accountsPath);
    _notice(message);
  }

  void _notice(String text) {
    scaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));
  }
}

/// Small dot: green connected, amber connecting/reconnecting, grey offline.
class RealtimeDot extends ConsumerWidget {
  const RealtimeDot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(realtimeStatusProvider);
    final (color, label) = switch (s) {
      RealtimeStatus.connected => (const Color(0xFF45D48C), 'Live: changes sync instantly'),
      RealtimeStatus.connecting => (const Color(0xFFF2B84B), 'Connecting…'),
      RealtimeStatus.reconnecting => (const Color(0xFFF2B84B), 'Reconnecting…'),
      RealtimeStatus.offline => (const Color(0xFF7F8A9A), 'Offline: changes from others won’t show until reconnected'),
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: 'Sync ${s.name}',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Container(
            key: ValueKey('rt-dot-${s.name}'),
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

/// Is my own [account] shared with anyone (or a pending invite)?
bool ownedAccountShared(WidgetRef ref, Account account) {
  if (account.shared || !account.role.isOwner) return false;
  final info = ref.watch(accountPeopleProvider(account.id)).valueOrNull;
  if (info == null) return false;
  return info.accountShares.isNotEmpty || info.invites.any((i) => i.pending);
}
