import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import 'money_text.dart';
import '../theme/app_theme.dart';

/// New / edit pool dialog (name, seed balance + date, loss
/// threshold). Returns the edited pool, not yet saved — unless [onSave]
/// is given: then Save runs it inside the dialog (staying open with the error
/// shown if it throws) and returns its result.
Future<Pool?> showPoolDialog(
  BuildContext context, {
  Pool? existing,
  Future<Pool> Function(Pool draft)? onSave,
  int? transactionCount,
}) {
  return showDialog<Pool>(
    context: context,
    builder: (context) => PoolDialog(
      existing: existing,
      onSave: onSave,
      transactionCount: transactionCount,
    ),
  );
}

class PoolDialog extends StatefulWidget {
  const PoolDialog({
    super.key,
    this.existing,
    this.onSave,
    this.transactionCount,
  });

  /// Transactions in the pool (for the seed-move note); defaults to the
  /// pool's transaction order length.
  final int? transactionCount;

  final Pool? existing;
  final Future<Pool> Function(Pool draft)? onSave;

  @override
  State<PoolDialog> createState() => _PoolDialogState();
}

class _PoolDialogState extends State<PoolDialog> {
  /// "All N transactions will move by X days" when editing and the seed
  /// date changed (the server shifts every schedule by the same delta).
  String? _seedMoveNote() {
    final existing = widget.existing;
    if (existing == null) return null;
    final delta = seedShiftDays(existing.seedDate, _seedDate);
    if (delta == 0) return null;
    final n = widget.transactionCount ?? existing.transactionOrder.length;
    if (n == 0) return null;
    final days = '${delta.abs()} day${delta.abs() == 1 ? '' : 's'}';
    final dir = delta > 0 ? 'later' : 'earlier';
    final what = n == 1 ? 'The 1 transaction' : 'All $n transactions';
    return '$what will move $days $dir';
  }

  late final TextEditingController _name;
  late final TextEditingController _seedBalance;
  late final TextEditingController _lossThreshold;
  late DateTime _seedDate;

  /// New pools start at Hundreds ([Pool.defaultCurrencyScale]).
  late int _currencyScale;
  String? _nameError;
  String? _balanceError;
  String? _lossError;

  String? _saveError;
  bool _saving = false;

  /// After the first Save attempt, errors update as you type.
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _seedBalance = TextEditingController(
      text: existing?.seedBalance.toString() ?? '0',
    );
    _lossThreshold = TextEditingController(
      text: existing?.lossThreshold.toString() ?? '0',
    );
    _seedDate = existing?.seedDate ?? DateTime.now();
    _currencyScale = existing?.currencyScale ?? Pool.defaultCurrencyScale;
  }

  @override
  void dispose() {
    _name.dispose();
    _seedBalance.dispose();
    _lossThreshold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New pool' : 'Edit pool'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('pool-name'),
              controller: _name,
              onChanged: _revalidate,
              onSubmitted: (_) => _submit(),
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Name',
                errorText: _nameError,
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('pool-seed'),
              controller: _seedBalance,
              onChanged: _revalidate,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Seed balance',
                prefixText: '$moneySymbol ',
                helperText: 'Balance on the seed date, before any transactions',
                errorText: _balanceError,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('pool-threshold'),
              controller: _lossThreshold,
              onChanged: _revalidate,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Alert threshold',
                prefixText: '$moneySymbol ',
                helperText: 'Balances below this show in red',
                errorText: _lossError,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: ValueKey('pool-currency-scale-$_currencyScale'),
              initialValue: _currencyScale,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Currency Scale',
                helperText: 'Sets the timeline\'s default vertical view',
              ),
              items: [
                for (final e in Pool.currencyScales.entries)
                  DropdownMenuItem(
                    key: ValueKey('currency-scale-${e.key}'),
                    value: e.key,
                    child: Text(e.value),
                  ),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() => _currencyScale = v);
                }
              },
            ),
            const SizedBox(height: 12),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _seedDate,
                  firstDate: DateTime(1970),
                  lastDate: DateTime(2100),
                  helpText: 'Seed date',
                );
                if (picked != null) setState(() => _seedDate = picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Seed date',
                  helperText: 'The balance starts from this day',
                  suffixIcon: Icon(Icons.calendar_month_rounded, size: 18),
                ),
                child: Text(DateFormat('EEE d MMM y').format(_seedDate)),
              ),
            ),
            if (_seedMoveNote() case final note?)
              Padding(
                key: const ValueKey('seed-move-note'),
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.swap_horiz_rounded,
                      size: 16,
                      color: AppTheme.accent,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        note,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _saveError!,
              key: const ValueKey('pool-save-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('pool-save'),
          onPressed: _saving ? null : _submit,
          child: Text(widget.existing == null ? 'Create pool' : 'Save'),
        ),
      ],
    );
  }

  /// Validates every field; returns whether all are valid.
  bool _validate() {
    final lossText = _lossThreshold.text.trim();
    setState(() {
      _nameError = _name.text.trim().isEmpty ? 'Enter a name' : null;
      _balanceError = parseMoneyInput(_seedBalance.text) == null
          ? 'Enter an amount, e.g. 2500 or -120.50'
          : null;
      _lossError = lossText.isEmpty || parseMoneyInput(lossText) != null
          ? null
          : 'Enter an amount, e.g. 200 (or leave empty for 0)';
    });
    return _nameError == null && _balanceError == null && _lossError == null;
  }

  void _revalidate(String _) {
    if (_submitted) {
      _validate();
    }
  }

  Future<void> _submit() async {
    _submitted = true;
    if (!_validate()) return;
    final name = _name.text.trim();
    final balance = parseMoneyInput(_seedBalance.text)!;
    final lossText = _lossThreshold.text.trim();
    final lossThreshold = lossText.isEmpty
        ? Decimal.zero
        : parseMoneyInput(lossText)!;
    final existing = widget.existing;
    final pool = Pool(
      id: existing?.id ?? '',
      ownerId: existing?.ownerId ?? '',
      name: name,
      seedBalance: balance,
      seedDate: _seedDate,
      lossThreshold: lossThreshold,
      transactionOrder: existing?.transactionOrder ?? const [],
      displayOrder: existing?.displayOrder ?? 0,
      currencyScale: _currencyScale,
      version: existing?.version,
      role: existing?.role ?? Role.owner,
    );
    final onSave = widget.onSave;
    if (onSave == null) {
      Navigator.of(context).pop(pool);
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final saved = await onSave(pool);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Couldn’t save: $error';
      });
    }
  }
}

/// Calendar days from [from] to [to] (date parts only, DST safe).
int seedShiftDays(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
