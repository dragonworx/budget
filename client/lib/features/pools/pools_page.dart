import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../brand/brand.dart';
import '../../data/alert.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/sharing.dart';
import '../../state/providers.dart';
import '../../state/realtime_providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/pool_dialog.dart';
import '../../widgets/pool_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/conflict_dialog.dart';
import '../../widgets/money_text.dart';
import '../../widgets/sharing_ui.dart';
import '../../widgets/ui.dart';
import '../../widgets/user_menu.dart';
import '../sharing/share_dialog.dart';
import '../../data/repositories.dart' show PoolDeleteTransfers;
import 'delete_pool_dialog.dart';

/// Opens the new-pool dialog; the pool is created inside it (errors
/// keep it open). Resolves to the created pool.
Future<Pool?> createPool(BuildContext context) {
  final notifier = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(poolsProvider.notifier);
  return showPoolDialog(context, onSave: notifier.create);
}

/// Pools home: my pools, then those shared with me, and New pool.
/// Pools are top level (there are no projects). With [landing] (the `/`
/// route), the first visit after sign-in opens the last-used pool
/// instead, when I can still open it.
class PoolsPage extends ConsumerStatefulWidget {
  const PoolsPage({super.key, this.landing = false});

  final bool landing;

  @override
  ConsumerState<PoolsPage> createState() => _PoolsPageState();
}

class _PoolsPageState extends ConsumerState<PoolsPage> {
  bool _jumping = false;

  /// On the landing route, once per session: go to the last-used pool.
  void _maybeLand(List<Pool> pools) {
    if (!widget.landing || _jumping || ref.read(landedProvider)) return;
    final last = ref.read(poolsProvider.notifier).lastPoolId;
    final target = pools.where((a) => a.id == last).firstOrNull;
    _jumping = target != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(landedProvider.notifier).state = true;
      if (target != null) context.go('/pools/${target.id}/timeline');
    });
  }

  @override
  Widget build(BuildContext context) {
    final poolsAsync = ref.watch(poolsProvider);
    final pools = poolsAsync.valueOrNull;
    if (pools != null && !poolsAsync.isLoading) _maybeLand(pools);
    final deciding =
        widget.landing &&
        !ref.watch(landedProvider) &&
        (pools == null || _jumping);
    final count = pools?.length;
    return Scaffold(
      appBar: AppBar(
        title: const Align(
          alignment: AlignmentDirectional.centerStart,
          child: BudgieNavbarLockup(height: 32),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.read(poolsProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const UserMenu(),
          const SizedBox(width: 12),
        ],
      ),
      body: deciding && !poolsAsync.hasError
          ? const Center(child: CircularProgressIndicator())
          : PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeading(
                    title: 'Pools',
                    subtitle: count == null || count == 0
                        ? 'Plan each pool\'s balance over time'
                        : '$count pool${count == 1 ? '' : 's'} · open one to plan its balance over time',
                    actions: [
                      if (count != null && count > 0)
                        FilledButton.icon(
                          key: const ValueKey('new-pool'),
                          onPressed: () => _create(context),
                          icon: const Icon(Icons.add_rounded, size: 20),
                          label: const Text('New pool'),
                        ),
                    ],
                  ),
                  Expanded(child: _body(context, poolsAsync)),
                ],
              ),
            ),
    );
  }

  Widget _body(BuildContext context, AsyncValue<List<Pool>> poolsAsync) {
    return poolsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        error: true,
        icon: Icons.cloud_off_rounded,
        title: 'Could not load pools',
        message: friendlyError(error),
        action: OutlinedButton.icon(
          onPressed: () => ref.read(poolsProvider.notifier).refresh(),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Retry'),
        ),
      ),
      data: (pools) {
        final invites =
            ref.watch(myInvitesProvider).valueOrNull ?? const <Invite>[];
        if (pools.isEmpty) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            children: [
              for (final i in invites) _PendingInviteTile(invite: i),
              EmptyState(
                key: const ValueKey('pools-empty'),
                glyph: const PoolIcon(key: ValueKey('pool-icon')),
                title: 'No pools yet',
                message: 'Create a pool with a starting (seed) balance, then plan its transactions on the timeline. Pools others share with you show up here too.',
                action: FilledButton.icon(
                  key: const ValueKey('new-pool'),
                  onPressed: () => _create(context),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('New pool'),
                ),
              ),
            ],
          );
        }
        final mine = [
          for (final a in pools)
            if (!a.shared) a,
        ];
        final shared = [
          for (final a in pools)
            if (a.shared) a,
        ];
        return LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= 900
                ? 3
                : c.maxWidth >= 600
                ? 2
                : 1;
            const gap = 16.0;
            final w = (c.maxWidth - 48 - gap * (cols - 1)) / cols;
            Widget grid(List<Pool> list) => Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final pool in list)
                  SizedBox(
                    width: w,
                    child: _PoolCard(
                      pool: pool,
                      canDelete: pool.role.isOwner,
                      canShare: pool.role.isOwner,
                      onShare: () => showShareDialog(
                        context,
                        ShareTarget.pool(pool.id, pool.name),
                      ),
                      onOpen: () => context.go('/pools/${pool.id}/timeline'),
                      onEdit: () => _edit(context, pool),
                      onDelete: () => _delete(context, pool),
                    ),
                  ),
              ],
            );
            Widget heading(String t, String key) => Padding(
              key: ValueKey(key),
              padding: const EdgeInsets.fromLTRB(2, 14, 0, 8),
              child: Text(
                t,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: AppTheme.textMuted),
              ),
            );
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (invites.isNotEmpty) ...[
                    heading('Invitations for you', 'invites-heading'),
                    for (final i in invites) _PendingInviteTile(invite: i),
                  ],
                  if (mine.isNotEmpty && shared.isNotEmpty)
                    heading('My pools', 'mine-heading'),
                  if (mine.isNotEmpty) grid(mine),
                  if (shared.isNotEmpty) ...[
                    heading('Shared with me', 'shared-heading'),
                    grid(shared),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _create(BuildContext context) async {
    final created = await createPool(context);
    if (created != null && context.mounted) {
      context.go('/pools/${created.id}/timeline');
    }
  }

  Future<void> _edit(BuildContext context, Pool existing) async {
    final notifier = ref.read(poolsProvider.notifier);
    final result = await showPoolDialog(context, existing: existing);
    if (result == null) return;
    try {
      if (!context.mounted) return;
      await saveWithConflictCheck(
        context,
        save: (force) => notifier.updatePool(result, force: force),
        reload: notifier.refresh,
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }

  Future<void> _delete(BuildContext context, Pool pool) async {
    // What goes with it decides the confirm: a pool with transactions lists
    // them and asks what happens to its transfers' far sides.
    List<Transaction> transactions;
    try {
      transactions = await ref.read(transactionsProvider(pool.id).future);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
      return;
    }
    if (!context.mounted) return;
    PoolDeleteTransfers? mode;
    if (transactions.isEmpty) {
      final confirmed = await showConfirmDialog(
        context,
        title: 'Delete pool?',
        message: '“${pool.name}” will be removed. It has no transactions.',
        confirmLabel: 'Delete pool',
      );
      if (confirmed) mode = PoolDeleteTransfers.keep;
    } else {
      mode = await showDeletePoolDialog(
        context,
        pool: pool,
        transactions: transactions,
        pools: ref.read(poolsProvider).valueOrNull ?? const [],
      );
    }
    if (mode == null) return;
    try {
      await ref.read(poolsProvider.notifier).delete(pool.id, transfers: mode);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }
}

enum _PoolAction { edit, delete, share }

class _PoolCard extends ConsumerWidget {
  const _PoolCard({
    required this.pool,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
    required this.onShare,
    this.canDelete = true,
    this.canShare = true,
  });

  final VoidCallback onShare;
  final bool canDelete;
  final bool canShare;
  final Pool pool;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final today = ref.watch(todayBalanceProvider(pool.id));
    final value = today.valueOrNull;
    final low = value != null && belowAlert(value, pool.lossThreshold);
    String money(num v) => formatMoneyAmount(v, decimalDigits: 2);
    return Material(
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('pool-card-${pool.id}'),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const IconTile.glyph(PoolIcon(key: ValueKey('pool-icon'))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Tooltip(
                      message: pool.name,
                      waitDuration: const Duration(milliseconds: 500),
                      child: Text(
                        pool.name,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!pool.role.isOwner) ...[
                    RoleChip(pool.role),
                    const SizedBox(width: 6),
                  ] else if (ownedPoolShared(ref, pool)) ...[
                    const Tooltip(
                      message: 'Shared with others',
                      child: Icon(
                        Icons.people_alt_outlined,
                        key: ValueKey('owned-shared-badge'),
                        size: 18,
                        color: AppTheme.accent,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (pool.role.canEdit || canShare)
                    PopupMenuButton<_PoolAction>(
                      tooltip: 'Pool actions',
                      padding: EdgeInsets.zero,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      iconSize: 20,
                      icon: const Icon(Icons.more_vert_rounded),
                      onSelected: (action) => switch (action) {
                        _PoolAction.edit => onEdit(),
                        _PoolAction.delete => onDelete(),
                        _PoolAction.share => onShare(),
                      },
                      itemBuilder: (context) => [
                        if (canShare)
                          const PopupMenuItem(
                            value: _PoolAction.share,
                            child: ListTile(
                              leading: Icon(Icons.person_add_alt_1_outlined),
                              title: Text('Share pool…'),
                            ),
                          ),
                        if (pool.role.canEdit)
                          const PopupMenuItem(
                            value: _PoolAction.edit,
                            child: ListTile(
                              leading: Icon(Icons.tune_rounded),
                              title: Text('Pool settings'),
                            ),
                          ),
                        if (canDelete)
                          const PopupMenuItem(
                            value: _PoolAction.delete,
                            child: ListTile(
                              leading: Icon(Icons.delete_outline_rounded),
                              title: Text('Delete pool'),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
              if (pool.shared && pool.owner != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Shared by ${pool.owner!.displayName}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'BALANCE TODAY',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textFaint,
                ),
              ),
              const SizedBox(height: 2),
              Padding(
                padding: EdgeInsets.zero,
                child: SizedBox(
                  height: 34,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      today.isLoading && value == null
                          ? '—'
                          : value == null
                          ? 'No data'
                          : money(value.toDouble()),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: low ? AppTheme.debitColor : AppTheme.text,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Padding(
                padding: EdgeInsets.zero,
                child: Row(
                  children: [
                    Expanded(
                      child: _Fact(
                        label:
                            'Seed · ${DateFormat('d MMM y').format(pool.seedDate)}',
                        value: money(pool.seedBalance.toDouble()),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _Fact(
                      label: 'Alert at',
                      value: '< ${money(pool.lossThreshold.toDouble())}',
                      alignEnd: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Spacer(),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: onOpen,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: const Text('Open timeline'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({
    required this.label,
    required this.value,
    this.alignEnd = false,
  });
  final String label;
  final String value;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.text),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// An invite addressed to me that hasn't been accepted yet.
class _PendingInviteTile extends StatelessWidget {
  const _PendingInviteTile({required this.invite});
  final Invite invite;

  @override
  Widget build(BuildContext context) {
    final by = invite.invitedBy;
    return Card(
      key: ValueKey('my-invite-${invite.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: by == null
            ? const Icon(Icons.mail_outline_rounded)
            : RefAvatar(by, radius: 16),
        title: Text(invite.targetLabel),
        subtitle: Text(
          '${by?.displayName ?? 'Someone'} invited you as ${invite.role.label.toLowerCase()}. '
          'Open the link they sent you, or sign out and back in to accept.',
        ),
        trailing: RoleChip(invite.role),
      ),
    );
  }
}
