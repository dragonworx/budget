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

/// Members / shares / invites of a project (owner sees all), or null when
/// they can't be loaded. Used for the "Shared" badge and actor names.
final projectPeopleProvider = FutureProvider.family<ShareInfo?, String>((
  ref,
  projectId,
) async {
  try {
    return await ref
        .read(sharingRepositoryProvider)
        .load(ShareTarget.project(projectId, ''));
  } catch (_) {
    return null;
  }
});

/// Bumped on membership / share / invite events so open share dialogs reload.
final sharingEpochProvider = StateProvider<int>((ref) => 0);

/// Display name of [userId] as known in [projectId] (null when unknown).
String? actorName(WidgetRef ref, String? projectId, String? userId) {
  if (userId == null) return null;
  if (projectId != null) {
    final info = ref.watch(projectPeopleProvider(projectId)).valueOrNull;
    for (final m in [...?info?.members, ...?info?.accountShares]) {
      if (m.userId == userId) return m.user.displayName;
    }
    final p = ref
        .watch(projectsProvider)
        .valueOrNull
        ?.where((p) => p.id == projectId)
        .firstOrNull;
    if (p?.owner?.id == userId) return p!.owner!.displayName;
  }
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
    ref.invalidate(projectsProvider);
    ref.invalidate(projectProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(accountProvider);
    ref.invalidate(transactionsProvider);
    _balances();
    ref.invalidate(scenariosProvider);
    ref.invalidate(myInvitesProvider);
    ref.invalidate(projectPeopleProvider);
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
    final pid = e.projectId;
    final aid = e.accountId;
    if (e.entityId != null) {
      final n = ref.read(remoteChangesProvider.notifier);
      n.state = {...n.state, e.entityId!: e};
    }
    switch (e.kind) {
      case 'project':
        ref.invalidate(projectsProvider);
        if (pid != null) ref.invalidate(projectProvider(pid));
        if (e.action == 'project.deleted' && pid != null) {
          _leaveIfOn(projectId: pid, message: 'This project was deleted');
        }
      case 'account':
        if (pid != null) ref.invalidate(accountsProvider(pid));
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
      case 'membership':
      case 'account_share':
      case 'invite':
        ref.invalidate(projectsProvider);
        ref.invalidate(myInvitesProvider);
        if (pid != null) {
          ref.invalidate(projectPeopleProvider(pid));
          ref.invalidate(projectProvider(pid));
          ref.invalidate(accountsProvider(pid));
        }
        if (aid != null) ref.invalidate(accountProvider(aid));
        ref.read(sharingEpochProvider.notifier).state++;
        final lost = e.action.endsWith('.revoked') || e.action.endsWith('.left');
        if (lost && e.subjectUserId != null && e.subjectUserId == _me) {
          if (e.kind == 'membership' && pid != null) {
            _leaveIfOn(projectId: pid, message: 'You no longer have access to that project');
          } else if (aid != null) {
            _leaveIfOn(accountId: aid, message: 'You no longer have access to that account');
          }
        }
      case 'admin':
        ref.invalidate(adminUsersProvider);
        ref.invalidate(adminAllowlistProvider);
    }
  }

  void _leaveIfOn({String? projectId, String? accountId, required String message}) {
    final router = ref.read(routerProvider);
    final path = router.routerDelegate.currentConfiguration.uri.path;
    var on = false;
    if (projectId != null && path == '/projects/$projectId') on = true;
    final m = RegExp(r'^/accounts/([^/]+)/').firstMatch(path);
    if (m != null) {
      final current = m.group(1)!;
      if (current == accountId) on = true;
      final acct = ref.read(accountProvider(current)).valueOrNull;
      if (projectId != null && acct?.projectId == projectId) on = true;
    }
    if (!on) return;
    router.go('/');
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

/// Is [projectId] (owned by me) shared with anyone?
bool ownedProjectShared(WidgetRef ref, Project p) {
  if (p.shared || !p.role.isOwner) return false;
  final info = ref.watch(projectPeopleProvider(p.id)).valueOrNull;
  if (info == null) return false;
  return info.members.length > 1 ||
      info.accountShares.isNotEmpty ||
      info.invites.any((i) => i.pending);
}
