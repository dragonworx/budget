import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/alert.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/sharing.dart';
import '../../state/providers.dart';
import '../../state/realtime_providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/account_dialog.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/conflict_dialog.dart';
import '../../widgets/money_text.dart';
import '../../widgets/sharing_ui.dart';
import '../../widgets/ui.dart';
import '../../widgets/user_menu.dart';
import '../sharing/share_dialog.dart';

/// Opens the new-account dialog; the account is created inside it (errors
/// keep it open). Resolves to the created account.
Future<Account?> createAccount(BuildContext context) {
  final notifier = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(accountsProvider.notifier);
  return showAccountDialog(context, onSave: notifier.create);
}

/// Accounts home: my accounts, then those shared with me, and New account.
/// Accounts are top level (there are no projects). With [landing] (the `/`
/// route), the first visit after sign-in opens the last-used account
/// instead, when I can still open it.
class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key, this.landing = false});

  final bool landing;

  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage> {
  bool _jumping = false;

  /// On the landing route, once per session: go to the last-used account.
  void _maybeLand(List<Account> accounts) {
    if (!widget.landing || _jumping || ref.read(landedProvider)) return;
    final last = ref.read(accountsProvider.notifier).lastAccountId;
    final target = accounts.where((a) => a.id == last).firstOrNull;
    _jumping = target != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(landedProvider.notifier).state = true;
      if (target != null) context.go('/accounts/${target.id}/timeline');
    });
  }

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    final accounts = accountsAsync.valueOrNull;
    if (accounts != null && !accountsAsync.isLoading) _maybeLand(accounts);
    final deciding =
        widget.landing &&
        !ref.watch(landedProvider) &&
        (accounts == null || _jumping);
    final count = accounts?.length;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.timeline_rounded, color: AppTheme.accent),
            SizedBox(width: 10),
            Text('Budget'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.read(accountsProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const UserMenu(),
          const SizedBox(width: 12),
        ],
      ),
      body: deciding && !accountsAsync.hasError
          ? const Center(child: CircularProgressIndicator())
          : PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeading(
                    title: 'Accounts',
                    subtitle: count == null || count == 0
                        ? 'Plan each account\'s balance over time'
                        : '$count account${count == 1 ? '' : 's'} · open one to plan its balance over time',
                    actions: [
                      if (count != null && count > 0)
                        FilledButton.icon(
                          key: const ValueKey('new-account'),
                          onPressed: () => _create(context),
                          icon: const Icon(Icons.add_rounded, size: 20),
                          label: const Text('New account'),
                        ),
                    ],
                  ),
                  Expanded(child: _body(context, accountsAsync)),
                ],
              ),
            ),
    );
  }

  Widget _body(BuildContext context, AsyncValue<List<Account>> accountsAsync) {
    return accountsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        error: true,
        icon: Icons.cloud_off_rounded,
        title: 'Could not load accounts',
        message: friendlyError(error),
        action: OutlinedButton.icon(
          onPressed: () => ref.read(accountsProvider.notifier).refresh(),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Retry'),
        ),
      ),
      data: (accounts) {
        final invites =
            ref.watch(myInvitesProvider).valueOrNull ?? const <Invite>[];
        if (accounts.isEmpty) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            children: [
              for (final i in invites) _PendingInviteTile(invite: i),
              EmptyState(
                key: const ValueKey('accounts-empty'),
                icon: Icons.account_balance_wallet_rounded,
                title: 'No accounts yet',
                message:
                    'Create an account with a starting (seed) balance, then plan its transactions on the timeline. Accounts others share with you show up here too.',
                action: FilledButton.icon(
                  key: const ValueKey('new-account'),
                  onPressed: () => _create(context),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('New account'),
                ),
              ),
            ],
          );
        }
        final mine = [for (final a in accounts) if (!a.shared) a];
        final shared = [for (final a in accounts) if (a.shared) a];
        return LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= 900
                ? 3
                : c.maxWidth >= 600
                ? 2
                : 1;
            const gap = 16.0;
            final w = (c.maxWidth - 48 - gap * (cols - 1)) / cols;
            Widget grid(List<Account> list) => Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final account in list)
                  SizedBox(
                    width: w,
                    child: _AccountCard(
                      account: account,
                      canDelete: account.role.isOwner,
                      canShare: account.role.isOwner,
                      onShare: () => showShareDialog(
                        context,
                        ShareTarget.account(account.id, account.name),
                      ),
                      onOpen: () =>
                          context.go('/accounts/${account.id}/timeline'),
                      onEdit: () => _edit(context, account),
                      onDelete: () => _delete(context, account),
                    ),
                  ),
              ],
            );
            Widget heading(String t, String key) => Padding(
              key: ValueKey(key),
              padding: const EdgeInsets.fromLTRB(2, 14, 0, 8),
              child: Text(
                t,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: AppTheme.textMuted,
                ),
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
                    heading('My accounts', 'mine-heading'),
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
    final created = await createAccount(context);
    if (created != null && context.mounted) {
      context.go('/accounts/${created.id}/timeline');
    }
  }

  Future<void> _edit(BuildContext context, Account existing) async {
    final notifier = ref.read(accountsProvider.notifier);
    final result = await showAccountDialog(context, existing: existing);
    if (result == null) return;
    try {
      if (!context.mounted) return;
      await saveWithConflictCheck(
        context,
        save: (force) => notifier.updateAccount(result, force: force),
        reload: notifier.refresh,
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }

  Future<void> _delete(BuildContext context, Account account) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete account?',
      message: '“${account.name}” and all of its transactions will be removed.',
    );
    if (!confirmed) return;
    try {
      await ref.read(accountsProvider.notifier).delete(account.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }
}

enum _AccountAction { edit, delete, share }

class _AccountCard extends ConsumerWidget {
  const _AccountCard({
    required this.account,
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
  final Account account;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final today = ref.watch(todayBalanceProvider(account.id));
    final value = today.valueOrNull;
    final low = value != null && belowAlert(value, account.lossThreshold);
    String money(num v) =>
        formatMoneyAmount(v, decimalDigits: 2);
    return Material(
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('account-card-${account.id}'),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const IconTile(Icons.account_balance_wallet_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Tooltip(
                      message: account.name,
                      waitDuration: const Duration(milliseconds: 500),
                      child: Text(
                        account.name,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!account.role.isOwner) ...[
                    RoleChip(account.role),
                    const SizedBox(width: 6),
                  ] else if (ownedAccountShared(ref, account)) ...[
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
                  if (account.role.canEdit || canShare)
                  PopupMenuButton<_AccountAction>(
                    tooltip: 'Account actions',
                    padding: EdgeInsets.zero,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    iconSize: 20,
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (action) => switch (action) {
                      _AccountAction.edit => onEdit(),
                      _AccountAction.delete => onDelete(),
                      _AccountAction.share => onShare(),
                    },
                    itemBuilder: (context) => [
                      if (canShare)
                        const PopupMenuItem(
                          value: _AccountAction.share,
                          child: ListTile(
                            leading: Icon(Icons.person_add_alt_1_outlined),
                            title: Text('Share account…'),
                          ),
                        ),
                      if (account.role.canEdit)
                      const PopupMenuItem(
                        value: _AccountAction.edit,
                        child: ListTile(
                          leading: Icon(Icons.tune_rounded),
                          title: Text('Account settings'),
                        ),
                      ),
                      if (canDelete)
                      const PopupMenuItem(
                        value: _AccountAction.delete,
                        child: ListTile(
                          leading: Icon(Icons.delete_outline_rounded),
                          title: Text('Delete account'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (account.shared && account.owner != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Shared by ${account.owner!.displayName}',
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
                            'Seed · ${DateFormat('d MMM y').format(account.seedDate)}',
                        value: money(account.seedBalance.toDouble()),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _Fact(
                      label: 'Alert at',
                      value: '< ${money(account.lossThreshold.toDouble())}',
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

