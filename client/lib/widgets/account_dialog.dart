import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import 'money_text.dart';
import '../theme/app_theme.dart';

/// New / edit account dialog (name, currency, seed balance + date, loss
/// threshold). Returns the edited account, not yet saved — unless [onSave]
/// is given: then Save runs it inside the dialog (staying open with the error
/// shown if it throws) and returns its result.
Future<Account?> showAccountDialog(
  BuildContext context, {
  required String projectId,
  Account? existing,
  Future<Account> Function(Account draft)? onSave,
  int? transactionCount,
}) {
  return showDialog<Account>(
    context: context,
    builder: (context) => AccountDialog(
      projectId: projectId,
      existing: existing,
      onSave: onSave,
      transactionCount: transactionCount,
    ),
  );
}

class AccountDialog extends StatefulWidget {
  const AccountDialog({
    super.key,
    required this.projectId,
    this.existing,
    this.onSave,
    this.transactionCount,
  });

  /// Transactions in the account (for the seed-move note); defaults to the
  /// account's transaction order length.
  final int? transactionCount;

  final String projectId;
  final Account? existing;
  final Future<Account> Function(Account draft)? onSave;

  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<AccountDialog> {
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
  late final TextEditingController _currency;
  late final TextEditingController _seedBalance;
  late final TextEditingController _lossThreshold;
  late DateTime _seedDate;

  /// New accounts start at Hundreds ([Account.defaultCurrencyScale]).
  late int _currencyScale;
  String? _nameError;
  String? _currencyError;
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
    _currency = TextEditingController(
      text:
          existing?.currency ??
          (NumberFormat.simpleCurrency().currencyName ?? 'USD'),
    );
    _seedBalance = TextEditingController(
      text: existing?.seedBalance.toString() ?? '0',
    );
    _lossThreshold = TextEditingController(
      text: existing?.lossThreshold.toString() ?? '0',
    );
    _seedDate = existing?.seedDate ?? DateTime.now();
    _currencyScale = existing?.currencyScale ?? Account.defaultCurrencyScale;
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
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('account-name'),
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
              key: const ValueKey('account-currency'),
              controller: _currency,
              onChanged: _revalidate,
              onSubmitted: (_) => _submit(),
              maxLength: 3,
              decoration: InputDecoration(
                labelText: 'Currency',
                helperText: '3-letter code, e.g. AUD, USD, EUR',
                errorText: _currencyError,
                counterText: '',
              ),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('account-seed'),
              controller: _seedBalance,
              onChanged: _revalidate,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Seed balance',
                prefixText: '${_symbol()} ',
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
              key: const ValueKey('account-threshold'),
              controller: _lossThreshold,
              onChanged: _revalidate,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Alert threshold',
                prefixText: '${_symbol()} ',
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
              key: ValueKey('account-currency-scale-$_currencyScale'),
              initialValue: _currencyScale,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Currency Scale',
                helperText: 'Sets the timeline\'s default vertical view',
              ),
              items: [
                for (final e in Account.currencyScales.entries)
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
              key: const ValueKey('account-save-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('account-save'),
          onPressed: _saving ? null : _submit,
          child: Text(widget.existing == null ? 'Create account' : 'Save'),
        ),
      ],
    );
  }

  String _symbol() {
    final code = _currency.text.trim().toUpperCase();
    return code.length == 3 ? MoneyText.symbolFor(code).trim() : '';
  }

  /// Validates every field; returns whether all are valid.
  bool _validate() {
    final currency = _currency.text.trim().toUpperCase();
    final lossText = _lossThreshold.text.trim();
    setState(() {
      _nameError = _name.text.trim().isEmpty ? 'Enter a name' : null;
      _currencyError = RegExp(r'^[A-Z]{3}$').hasMatch(currency)
          ? null
          : 'Use a 3-letter code, e.g. AUD';
      _balanceError = parseMoneyInput(_seedBalance.text) == null
          ? 'Enter an amount, e.g. 2500 or -120.50'
          : null;
      _lossError = lossText.isEmpty || parseMoneyInput(lossText) != null
          ? null
          : 'Enter an amount, e.g. 200 (or leave empty for 0)';
    });
    return _nameError == null &&
        _currencyError == null &&
        _balanceError == null &&
        _lossError == null;
  }

  void _revalidate(String _) {
    if (_submitted) {
      _validate();
    } else {
      setState(() {}); // refresh the currency prefix
    }
  }

  Future<void> _submit() async {
    _submitted = true;
    if (!_validate()) return;
    final name = _name.text.trim();
    final currency = _currency.text.trim().toUpperCase();
    final balance = parseMoneyInput(_seedBalance.text)!;
    final lossText = _lossThreshold.text.trim();
    final lossThreshold = lossText.isEmpty
        ? Decimal.zero
        : parseMoneyInput(lossText)!;
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
      currencyScale: _currencyScale,
      version: existing?.version,
      role: existing?.role ?? Role.owner,
    );
    final onSave = widget.onSave;
    if (onSave == null) {
      Navigator.of(context).pop(account);
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final saved = await onSave(account);
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
