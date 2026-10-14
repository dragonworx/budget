import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../timeline/occurrence_dates.dart';
import 'solve_sheet.dart';

Future<Transaction?> showTransactionEditor(
  BuildContext context, {
  required String accountId,
  Transaction? existing,
  DateTime? initialDate,
  bool onceOnly = false,
}) {
  return showModalBottomSheet<Transaction>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      final inset = MediaQuery.viewInsetsOf(context).bottom;
      final height = MediaQuery.sizeOf(context).height * 0.92 - inset;
      return Padding(
        padding: EdgeInsets.only(bottom: inset),
        child: SizedBox(
          height: height.clamp(320, 900),
          child: TransactionEditor(
            accountId: accountId,
            existing: existing,
            initialDate: initialDate,
            onceOnly: onceOnly,
          ),
        ),
      );
    },
  );
}

class TransactionEditor extends ConsumerStatefulWidget {
  const TransactionEditor({
    super.key,
    required this.accountId,
    this.existing,
    this.initialDate,
    this.onceOnly = false,
  });

  final String accountId;
  final Transaction? existing;
  final DateTime? initialDate;
  final bool onceOnly;

  @override
  ConsumerState<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends ConsumerState<TransactionEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _interval;
  late final TextEditingController _count;
  late TransactionDirection _direction;
  late RecurrenceMode _recurrenceMode;
  late RecurrenceUnit _unit;
  late EndMode _endMode;
  late DateTime _startDate;
  DateTime? _endDate;
  late bool _enabled;
  bool _saving = false;
  String? _endDateError;

  /// Whether the count field holds a user value rather than the default.
  late bool _countEdited;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _amount = TextEditingController(text: existing?.amount.toString() ?? '');
    _interval = TextEditingController(
      text: (existing?.interval ?? 1).toString(),
    );
    _count = TextEditingController(
      text: (existing?.occurrenceCount ?? 12).toString(),
    );
    _countEdited = existing?.occurrenceCount != null;
    _direction = existing?.direction ?? TransactionDirection.debit;
    _recurrenceMode = widget.onceOnly
        ? RecurrenceMode.once
        : (existing?.recurrenceMode ?? RecurrenceMode.every);
    _unit = existing?.unit ?? RecurrenceUnit.months;
    _endMode = existing?.endMode ?? EndMode.count;
    if (existing == null && _recurrenceMode == RecurrenceMode.once) {
      _endMode = EndMode.never;
    }
    _startDate = existing?.startDate ?? widget.initialDate ?? DateTime.now();
    _endDate = existing?.endDate;
    _enabled = existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _interval.dispose();
    _count.dispose();
    super.dispose();
  }

  int get _intervalValue => int.tryParse(_interval.text.trim()) ?? 1;

  Transaction _draft({Decimal? amount, int? count, DateTime? endDate}) {
    final parsedAmount =
        amount ?? Decimal.tryParse(_amount.text.trim()) ?? Decimal.zero;
    final repeating = _recurrenceMode == RecurrenceMode.every;
    final endMode = repeating ? _endMode : EndMode.never;
    return Transaction(
      id: widget.existing?.id ?? 'preview',
      accountId: widget.accountId,
      name: _name.text.trim(),
      direction: _direction,
      amount: parsedAmount,
      startDate: _startDate,
      recurrenceMode: _recurrenceMode,
      interval: repeating ? _intervalValue : null,
      unit: repeating ? _unit : null,
      endMode: endMode,
      endDate: endMode == EndMode.untilDate ? (endDate ?? _endDate) : null,
      occurrenceCount: endMode == EndMode.count
          ? (count ?? int.tryParse(_count.text.trim()) ?? 1)
          : null,
      enabled: _enabled,
    );
  }

  /// How many times this transaction pays, when the schedule is finite.
  int? _finiteCount(Transaction draft) {
    if (draft.recurrenceMode == RecurrenceMode.once) return 1;
    if (draft.endMode == EndMode.count) return draft.occurrenceCount;
    if (draft.endMode == EndMode.untilDate && draft.endDate != null) {
      final dates = estimateOccurrenceDates(draft, maxCount: 5000);
      return dates.isEmpty ? null : dates.length;
    }
    return null;
  }

  Decimal? _computedTotal() {
    final amount = Decimal.tryParse(_amount.text.trim());
    if (amount == null) return null;
    final count = _finiteCount(_draft());
    if (count == null || count < 1) return null;
    return amount * Decimal.fromInt(count);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewDates = estimateOccurrenceDates(_draft(), maxCount: 6);
    final liveTotal = _computedTotal();

    return SafeArea(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.existing == null ? 'New transaction' : 'Edit transaction',
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'Rent, Paycheck…',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<TransactionDirection>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: TransactionDirection.credit,
                          label: Text('Credit'),
                          icon: Icon(Icons.arrow_upward),
                        ),
                        ButtonSegment(
                          value: TransactionDirection.debit,
                          label: Text('Debit'),
                          icon: Icon(Icons.arrow_downward),
                        ),
                      ],
                      selected: {_direction},
                      onSelectionChanged: (value) {
                        setState(() {
                          _direction = value.first;
                        });
                      },
                      style: ButtonStyle(
                        foregroundColor: WidgetStateProperty.resolveWith((
                          states,
                        ) {
                          if (states.contains(WidgetState.selected)) {
                            return _direction == TransactionDirection.credit
                                ? AppTheme.creditColor
                                : AppTheme.debitColor;
                          }
                          return null;
                        }),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('Recurrence', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    SegmentedButton<RecurrenceMode>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: RecurrenceMode.once,
                          label: Text('Once'),
                        ),
                        ButtonSegment(
                          value: RecurrenceMode.every,
                          label: Text('Repeating'),
                        ),
                      ],
                      selected: {_recurrenceMode},
                      onSelectionChanged: (value) {
                        setState(() {
                          _recurrenceMode = value.first;
                          if (_recurrenceMode == RecurrenceMode.once) {
                            _endMode = EndMode.never;
                            _endDateError = null;
                          }
                        });
                      },
                    ),
                    if (_recurrenceMode == RecurrenceMode.once) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Choose Repeating to set frequency, increment, and duration.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (_recurrenceMode == RecurrenceMode.every) ...[
                      const SizedBox(height: 16),
                      Text('Frequency', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      SegmentedButton<RecurrenceUnit>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: RecurrenceUnit.days,
                            label: Text('Day'),
                          ),
                          ButtonSegment(
                            value: RecurrenceUnit.weeks,
                            label: Text('Week'),
                          ),
                          ButtonSegment(
                            value: RecurrenceUnit.months,
                            label: Text('Month'),
                          ),
                          ButtonSegment(
                            value: RecurrenceUnit.years,
                            label: Text('Year'),
                          ),
                        ],
                        selected: {_unit},
                        onSelectionChanged: (value) {
                          setState(() {
                            _unit = value.first;
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      Text('Increment', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'How many ${_unitPlural(_unit)} between each occurrence.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Decrease increment',
                            onPressed: _intervalValue <= 1
                                ? null
                                : () {
                                    setState(() {
                                      _interval.text = '${_intervalValue - 1}';
                                    });
                                  },
                            icon: const Icon(Icons.remove),
                          ),
                          SizedBox(
                            width: 72,
                            child: TextFormField(
                              controller: _interval,
                              textAlign: TextAlign.center,
                              decoration: const InputDecoration(
                                labelText: 'Every',
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setState(() {}),
                              validator: (value) {
                                if (_recurrenceMode != RecurrenceMode.every) {
                                  return null;
                                }
                                final n = int.tryParse(value ?? '');
                                if (n == null || n < 1) return '≥ 1';
                                return null;
                              },
                            ),
                          ),
                          IconButton(
                            tooltip: 'Increase increment',
                            onPressed: () {
                              setState(() {
                                _interval.text = '${_intervalValue + 1}';
                              });
                            },
                            icon: const Icon(Icons.add),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _unitPlural(_unit, _intervalValue),
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Every $_intervalValue ${_unitPlural(_unit, _intervalValue)}',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      Text('Duration', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      SegmentedButton<EndMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: EndMode.never,
                            label: Text('Never'),
                          ),
                          ButtonSegment(
                            value: EndMode.untilDate,
                            label: Text('Until date'),
                          ),
                          ButtonSegment(
                            value: EndMode.count,
                            label: Text('Count'),
                          ),
                        ],
                        selected: {_endMode},
                        onSelectionChanged: (value) {
                          setState(() {
                            _endMode = value.first;
                            _endDateError = null;
                            if (_endMode != EndMode.untilDate) _endDate = null;
                          });
                        },
                      ),
                      if (_endMode == EndMode.untilDate) ...[
                        const SizedBox(height: 8),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('End date'),
                          subtitle: Text(
                            _endDate == null
                                ? 'Pick a date'
                                : formatDate(_endDate!),
                          ),
                          trailing: const Icon(Icons.calendar_today_outlined),
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _endDate ?? _startDate,
                              firstDate: _startDate,
                              lastDate: DateTime(2100),
                            );
                            if (picked != null) {
                              setState(() {
                                _endDate = picked;
                                _endDateError = null;
                              });
                            }
                          },
                        ),
                        if (_endDateError != null)
                          Text(
                            _endDateError!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                      ],
                      if (_endMode == EndMode.count) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _count,
                          decoration: const InputDecoration(
                            labelText: 'Number of occurrences',
                            helperText: 'Includes the first occurrence',
                          ),
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setState(() => _countEdited = true),
                          validator: (value) {
                            if (_endMode != EndMode.count) return null;
                            final n = int.tryParse(value ?? '');
                            if (n == null || n < 1) return '≥ 1';
                            return null;
                          },
                        ),
                      ],
                    ],
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Start date'),
                      subtitle: Text(formatDate(_startDate)),
                      trailing: const Icon(Icons.calendar_today_outlined),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _startDate,
                          firstDate: DateTime(1970),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setState(() {
                            _startDate = picked;
                          });
                        }
                      },
                    ),
                    TextFormField(
                      controller: _amount,
                      decoration: const InputDecoration(
                        labelText: 'Increment amount',
                        helperText: 'Amount added or removed each occurrence',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) => setState(() {}),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Required';
                        }
                        try {
                          final amount = Decimal.parse(value.trim());
                          if (amount < Decimal.zero) return 'Must be ≥ 0';
                        } catch (_) {
                          return 'Invalid amount';
                        }
                        return null;
                      },
                    ),
                    if (liveTotal != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Total amount $liveTotal'
                        '${_finiteCount(_draft()) != null ? ' over ${_finiteCount(_draft())} occurrences' : ''}',
                        style: theme.textTheme.titleMedium,
                      ),
                    ] else if (_recurrenceMode == RecurrenceMode.every &&
                        _endMode == EndMode.never) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Total is open-ended while this repeats forever.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _openPlanner,
                      icon: const Icon(Icons.calculate_outlined),
                      label: const Text('Solve from what you know…'),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Know the total but not the count or end date? Fill in '
                      'what you know and the rest is calculated.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Enabled'),
                      value: _enabled,
                      onChanged: (value) => setState(() {
                        _enabled = value;
                      }),
                    ),
                    if (previewDates.isNotEmpty) ...[
                      Text(
                        'Next occurrences',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final date in previewDates)
                            Chip(
                              label: Text(formatDate(date)),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save transaction'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPlanner() async {
    final repeating = _recurrenceMode == RecurrenceMode.every;
    final amount = Decimal.tryParse(_amount.text.trim());
    final result = await showSolveSheet(
      context,
      accountId: widget.accountId,
      saveOnCommit: false,
      initial: SolveRequest(
        name: _name.text.trim(),
        direction: _direction,
        unit: repeating ? _unit : RecurrenceUnit.weeks,
        interval: repeating ? _intervalValue : 1,
        startDate: _startDate,
        amount: amount != null && amount > Decimal.zero ? amount : null,
        endDate: repeating && _endMode == EndMode.untilDate ? _endDate : null,
        occurrenceCount: repeating && _endMode == EndMode.count && _countEdited
            ? int.tryParse(_count.text.trim())
            : null,
      ),
    );
    final transaction = result?.transaction;
    if (transaction == null || !mounted) return;
    setState(() {
      _name.text = transaction.name;
      _direction = transaction.direction;
      _amount.text = transaction.amount.toString();
      _startDate = transaction.startDate;
      _recurrenceMode = transaction.recurrenceMode;
      _endDateError = null;
      if (transaction.recurrenceMode == RecurrenceMode.once) {
        _endMode = EndMode.never;
        _endDate = null;
        return;
      }
      _interval.text = '${transaction.interval ?? 1}';
      _unit = transaction.unit ?? _unit;
      _endMode = transaction.endMode;
      _endDate = transaction.endDate;
      if (transaction.occurrenceCount != null) {
        _count.text = '${transaction.occurrenceCount}';
        _countEdited = true;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _endDateError = null);
    if (!_formKey.currentState!.validate()) return;
    if (_recurrenceMode == RecurrenceMode.every &&
        _endMode == EndMode.untilDate &&
        _endDate == null) {
      setState(() => _endDateError = 'Pick an end date');
      return;
    }
    if (_endDate != null &&
        _endDate!.isBefore(
          DateTime(_startDate.year, _startDate.month, _startDate.day),
        )) {
      setState(() => _endDateError = 'End date must be on or after start');
      return;
    }

    final draft = _draft(amount: Decimal.parse(_amount.text.trim())).copyWith(
      id: widget.existing?.id ?? const Uuid().v4(),
      accountId: widget.accountId,
      name: _name.text.trim(),
      direction: _direction,
      startDate: DateTime(_startDate.year, _startDate.month, _startDate.day),
      enabled: _enabled,
    );

    setState(() => _saving = true);
    try {
      final notifier = ref.read(transactionsProvider(widget.accountId).notifier);
      final Transaction saved;
      if (widget.existing == null) {
        saved = await notifier.create(draft);
      } else {
        await notifier.updateTransaction(draft);
        saved = draft;
      }
      if (mounted) Navigator.of(context).pop(saved);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is ApiException ? error.message : error.toString(),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

String _unitPlural(RecurrenceUnit unit, [int count = 2]) {
  final one = count == 1;
  return switch (unit) {
    RecurrenceUnit.days => one ? 'day' : 'days',
    RecurrenceUnit.weeks => one ? 'week' : 'weeks',
    RecurrenceUnit.months => one ? 'month' : 'months',
    RecurrenceUnit.years => one ? 'year' : 'years',
  };
}
