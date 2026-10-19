import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/user_menu.dart';

import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/account_dialog.dart';
import '../../widgets/money_text.dart';
import '../../widgets/ui.dart';

class ProjectDetailPage extends ConsumerWidget {
  const ProjectDetailPage({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(projectProvider(projectId));
    final accountsAsync = ref.watch(accountsProvider(projectId));

    final count = accountsAsync.valueOrNull?.length;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'All projects',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/'),
        ),
        titleSpacing: 4,
        title: const Text('Projects'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                ref.read(accountsProvider(projectId).notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const UserMenu(),
          const SizedBox(width: 12),
        ],
      ),
      body: PageBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeading(
              eyebrow: 'Project',
              title: projectAsync.valueOrNull?.name ?? '…',
              subtitle: count == null || count == 0
                  ? null
                  : '$count account${count == 1 ? '' : 's'} · open one to plan its balance over time',
              actions: [
                if (count != 0)
                  FilledButton.icon(
                    key: const ValueKey('add-account'),
                    onPressed: () => _editAccount(context, ref),
                    icon: const Icon(Icons.add_rounded, size: 20),
                    label: const Text('Add account'),
                  ),
              ],
            ),
            Expanded(
              child: accountsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => EmptyState(
                  error: true,
                  icon: Icons.cloud_off_rounded,
                  title: 'Could not load accounts',
                  message: _errorMessage(error),
                  action: OutlinedButton.icon(
                    onPressed: () => ref
                        .read(accountsProvider(projectId).notifier)
                        .refresh(),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry'),
                  ),
                ),
                data: (accounts) {
                  if (accounts.isEmpty) {
                    return EmptyState(
                      icon: Icons.account_balance_wallet_rounded,
                      title: 'No accounts yet',
                      message: 'Add an account with a starting (seed) balance, then plan its transactions on the timeline.',
                      action: FilledButton.icon(
                        onPressed: () => _editAccount(context, ref),
                        icon: const Icon(Icons.add_rounded, size: 20),
                        label: const Text('Add account'),
                      ),
                    );
                  }
                  return LayoutBuilder(
                    builder: (context, c) {
                      final cols = c.maxWidth >= 900
                          ? 3
                          : c.maxWidth >= 600
                          ? 2
                          : 1;
                      const gap = 16.0;
                      final w = (c.maxWidth - 48 - gap * (cols - 1)) / cols;
                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                        child: Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final account in accounts)
                              SizedBox(
                                width: w,
                                child: _AccountCard(
                                  account: account,
                                  onOpen: () => context.go(
                                    '/accounts/${account.id}/timeline',
                                  ),
                                  onEdit: () => _editAccount(
                                    context,
                                    ref,
                                    existing: account,
                                  ),
                                  onDelete: () =>
                                      _deleteAccount(context, ref, account),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editAccount(
    BuildContext context,
    WidgetRef ref, {
    Account? existing,
  }) async {
    final notifier = ref.read(accountsProvider(projectId).notifier);
    if (existing == null) {
      // Create inside the dialog (errors keep it open), then open the new
      // account's timeline; pushed so back returns here.
      final created = await showAccountDialog(
        context,
        projectId: projectId,
        onSave: notifier.create,
      );
      if (created != null && context.mounted) {
        context.push('/accounts/${created.id}/timeline');
      }
      return;
    }
    final result = await showAccountDialog(
      context,
      projectId: projectId,
      existing: existing,
    );
    if (result == null) return;
    try {
      await notifier.updateAccount(result);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorMessage(error))));
      }
    }
  }

  Future<void> _deleteAccount(
    BuildContext context,
    WidgetRef ref,
    Account account,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete account?',
      message: '“${account.name}” and all of its transactions will be removed.',
    );
    if (!confirmed) return;
    try {
      await ref.read(accountsProvider(projectId).notifier).delete(account.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorMessage(error))));
      }
    }
  }
}

enum _AccountAction { edit, delete }

class _AccountCard extends ConsumerWidget {
  const _AccountCard({
    required this.account,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final Account account;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final today = ref.watch(todayBalanceProvider(account.id));
    final value = today.valueOrNull;
    final low = value != null && value <= account.lossThreshold;
    String money(num v) =>
        formatMoneyAmount(v, account.currency, decimalDigits: 2);
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
                  Pill(account.currency),
                  const SizedBox(width: 4),
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
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _AccountAction.edit,
                        child: ListTile(
                          leading: Icon(Icons.tune_rounded),
                          title: Text('Account settings'),
                        ),
                      ),
                      PopupMenuItem(
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
                      value: '≤ ${money(account.lossThreshold.toDouble())}',
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

String _errorMessage(Object error) => friendlyError(error);
