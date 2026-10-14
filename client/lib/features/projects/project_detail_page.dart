import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/money_text.dart';

class ProjectDetailPage extends ConsumerWidget {
  const ProjectDetailPage({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(projectProvider(projectId));
    final accountsAsync = ref.watch(accountsProvider(projectId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: Text(
          projectAsync.valueOrNull?.name ?? 'Project',
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                ref.read(accountsProvider(projectId).notifier).refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editAccount(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add account'),
      ),
      body: accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_errorMessage(error), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () =>
                      ref.read(accountsProvider(projectId).notifier).refresh(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
        data: (accounts) {
          if (accounts.isEmpty) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'No accounts yet',
                        style: Theme.of(context).textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add an account with a seed balance to open the timeline.',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: () => _editAccount(context, ref),
                        icon: const Icon(Icons.add),
                        label: const Text('Add account'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: accounts.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final account = accounts[index];
              return ListTile(
                tileColor: Colors.white.withValues(alpha: 0.55),
                title: Text(account.name),
                subtitle: Row(
                  children: [
                    MoneyText(account.seedBalance, currency: account.currency),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '· seed ${formatDate(account.seedDate)} · ${account.currency}'
                        ' · loss ≤ ${account.lossThreshold}',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                trailing: PopupMenuButton<_AccountAction>(
                  onSelected: (action) async {
                    switch (action) {
                      case _AccountAction.edit:
                        await _editAccount(context, ref, existing: account);
                      case _AccountAction.delete:
                        await _deleteAccount(context, ref, account);
                      case _AccountAction.timeline:
                        context.go('/accounts/${account.id}/timeline');
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _AccountAction.timeline,
                      child: Text('Open timeline'),
                    ),
                    PopupMenuItem(
                      value: _AccountAction.edit,
                      child: Text('Edit'),
                    ),
                    PopupMenuItem(
                      value: _AccountAction.delete,
                      child: Text('Delete'),
                    ),
                  ],
                ),
                onTap: () => context.go('/accounts/${account.id}/timeline'),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _editAccount(
    BuildContext context,
    WidgetRef ref, {
    Account? existing,
  }) async {
    final result = await showDialog<Account>(
      context: context,
      builder: (context) => _AccountDialog(
        projectId: projectId,
        existing: existing,
      ),
    );
    if (result == null) return;
    try {
      final notifier = ref.read(accountsProvider(projectId).notifier);
      if (existing == null) {
        await notifier.create(result);
      } else {
        await notifier.updateAccount(result);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(error))),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(error))),
        );
      }
    }
  }
}

enum _AccountAction { edit, delete, timeline }

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({required this.projectId, this.existing});

  final String projectId;
  final Account? existing;

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  late final TextEditingController _name;
  late final TextEditingController _currency;
  late final TextEditingController _seedBalance;
  late final TextEditingController _lossThreshold;
  late DateTime _seedDate;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _currency = TextEditingController(
      text: existing?.currency ??
          (NumberFormat.simpleCurrency().currencyName ?? 'USD'),
    );
    _seedBalance = TextEditingController(
      text: existing?.seedBalance.toString() ?? '0',
    );
    _lossThreshold = TextEditingController(
      text: existing?.lossThreshold.toString() ?? '0',
    );
    _seedDate = existing?.seedDate ?? DateTime.now();
  }

  @override
  void dispose() {
    _name.dispose();
    _currency.dispose();
    _seedBalance.dispose();
    _lossThreshold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New account' : 'Edit account'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _currency,
              decoration: const InputDecoration(
                labelText: 'Currency',
                helperText: 'ISO 4217 (e.g. USD, AUD)',
              ),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _seedBalance,
              decoration: const InputDecoration(labelText: 'Seed balance'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lossThreshold,
              decoration: const InputDecoration(
                labelText: 'Loss threshold',
                helperText: 'Balances at or below this are filled in red.',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Seed date'),
              subtitle: Text(formatDate(_seedDate)),
              trailing: const Icon(Icons.calendar_today_outlined),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _seedDate,
                  firstDate: DateTime(1970),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _seedDate = picked);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _name.text.trim();
    final currency = _currency.text.trim().toUpperCase();
    if (name.isEmpty || currency.length != 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and a 3-letter currency are required')),
      );
      return;
    }
    Decimal balance;
    try {
      balance = Decimal.parse(_seedBalance.text.trim());
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid seed balance')),
      );
      return;
    }
    final lossText = _lossThreshold.text.trim();
    final Decimal lossThreshold;
    if (lossText.isEmpty) {
      lossThreshold = Decimal.zero;
    } else {
      try {
        lossThreshold = Decimal.parse(lossText);
      } catch (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid loss threshold')),
        );
        return;
      }
    }

    final existing = widget.existing;
    final account = Account(
      id: existing?.id ?? '',
      projectId: widget.projectId,
      name: name,
      currency: currency,
      seedBalance: balance,
      seedDate: _seedDate,
      lossThreshold: lossThreshold,
      transactionOrder: existing?.transactionOrder ?? const [],
      displayOrder: existing?.displayOrder ?? 0,
    );
    Navigator.of(context).pop(account);
  }
}

String _errorMessage(Object error) {
  if (error is ApiException) return error.message;
  return error.toString();
}
