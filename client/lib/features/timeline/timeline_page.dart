import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/money_text.dart';
import '../transactions/solve_sheet.dart';
import '../transactions/transaction_editor.dart';
import 'balance_chart.dart';
import 'chart_geometry.dart';
import 'zoom_level.dart';

class TimelinePage extends ConsumerStatefulWidget {
  const TimelinePage({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends ConsumerState<TimelinePage> {
  late DateTime _dataFrom;
  late DateTime _dataTo;
  late DateTime _viewStart;
  double _visibleDays = ZoomLevel.week.visibleDays.toDouble();
  String? _windowAccountId;
  BalanceSeries? _seriesCache;

  @override
  void initState() {
    super.initState();
    final today = dateOnly(DateTime.now());
    _viewStart = today.subtract(const Duration(days: 7));
    _dataFrom = _viewStart.subtract(const Duration(days: 30));
    _dataTo = today.add(const Duration(days: 120));
  }

  void _ensureWindow(Account account) {
    if (_windowAccountId == account.id) return;
    _windowAccountId = account.id;
    _seriesCache = null;
    final today = dateOnly(DateTime.now());
    final seed = dateOnly(account.seedDate);
    _viewStart = seed.subtract(const Duration(days: 7));
    _dataFrom = dateOnly(_viewStart).subtract(const Duration(days: 30));
    final horizon = math.max(120, _visibleDays.ceil());
    _dataTo = (today.isAfter(seed) ? today : seed).add(Duration(days: horizon));
  }

  BalanceQuery get _query =>
      BalanceQuery(accountId: widget.accountId, from: _dataFrom, to: _dataTo);

  void _invalidateBalance() {
    ref.invalidate(balanceProvider(_query));
  }

  void _centerOn(DateTime day) {
    _onViewport(addDays(dateOnly(day), -_visibleDays / 3), _visibleDays);
  }

  void _applyPreset(ZoomLevel level) {
    final days = level.visibleDays.toDouble();
    final center = addDays(_viewStart, _visibleDays / 2);
    _onViewport(addDays(center, -days / 2), days);
  }

  ZoomLevel? get _finerPreset {
    for (final level in ZoomLevel.values.reversed) {
      if (level.visibleDays < _visibleDays - 0.5) return level;
    }
    return null;
  }

  ZoomLevel? get _coarserPreset {
    for (final level in ZoomLevel.values) {
      if (level.visibleDays > _visibleDays + 0.5) return level;
    }
    return null;
  }

  String get _spanLabel {
    for (final level in ZoomLevel.values) {
      if ((level.visibleDays - _visibleDays).abs() < 0.6) return level.label;
    }
    final days = _visibleDays;
    if (days < 21) return '${days.round()} days';
    if (days < 90) return '${(days / 7).round()} wk';
    if (days < 700) return '${(days / 30.44).round()} mo';
    return '${(days / 365).toStringAsFixed(1)} yr';
  }

  void _onViewport(DateTime start, double visibleDays) {
    final days = visibleDays.clamp(minVisibleDays, maxVisibleDays).toDouble();
    final viewEnd = addDays(start, days);
    var from = _dataFrom;
    var to = _dataTo;
    final bufferDays = math.max(14, days.ceil());
    final buffer = Duration(days: bufferDays);
    if (!dateOnly(start).isAfter(dateOnly(from).add(buffer))) {
      from = dateOnly(start).subtract(buffer * 2);
    }
    if (!dateOnly(viewEnd).isBefore(dateOnly(to).subtract(buffer))) {
      to = dateOnly(viewEnd).add(buffer * 2);
    }
    setState(() {
      _viewStart = start;
      _visibleDays = days;
      _dataFrom = from;
      _dataTo = to;
    });
  }

  @override
  Widget build(BuildContext context) {
    final accountAsync = ref.watch(accountProvider(widget.accountId));

    return accountAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _goBack(context, null),
          ),
          title: const Text('Timeline'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              error is ApiException ? error.message : error.toString(),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
      data: (account) {
        _ensureWindow(account);
        final balanceAsync = ref.watch(balanceProvider(_query));
        final liveSeries = balanceAsync.asData?.value;
        if (liveSeries != null) _seriesCache = liveSeries;
        final series = _seriesCache;
        // Transaction names label the occurrence dots on the chart.
        final transactionNames = {
          for (final transaction
              in ref.watch(transactionsProvider(widget.accountId)).asData?.value ??
                  const <Transaction>[])
            transaction.id: transaction.name,
        };

        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => _goBack(context, account.projectId),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(account.name),
                if (series == null)
                  Text(
                    'Seed ${formatDate(account.seedDate)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else
                  Builder(
                    builder: (context) {
                      final todayPoint = _closingNear(
                        series.points,
                        DateTime.now(),
                      );
                      if (todayPoint == null) {
                        return Text(
                          'Seed ${formatDate(account.seedDate)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        );
                      }
                      final loss =
                          todayPoint.closingBalance <= account.lossThreshold;
                      return MoneyText(
                        todayPoint.closingBalance,
                        currency: account.currency,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: loss ? AppTheme.debitColor : null,
                        ),
                      );
                    },
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => _openTransactionsSheet(context, account),
                child: const Text('Transactions'),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _finerPreset == null
                          ? null
                          : () => _applyPreset(_finerPreset!),
                      icon: const Icon(Icons.zoom_in),
                      label: const Text('In'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _coarserPreset == null
                          ? null
                          : () => _applyPreset(_coarserPreset!),
                      icon: const Icon(Icons.zoom_out),
                      label: const Text('Out'),
                    ),
                    Chip(
                      label: Text(_spanLabel),
                      visualDensity: VisualDensity.compact,
                    ),
                    Text(
                      '${formatDate(dateOnly(_viewStart))} → ${formatDate(dateOnly(addDays(_viewStart, _visibleDays)))}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _centerOn(DateTime.now()),
                      icon: const Icon(Icons.today),
                      label: const Text('Today'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _centerOn(account.seedDate),
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text('Seed'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final result = await showSolveSheet(
                          context,
                          accountId: widget.accountId,
                        );
                        if (result != null && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                result.message ??
                                    'Created ${result.transaction?.name.isNotEmpty == true ? result.transaction!.name : 'transaction'}',
                              ),
                            ),
                          );
                          _invalidateBalance();
                        }
                      },
                      icon: const Icon(Icons.calculate_outlined),
                      label: const Text('Solve'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  'Drag to pan · scroll to zoom · long-press and drag to select a range · tap a day',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFD5DEDB)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: series == null
                          ? balanceAsync.when(
                              loading: () => const Center(
                                child: CircularProgressIndicator(),
                              ),
                              error: (error, _) => Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        'Could not load balance',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        error is ApiException
                                            ? error.message
                                            : error.toString(),
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        'Window ${formatDate(_dataFrom)} → ${formatDate(_dataTo)}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                      const SizedBox(height: 12),
                                      FilledButton(
                                        onPressed: _invalidateBalance,
                                        child: const Text('Retry'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              data: (_) => const SizedBox.shrink(),
                            )
                          : Stack(
                              children: [
                                BalanceChart(
                                  series: series,
                                  currency: account.currency,
                                  seedDate: account.seedDate,
                                  lossThreshold: account.lossThreshold
                                      .toDouble(),
                                  viewStart: _viewStart,
                                  visibleDays: _visibleDays,
                                  onViewportChanged: _onViewport,
                                  onDayTap: (day, onDay) {
                                    if (onDay.isNotEmpty) {
                                      _inspectOccurrences(
                                        context,
                                        account,
                                        day,
                                        onDay,
                                      );
                                    } else {
                                      _createOnceOnDay(context, day);
                                    }
                                  },
                                  onCreateOnDay: (day) =>
                                      _createOnceOnDay(context, day),
                                  transactionNames: transactionNames,
                                  onRangeSelected: (start, end) async {
                                    final result = await showSolveSheet(
                                      context,
                                      accountId: widget.accountId,
                                      startDate: start,
                                      endDate: end,
                                    );
                                    if (result != null && context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            result.message ??
                                                'Created ${result.transaction?.name.isNotEmpty == true ? result.transaction!.name : 'transaction'}',
                                          ),
                                        ),
                                      );
                                      _invalidateBalance();
                                    }
                                  },
                                ),
                                if (balanceAsync.isLoading)
                                  const Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: LinearProgressIndicator(
                                      minHeight: 2,
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _goBack(BuildContext context, String? projectId) {
    if (projectId != null) {
      context.go('/projects/$projectId');
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  Future<void> _createOnceOnDay(BuildContext context, DateTime day) async {
    final saved = await showTransactionEditor(
      context,
      accountId: widget.accountId,
      initialDate: day,
      onceOnly: true,
    );
    if (saved != null) _invalidateBalance();
  }

  Future<void> _inspectOccurrences(
    BuildContext context,
    Account account,
    DateTime day,
    List<Occurrence> onDay,
  ) async {
    final transactions = ref.read(transactionsProvider(widget.accountId)).valueOrNull;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  formatDate(day),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                for (final occ in onDay) ...[
                  Builder(
                    builder: (context) {
                      Transaction? transaction;
                      if (transactions != null) {
                        for (final s in transactions) {
                          if (s.id == occ.transactionId) {
                            transaction = s;
                            break;
                          }
                        }
                      }
                      final name = transaction?.name.isNotEmpty == true
                          ? transaction!.name
                          : 'Transaction';
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(name),
                        subtitle: Text(
                          '${occ.skipped ? 'Skipped · ' : ''}'
                          'Δ ${occ.signedDelta}'
                          '${transaction == null ? '' : ' · ${transaction.direction.name}'}',
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) async {
                            final notifier = ref.read(
                              transactionsProvider(widget.accountId).notifier,
                            );
                            try {
                              if (value == 'edit' && transaction != null) {
                                Navigator.pop(context);
                                final saved = await showTransactionEditor(
                                  this.context,
                                  accountId: widget.accountId,
                                  existing: transaction,
                                );
                                if (saved != null) _invalidateBalance();
                              } else if (value == 'skip') {
                                await notifier.setSkip(
                                  occ.transactionId,
                                  day,
                                  skipped: !occ.skipped,
                                );
                                if (context.mounted) Navigator.pop(context);
                                _invalidateBalance();
                              } else if (value == 'delete' && transaction != null) {
                                final toDelete = transaction;
                                final ok = await showConfirmDialog(
                                  context,
                                  title: 'Delete transaction?',
                                  message:
                                      '“$name” will be removed permanently.',
                                );
                                if (!ok) return;
                                await notifier.delete(toDelete.id);
                                if (context.mounted) Navigator.pop(context);
                                _invalidateBalance();
                              }
                            } catch (error) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      error is ApiException
                                          ? error.message
                                          : error.toString(),
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                          itemBuilder: (context) => [
                            if (transaction != null)
                              const PopupMenuItem(
                                value: 'edit',
                                child: Text('Edit transaction'),
                              ),
                            PopupMenuItem(
                              value: 'skip',
                              child: Text(
                                occ.skipped
                                    ? 'Unskip occurrence'
                                    : 'Skip occurrence',
                              ),
                            ),
                            if (transaction != null)
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete transaction'),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _createOnceOnDay(this.context, day);
                  },
                  child: const Text('Add one-time transaction on this day'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openTransactionsSheet(BuildContext context, Account account) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return _TransactionsSheet(
          accountId: widget.accountId,
          onChanged: _invalidateBalance,
        );
      },
    );
  }

  BalancePoint? _closingNear(List<BalancePoint> points, DateTime day) {
    final key = dateOnly(day);
    for (final point in points) {
      if (dateOnly(point.date) == key) return point;
    }
    if (points.isEmpty) return null;
    BalancePoint? best;
    for (final point in points) {
      if (!dateOnly(point.date).isAfter(key)) {
        if (best == null || point.date.isAfter(best.date)) best = point;
      }
    }
    return best ?? points.last;
  }
}

class _TransactionsSheet extends ConsumerWidget {
  const _TransactionsSheet({required this.accountId, required this.onChanged});

  final String accountId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transactionsAsync = ref.watch(transactionsProvider(accountId));
    final accountAsync = ref.watch(accountProvider(accountId));

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, controller) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Transactions',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add transaction',
                    onPressed: () async {
                      final saved = await showTransactionEditor(
                        context,
                        accountId: accountId,
                      );
                      if (saved != null) onChanged();
                    },
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: transactionsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(
                    child: Text(
                      error is ApiException ? error.message : error.toString(),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  data: (transactions) {
                    if (transactions.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('No transactions yet'),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: () async {
                                final saved = await showTransactionEditor(
                                  context,
                                  accountId: accountId,
                                );
                                if (saved != null) onChanged();
                              },
                              child: const Text('Create transaction'),
                            ),
                          ],
                        ),
                      );
                    }

                    final order = accountAsync.valueOrNull?.transactionOrder ?? [];
                    final ordered = _orderedTransactions(transactions, order);

                    return ReorderableListView.builder(
                      scrollController: controller,
                      itemCount: ordered.length,
                      onReorderItem: (oldIndex, newIndex) async {
                        final ids = ordered.map((s) => s.id).toList();
                        final id = ids.removeAt(oldIndex);
                        ids.insert(newIndex, id);
                        try {
                          await ref
                              .read(transactionsProvider(accountId).notifier)
                              .reorder(ids);
                          onChanged();
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  error is ApiException
                                      ? error.message
                                      : error.toString(),
                                ),
                              ),
                            );
                          }
                        }
                      },
                      itemBuilder: (context, index) {
                        final transaction = ordered[index];
                        return ListTile(
                          key: ValueKey(transaction.id),
                          leading: ReorderableDragStartListener(
                            index: index,
                            child: const Icon(Icons.drag_handle),
                          ),
                          title: Text(
                            transaction.name.isEmpty ? 'Untitled' : transaction.name,
                          ),
                          subtitle: Text(
                            '${transaction.direction.name} · ${transaction.amount} · '
                            '${transaction.recurrenceMode == RecurrenceMode.once ? 'once' : 'every ${transaction.interval} ${transaction.unit?.name}'}'
                            '${transaction.enabled ? '' : ' · disabled'}',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) async {
                              final notifier = ref.read(
                                transactionsProvider(accountId).notifier,
                              );
                              try {
                                if (value == 'edit') {
                                  final saved = await showTransactionEditor(
                                    context,
                                    accountId: accountId,
                                    existing: transaction,
                                  );
                                  if (saved != null) onChanged();
                                } else if (value == 'toggle') {
                                  await notifier.updateTransaction(
                                    transaction.copyWith(enabled: !transaction.enabled),
                                  );
                                  onChanged();
                                } else if (value == 'delete') {
                                  final ok = await showConfirmDialog(
                                    context,
                                    title: 'Delete transaction?',
                                    message:
                                        '“${transaction.name.isEmpty ? 'Untitled' : transaction.name}” will be removed.',
                                  );
                                  if (!ok) return;
                                  await notifier.delete(transaction.id);
                                  onChanged();
                                }
                              } catch (error) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        error is ApiException
                                            ? error.message
                                            : error.toString(),
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'edit',
                                child: Text('Edit'),
                              ),
                              PopupMenuItem(
                                value: 'toggle',
                                child: Text(
                                  transaction.enabled ? 'Disable' : 'Enable',
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
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
        );
      },
    );
  }

  List<Transaction> _orderedTransactions(
    List<Transaction> transactions,
    List<String> order,
  ) {
    final byId = {for (final s in transactions) s.id: s};
    final out = <Transaction>[];
    for (final id in order) {
      final s = byId.remove(id);
      if (s != null) out.add(s);
    }
    out.addAll(byId.values);
    return out;
  }
}
