import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import 'money_text.dart';

/// New / edit account dialog (name, currency, seed balance + date, loss
/// threshold). Returns the edited account, not yet saved.
Future<Account?> showAccountDialog(
  BuildContext context, {
  required String projectId,
  Account? existing,
}) {
  return showDialog<Account>(
    context: context,
    builder: (context) =>
        AccountDialog(projectId: projectId, existing: existing),
  );
}

class AccountDialog extends StatefulWidget {
  const AccountDialog({super.key, required this.projectId, this.existing});

  final String projectId;
  final Account? existing;

  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<AccountDialog> {
  late final TextEditingController _name;
  late final TextEditingController _currency;
  late final TextEditingController _seedBalance;
  late final TextEditingController _lossThreshold;
  late DateTime _seedDate;
  String? _nameError;
  String? _currencyError;
  String? _balanceError;
  String? _lossError;

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
                helperText: 'Balances at or below this show in red',
                errorText: _lossError,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('account-save'),
          onPressed: _submit,
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

  void _submit() {
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
    );
    Navigator.of(context).pop(account);
  }
}
