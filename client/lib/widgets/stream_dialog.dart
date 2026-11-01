import '../features/loans/loan_display.dart';

import 'dart:async';

import 'package:budget_formula/budget_formula.dart' show fieldSpecs;
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart';
import '../data/models.dart';
import 'formula/formula_field.dart';
import 'money_text.dart';
import '../theme/app_theme.dart';

/// New / edit stream dialog (name, seed balance + date, loss
/// threshold; Currency Scale only when editing: new streams start at
/// Hundreds). Opening it new focuses Name and, on touch, raises the
/// keyboard (see [primeSoftKeyboard]). Returns the edited stream, not yet saved — unless [onSave]
/// is given: then Save runs it inside the dialog (staying open with the error
/// shown if it throws) and returns its result.
Future<BudgetStream?> showStreamDialog(
  BuildContext context, {
  BudgetStream? existing,
  Future<BudgetStream> Function(BudgetStream draft)? onSave,
  int? eventCount,
}) {
  // Still inside the tap: lets iOS / Android web raise the keyboard for
  // the Name field that focuses once the dialog is built.
  if (existing == null) primeSoftKeyboard();
  return showDialog<BudgetStream>(
    context: context,
    builder: (context) => StreamDialog(
      existing: existing,
      onSave: onSave,
      eventCount: eventCount,
    ),
  );
}

class StreamDialog extends StatefulWidget {
  const StreamDialog({super.key, this.existing, this.onSave, this.eventCount});

  /// Events in the stream (for the seed-move note); defaults to the
  /// stream's event order length.
  final int? eventCount;

  final BudgetStream? existing;
  final Future<BudgetStream> Function(BudgetStream draft)? onSave;

  @override
  State<StreamDialog> createState() => _StreamDialogState();
}

class _StreamDialogState extends State<StreamDialog> {
  /// "All N events will move by X days" when editing and the seed
  /// date changed (the server shifts every schedule by the same delta).
  String? _seedMoveNote() {
    final existing = widget.existing;
    if (existing == null) return null;
    final delta = seedShiftDays(existing.seedDate, _seedDate);
    if (delta == 0) return null;
    final n = widget.eventCount ?? existing.eventOrder.length;
    if (n == 0) return null;
    final days = '${delta.abs()} day${delta.abs() == 1 ? '' : 's'}';
    final dir = delta > 0 ? 'later' : 'earlier';
    final what = n == 1 ? 'The 1 event' : 'All $n events';
    return '$what will move $days $dir';
  }

  late final TextEditingController _name;

  /// Seed and threshold take formulas (spec 013): read
  /// [FormulaEditingController.formula], not the text.
  late final FormulaEditingController _seedBalance;
  late final FormulaEditingController _lossThreshold;
  late DateTime _seedDate;

  /// New streams start at Hundreds ([Stream.defaultCurrencyScale]); only
  /// Edit stream (Stream settings) offers the picker.
  late int _currencyScale;
  final _nameFocus = FocusNode(debugLabel: 'stream-name');
  Timer? _refocus;
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
    final on = ServerFeatures.variables;
    _seedBalance = FormulaEditingController(
      text:
          (on ? existing?.seedBalanceExpr : null) ??
          existing?.seedBalance.toString() ??
          '0',
      spec: fieldSpecs['stream.seed']!,
      formulasEnabled: on,
    );
    _lossThreshold = FormulaEditingController(
      text:
          (on ? existing?.lossThresholdExpr : null) ??
          existing?.lossThreshold.toString() ??
          '0',
      spec: fieldSpecs['stream.threshold']!,
      formulasEnabled: on,
    );
    if (on && existing != null) {
      if (existing.seedBalanceExpr != null) {
        flagSavedError(
          _seedBalance,
          existing.exprErrors,
          'seedBalance',
          existing.seedBalance,
        );
      }
      if (existing.lossThresholdExpr != null) {
        flagSavedError(
          _lossThreshold,
          existing.exprErrors,
          'lossThreshold',
          existing.lossThreshold,
        );
      }
    }
    _seedDate = existing?.seedDate ?? DateTime.now();
    _currencyScale =
        existing?.currencyScale ?? BudgetStream.defaultCurrencyScale;
    // New: Name again once the dialog has animated in, unless focus has
    // already moved inside it (a closing menu restores its own focus).
    if (existing == null) {
      _refocus = Timer(streamNameRefocusDelay, () {
        if (!mounted || _nameFocus.hasFocus) return;
        final primary = FocusManager.instance.primaryFocus;
        final ctx = primary?.context;
        final inDialog =
            ctx != null &&
            ctx.findAncestorStateOfType<_StreamDialogState>() == this;
        if (!inDialog) _nameFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _refocus?.cancel();
    _nameFocus.dispose();
    _name.dispose();
    _seedBalance.dispose();
    _lossThreshold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New stream' : 'Edit stream'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('stream-name'),
              controller: _name,
              focusNode: _nameFocus,
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
            // The owner's variables; a new stream is mine.
            VariableScopeBuilder(
              streamId: widget.existing?.id,
              builder: (context, scope) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FormulaField(
                    key: const ValueKey('stream-seed'),
                    spec: fieldSpecs['stream.seed']!,
                    scope: scope,
                    controller: _seedBalance,
                    label: 'Seed balance',
                    prefixText: '$moneySymbol ',
                    helperText: 'Balance on the seed date, before any events',
                    errorText: _balanceError,
                    // Errors show after the first Save, then live (below).
                    autovalidateMode: AutovalidateMode.disabled,
                    legacyKeyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => _revalidate(''),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 12),
                  FormulaField(
                    key: const ValueKey('stream-threshold'),
                    spec: fieldSpecs['stream.threshold']!,
                    scope: scope,
                    controller: _lossThreshold,
                    label: 'Alert threshold',
                    prefixText: '$moneySymbol ',
                    helperText: widget.existing?.hasLoan ?? false
                        ? loanThresholdHelper
                        : thresholdHelper(widget.existing),
                    helperMaxLines: 3,
                    errorText: _lossError,
                    autovalidateMode: AutovalidateMode.disabled,
                    legacyKeyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => _revalidate(''),
                    onSubmitted: (_) => _submit(),
                  ),
                ],
              ),
            ),
            if (widget.existing != null) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: ValueKey('stream-currency-scale-$_currencyScale'),
                initialValue: _currencyScale,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Currency Scale',
                  helperText: 'Sets the timeline\'s default vertical view',
                ),
                items: [
                  for (final e in BudgetStream.currencyScales.entries)
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
            ],
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
              key: const ValueKey('stream-save-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('stream-save'),
          onPressed: _saving ? null : _submit,
          child: Text(widget.existing == null ? 'Create stream' : 'Save'),
        ),
      ],
    );
  }

  /// Validates every field; returns whether all are valid.
  bool _validate() {
    final seed = _seedBalance.formula, loss = _lossThreshold.formula;
    setState(() {
      _nameError = _name.text.trim().isEmpty ? 'Enter a name' : null;
      // The specs carry today's messages (blank threshold = 0).
      _balanceError = seed.message;
      _lossError = loss.message;
    });
    return _nameError == null &&
        _balanceError == null &&
        _lossError == null &&
        seed.value != null &&
        loss.value != null;
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
    final balance = _seedBalance.formula.value!;
    final lossThreshold = _lossThreshold.formula.value ?? Decimal.zero;
    final existing = widget.existing;
    final stream = BudgetStream(
      id: existing?.id ?? '',
      ownerId: existing?.ownerId ?? '',
      name: name,
      seedBalance: balance,
      seedDate: _seedDate,
      lossThreshold: lossThreshold,
      seedBalanceExpr: _seedBalance.formula.expr,
      lossThresholdExpr: _lossThreshold.formula.expr,
      eventOrder: existing?.eventOrder ?? const [],
      displayOrder: existing?.displayOrder ?? 0,
      currencyScale: _currencyScale,
      version: existing?.version,
      role: existing?.role ?? Role.owner,
    );
    final onSave = widget.onSave;
    if (onSave == null) {
      Navigator.of(context).pop(stream);
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final saved = await onSave(stream);
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

/// How long after opening a new stream's dialog Name is refocused if
/// something took the focus away.
const Duration streamNameRefocusDelay = Duration(milliseconds: 400);

/// Calendar days from [from] to [to] (date parts only, DST safe).
int seedShiftDays(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// The alert threshold's helper; on an offset account (spec 004) it is
/// also the zero the loan's offset counts from.
String thresholdHelper(BudgetStream? stream) {
  const base = 'Balances below this show in red';
  final loans = stream?.offsetFor ?? const <OffsetLinkRef>[];
  if (loans.isEmpty) return base;
  final names = [
    for (final l in loans)
      l.visible && l.name != null ? l.name! : 'a loan not shared with you',
  ];
  return '$base. Also the zero for the offset on ${names.join(', ')}';
}
