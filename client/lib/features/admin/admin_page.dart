import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';

import 'package:intl/intl.dart';

import '../../data/api_client.dart';
import '../../data/sharing.dart';
import '../../state/auth_providers.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/sharing_ui.dart';
import '../../widgets/ui.dart';
import '../../widgets/user_menu.dart';

final adminUsersProvider = FutureProvider.autoDispose<List<AdminUser>>(
  (ref) => ref.read(sharingRepositoryProvider).users(),
);
final adminAllowlistProvider = FutureProvider.autoDispose<Allowlist>(
  (ref) => ref.read(sharingRepositoryProvider).allowlist(),
);

/// Admins only: users (disable / enable) and the sign-in allowlist.
class AdminPage extends ConsumerWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authProvider).valueOrNull?.user;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Streams',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go(streamsPath),
        ),
        titleSpacing: 4,
        title: const Text('Admin'),
        actions: const [UserMenu(), SizedBox(width: 12)],
      ),
      body: me == null || !me.isAdmin
          ? const EmptyState(
              icon: Icons.lock_outline_rounded,
              title: 'Admins only',
              message: 'Your account does not have admin access.',
            )
          : DefaultTabController(
              length: 2,
              child: PageBody(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const TabBar(
                      tabs: [
                        Tab(key: ValueKey('admin-tab-users'), text: 'Users'),
                        Tab(
                          key: ValueKey('admin-tab-allowlist'),
                          text: 'Allowlist',
                        ),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _UsersTab(myId: me.id),
                          const _AllowlistTab(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

void _toast(BuildContext context, Object msg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg is String ? msg : friendlyError(msg))),
  );
}

class _UsersTab extends ConsumerWidget {
  const _UsersTab({required this.myId});
  final String myId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(adminUsersProvider);
    final theme = Theme.of(context);
    return users.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(friendlyError(e))),
      data: (list) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        itemCount: list.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final u = list[i];
          final last = u.lastLoginAt;
          return ListTile(
            key: ValueKey('admin-user-${u.user.email}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: RefAvatar(u.user, radius: 18),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    u.user.displayName,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (u.isAdmin) ...[
                  const SizedBox(width: 6),
                  const _Tag('Admin', AppTheme.accent),
                ],
                if (u.disabled) ...[
                  const SizedBox(width: 6),
                  const _Tag('Disabled', AppTheme.warning),
                ],
              ],
            ),
            subtitle: Text(
              [
                if (u.user.name != null && u.user.name!.isNotEmpty)
                  u.user.email,
                '${u.ownedStreams} stream${u.ownedStreams == 1 ? '' : 's'}',
                last == null
                    ? 'never signed in'
                    : 'last in ${DateFormat('d MMM y').format(last.toLocal())}',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            trailing: u.user.id == myId
                ? const Text('You')
                : Tooltip(
                    message: u.disabled
                        ? 'Enable sign-in'
                        : 'Disable (signs them out)',
                    child: Switch(
                      key: ValueKey('admin-user-enabled-${u.user.email}'),
                      value: !u.disabled,
                      onChanged: (on) async {
                        try {
                          await ref
                              .read(sharingRepositoryProvider)
                              .setDisabled(u.user.id, !on);
                          ref.invalidate(adminUsersProvider);
                          if (context.mounted) {
                            _toast(
                              context,
                              '${u.user.email} ${on ? 'enabled' : 'disabled'}',
                            );
                          }
                        } catch (e) {
                          if (context.mounted) _toast(context, e);
                        }
                      },
                    ),
                  ),
          );
        },
      ),
    );
  }
}

class _AllowlistTab extends ConsumerStatefulWidget {
  const _AllowlistTab();

  @override
  ConsumerState<_AllowlistTab> createState() => _AllowlistTabState();
}

class _AllowlistTabState extends ConsumerState<_AllowlistTab> {
  final _pattern = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pattern.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final p = _pattern.text.trim().toLowerCase();
    if (!RegExp(r'^([^@\s]+@[^@\s]+\.[^@\s]+|@[^@\s]+\.[^@\s]+)$')
        .hasMatch(p)) {
      setState(() => _error = 'Enter an email or @domain');
      return;
    }
    try {
      await ref.read(sharingRepositoryProvider).addAllowed(p);
      _pattern.clear();
      setState(() => _error = null);
      ref.invalidate(adminAllowlistProvider);
    } catch (e) {
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = ref.watch(adminAllowlistProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(friendlyError(e))),
      data: (a) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            a.openSignup
                ? 'Open sign-up is on: anyone with a Google account can sign in.'
                : 'Only these people (and admins) can sign in.'
                      '${a.invitesBypassAllowlist ? ' People you invite can sign in too.' : ''}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('allowlist-input'),
                  controller: _pattern,
                  decoration: InputDecoration(
                    labelText: 'Email or @domain',
                    hintText: 'friend@gmail.com or @example.com',
                    errorText: _error,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('allowlist-add'),
                onPressed: _add,
                child: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final p in a.entries)
            ListTile(
              key: ValueKey('allow-$p'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                p.startsWith('@')
                    ? Icons.domain_rounded
                    : Icons.person_outline_rounded,
              ),
              title: Text(p),
              trailing: IconButton(
                key: ValueKey('allow-remove-$p'),
                tooltip: 'Remove',
                icon: const Icon(Icons.close_rounded),
                onPressed: () async {
                  try {
                    await ref.read(sharingRepositoryProvider).removeAllowed(p);
                    ref.invalidate(adminAllowlistProvider);
                  } catch (e) {
                    if (context.mounted) _toast(context, e);
                  }
                },
              ),
            ),
          if (a.entries.isEmpty)
            Text(
              'No entries added in the app yet.',
              style: theme.textTheme.bodySmall,
            ),
          if (a.env.isNotEmpty || a.admins.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'From server settings (edit the env file to change)',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            for (final p in a.admins)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: Text(p),
                trailing: const _Tag('Admin', AppTheme.accent),
              ),
            for (final p in a.env)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.lock_outline_rounded),
                title: Text(p),
              ),
          ],
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
    ),
  );
}
