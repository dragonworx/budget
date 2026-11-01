import 'package:budget_formula/budget_formula.dart' show fieldSpecs;
import 'package:budget_loan/budget_loan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../widgets/formula/formula_field.dart';
import 'loan_form.dart' show applyRate, rateController;
import 'loan_models.dart';
import 'repayment_helpers.dart';

/// Advanced mode's rate periods (spec 003 §5): one row per period with
/// its start, rate, fixed / variable, interest only and offset (disabled
/// until offset accounts, spec 004). The first row starts on the loan's
/// start date (locked). Rows sort by date when a date is picked; stacked
/// cards below 600px.
class RatePeriodsEditor extends StatefulWidget {
  const RatePeriodsEditor({
    super.key,
    required this.draft,
    required this.onChanged,
    this.readOnly = false,
    this.rowErrors = const {},
    required this.pickDate,
    this.streamId,
  });

  final LoanDraft draft;

  /// The loan's stream, for the rate formulas' variables (null: mine).
  final String? streamId;
  final VoidCallback onChanged;
  final bool readOnly;

  /// Engine / server errors by row ("from" or "rate" → message).
  final Map<int, Map<String, String>> rowErrors;
  final Future<DateTime?> Function(DateTime initial, DateTime first) pickDate;

  @override
  State<RatePeriodsEditor> createState() => _RatePeriodsEditorState();
}

/// Local checks on a row's start: after the loan start, before the term
/// end, not the same as another row's (null: fine).
String? ratePeriodDateError(LoanDraft d, int i) {
  if (i == 0) return null;
  final from = d.periods[i].from;
  if (!from.isAfter(d.start)) return 'Must be after the loan start';
  if (!from.isBefore(d.termEnd)) {
    return 'Must be before the term end ${loanDate(d.termEnd)}';
  }
  for (var j = 0; j < d.periods.length; j++) {
    if (j != i && d.periods[j].from == from) {
      return 'Another rate change starts on this date';
    }
  }
  return null;
}

/// A typed rate's problem (null: a valid 0–100 with ≤ 4 decimals).
String? rateTextError(String text) {
  final t = text.trim();
  if (t.isEmpty) return 'Enter a rate';
  if (!RegExp(r'^\d{1,3}(\.\d{1,4})?$').hasMatch(t)) {
    return 'A number like 6.4 (up to 4 decimals)';
  }
  if (double.parse(t) > 100) return 'At most 100%';
  return null;
}

class _RatePeriodsEditorState extends State<RatePeriodsEditor> {
  final _rates = <RatePeriodDraft, FormulaEditingController>{};

  /// Each period's rate takes a formula (spec 013): read `.formula`.
  FormulaEditingController _rateFor(RatePeriodDraft p, int i) =>
      _rates.putIfAbsent(p, () => rateController(d, p, i));

  @override
  void dispose() {
    for (final c in _rates.values) {
      c.dispose();
    }
    super.dispose();
  }

  LoanDraft get d => widget.draft;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  void _add() {
    final last = d.periods.last;
    var from = addMonthsSafe(last.from, 12);
    if (!from.isBefore(d.termEnd)) {
      from = DateTime(d.termEnd.year, d.termEnd.month, d.termEnd.day - 1);
    }
    d.periods.add(
      RatePeriodDraft(
        from: from,
        rate: last.rate,
        rateExpr: last.rateExpr,
        rateFormulaText: last.rateFormulaText,
        rateProblem: last.rateProblem,
        type: last.type,
        // Spec 004 §15: fixed periods default unchecked, variable checked.
        offsetApplies: last.type == RateType.variable,
      ),
    );
    d.sortPeriods();
    _changed();
  }

  void _remove(int i) {
    final p = d.periods.removeAt(i);
    _rates.remove(p)?.dispose();
    _changed();
  }

  Future<void> _pick(int i) async {
    final p = d.periods[i];
    final picked = await widget.pickDate(
      p.from,
      DateTime(d.start.year, d.start.month, d.start.day + 1),
    );
    if (picked == null || !mounted) return;
    p.from = picked;
    d.sortPeriods();
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 600;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, p) in d.periods.indexed) ...[
              _row(theme, i, p, wide),
              const SizedBox(height: 8),
            ],
            if (!widget.readOnly)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('loan-add-rate'),
                  onPressed: d.periods.length >= 120 ? null : _add,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add rate change'),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _row(ThemeData theme, int i, RatePeriodDraft p, bool wide) {
    final errors = widget.rowErrors[i] ?? const {};
    final dateError = ratePeriodDateError(d, i) ?? errors['from'];
    final rateCtl = _rateFor(p, i);
    if (rateCtl.text != p.rateText) rateCtl.text = p.rateText;
    final from = InkWell(
      key: ValueKey('loan-rate-from-$i'),
      borderRadius: BorderRadius.circular(10),
      onTap: i == 0 || widget.readOnly ? null : () => _pick(i),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: i == 0 ? 'From (loan start)' : 'From',
          errorText: dateError,
          errorMaxLines: 2,
          isDense: true,
          suffixIcon: i == 0
              ? const Icon(Icons.lock_outline_rounded, size: 16)
              : const Icon(Icons.calendar_month_rounded, size: 18),
        ),
        child: Text(loanDate(i == 0 ? d.start : p.from), maxLines: 1),
      ),
    );
    final rate = VariableScopeBuilder(
      streamId: widget.streamId,
      builder: (context, scope) => FormulaField(
        key: ValueKey('loan-rate-$i'),
        spec: fieldSpecs['loan.ratePct']!,
        scope: scope,
        controller: rateCtl,
        enabled: !widget.readOnly,
        label: 'Rate % p.a.',
        suffixText: '%',
        dense: true,
        // A narrow box: the value shows in the ✦ tooltip.
        previewInTooltip: true,
        errorText: errors['rate'],
        errorMaxLines: 2,
        legacyKeyboardType: const TextInputType.numberWithOptions(
          decimal: true,
        ),
        legacyFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
        onChanged: (f) {
          applyRate(p, f);
          widget.onChanged();
        },
      ),
    );
    final type = DropdownButtonFormField<RateType>(
      key: ValueKey('loan-rate-type-$i'),
      initialValue: p.type,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Type', isDense: true),
      items: const [
        DropdownMenuItem(value: RateType.fixed, child: Text('Fixed')),
        DropdownMenuItem(value: RateType.variable, child: Text('Variable')),
      ],
      onChanged: widget.readOnly
          ? null
          : (v) {
              if (v == null) return;
              if (v != p.type) p.offsetApplies = v == RateType.variable;
              p.type = v;
              _changed();
            },
    );
    final io = _check(
      key: 'loan-rate-io-$i',
      label: 'Interest only',
      value: p.interestOnly,
      onChanged: widget.readOnly
          ? null
          : (v) {
              p.interestOnly = v;
              _changed();
            },
    );
    // Spec 004: active once an offset account is linked.
    final linked = d.hasOffset;
    final offset = Tooltip(
      message: linked
          ? 'The offset account reduces the interest in this period'
          : 'Link an offset account to use this',
      child: _check(
        key: 'loan-rate-offset-$i',
        label: 'Offset applies',
        value: p.offsetApplies,
        onChanged: widget.readOnly || !linked
            ? null
            : (v) {
                p.offsetApplies = v;
                _changed();
              },
      ),
    );
    final delete = i == 0 || widget.readOnly
        ? const SizedBox(width: 40)
        : IconButton(
            key: ValueKey('loan-rate-delete-$i'),
            tooltip: 'Remove this rate change',
            onPressed: () => _remove(i),
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
          );
    if (wide) {
      return Row(
        key: ObjectKey(p),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: from),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: rate),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: type),
          const SizedBox(width: 4),
          io,
          offset,
          delete,
        ],
      );
    }
    return Container(
      key: ObjectKey(p),
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: from),
              delete,
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: rate),
              const SizedBox(width: 8),
              Expanded(child: type),
              const SizedBox(width: 6),
            ],
          ),
          Wrap(children: [io, offset]),
        ],
      ),
    );
  }

  Widget _check({
    required String key,
    required String label,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return InkWell(
      key: ValueKey(key),
      borderRadius: BorderRadius.circular(8),
      onTap: onChanged == null ? null : () => onChanged(!value),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: value,
              onChanged: onChanged == null ? null : (v) => onChanged(v!),
            ),
            Text(
              label,
              style: TextStyle(
                color: onChanged == null ? AppTheme.textFaint : AppTheme.text,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}
