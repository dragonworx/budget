import 'package:budget_formula/budget_formula.dart' show FieldSpec, fieldSpecs;
import 'package:budget_loan/budget_loan.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart' show ServerFeatures;
import '../../theme/app_theme.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/formula/formula_field.dart';
import '../timeline/occurrence_info.dart' show formatOccurrenceDate, ordinal;
import 'loan_models.dart';
import 'loan_offset_field.dart';
import 'rate_periods_editor.dart';

/// The loan editor's fields (spec 003 §5): interest type, Simple /
/// Advanced, the drawdown, term, repayments and (Advanced, reducing) the
/// charge schedule and rate periods. Edits [draft] in place and calls
/// [onChanged]; [errors] are the save-time messages by field.
class LoanForm extends StatefulWidget {
  const LoanForm({
    super.key,
    required this.draft,
    required this.onChanged,
    this.readOnly = false,
    this.errors = const {},
    this.principalFocus,
    this.onSubmit,
    this.streamId,
    this.canEditOffset = false,
  });

  /// The loan's stream (spec 004: the offset picker excludes it). Null
  /// hides the offset field.
  final String? streamId;

  /// Only the stream owner links or unlinks the offset account.
  final bool canEditOffset;

  final LoanDraft draft;
  final VoidCallback onChanged;
  final bool readOnly;

  /// Field key ("principal", "start", "term", "first", "chargeDay",
  /// "rate-<i>", "from-<i>", "other") → message.
  final Map<String, String> errors;
  final FocusNode? principalFocus;
  final VoidCallback? onSubmit;

  @override
  State<LoanForm> createState() => _LoanFormState();
}

/// The read-only charge line of Simple (reducing) mode, and its value in
/// Advanced: "Interest charged monthly on the 15th".
String chargeLine(LoanDraft d) {
  if (d.chargeSchedule == ChargeSchedule.onRepaymentDates) {
    return 'Interest charged on each repayment date';
  }
  return switch (d.chargeDay) {
    MonthEndChargeDay() => 'Interest charged monthly on the last day',
    DayOfMonthChargeDay(:final day) =>
      'Interest charged monthly on the ${ordinal(day)}',
    _ => 'Interest charged monthly on the ${ordinal(d.start.day)}',
  };
}

/// The flat plan box: "Total interest \$2,000.00 · 24 instalments of
/// \$83.33 (last \$83.41) · Repayment \$500.00 (final \$500.00) · About
/// 18.16% p.a. on a reducing balance".
String? flatPlanText(LoanDraft d) {
  final plan = d.flatPlanOrNull;
  final p = d.principalValue;
  if (plan == null || p == null || plan.dates.isEmpty) return null;
  final n = plan.dates.length;
  final each = plan.instalments.first;
  final last = plan.instalments.last;
  final eq = equivalentReducingRate(p, plan.repayment, n, d.frequency);
  return [
    'Total interest ${loanMoney(plan.totalInterest)}',
    '$n instalments of ${loanMoney(each)}'
        '${last != each ? ' (last ${loanMoney(last)})' : ''}',
    'Repayment ${loanMoney(plan.repayment)} '
        '(final ${loanMoney(plan.finalRepayment)})',
    'About ${eq.toStringAsFixed(2)}% p.a. on a reducing balance',
  ].join(' · ');
}

/// Why a field's text can't be saved yet: its error, or '…' while the
/// variables load (spec 013; null: it can).
String? formulaProblem(FormulaValue f) => f.pending ? '…' : f.message;

/// A loan rate field's result into [p] (spec 013): a formula keeps its
/// text and saves its resolved value; a plain rate stays as typed.
void applyRate(RatePeriodDraft p, FormulaValue f) {
  p.rate = f.isFormula ? (f.value?.toString() ?? '') : f.text;
  p.rateExpr = f.isFormula ? f.expr : null;
  p.rateFormulaText = f.isFormula ? f.text : null;
  p.rateProblem = f.isFormula ? formulaProblem(f) : null;
}

/// A rate controller for [p] (its formula when saved), flagged when the
/// server says that formula no longer resolves (row [i]).
FormulaEditingController rateController(LoanDraft d, RatePeriodDraft p, int i) {
  final c = FormulaEditingController(
    text: p.rateText,
    spec: fieldSpecs['loan.ratePct']!,
    formulasEnabled: ServerFeatures.variables,
  );
  if (p.rateExpr != null) {
    flagSavedError(
      c,
      d.exprErrors,
      'loan.ratePeriods.$i.ratePct',
      Decimal.tryParse(p.rate) ?? Decimal.zero,
    );
    if (c.formula.flagged) p.rateProblem = formulaProblem(c.formula);
  }
  return c;
}

class _LoanFormState extends State<LoanForm> {
  // Spec 013: every number here takes a formula; read `.formula`.
  late final FormulaEditingController _principal;
  late final FormulaEditingController _years;
  late final FormulaEditingController _months;
  late final FormulaEditingController _rate;
  late final FormulaEditingController _chargeDayNumber;
  String? _simpleBlocked;

  LoanDraft get d => widget.draft;

  static FormulaEditingController _ctl(String text, String spec) =>
      FormulaEditingController(
        text: text,
        spec: fieldSpecs[spec]!,
        formulasEnabled: ServerFeatures.variables,
      );

  @override
  void initState() {
    super.initState();
    _principal = _ctl(d.principalExpr ?? d.principal, 'loan.principal');
    _years = _ctl(d.termYearsExpr ?? '${d.termMonths ~/ 12}', 'loan.termYears');
    _months = _ctl(
      d.termMonthsExpr ?? '${d.termMonths % 12}',
      'loan.termMonths',
    );
    _rate = rateController(d, d.periods.first, 0);
    _chargeDayNumber = _ctl(
      d.chargeDayExpr ??
          switch (d.chargeDay) {
            DayOfMonthChargeDay(:final day) => '$day',
            _ => '${d.start.day}',
          },
      'loan.chargeDay',
    );
    // Saved formulas that no longer resolve (the server's exprErrors).
    final errors = d.exprErrors;
    if (d.principalExpr != null) {
      flagSavedError(
        _principal,
        errors,
        'amount',
        Decimal.tryParse(d.principal) ?? Decimal.zero,
      );
      d.principalProblem = _flagged(_principal);
    }
    if (d.termYearsExpr != null || d.termMonthsExpr != null) {
      final years = d.termYearsExpr != null;
      flagSavedError(
        years ? _years : _months,
        errors,
        'loan.term',
        Decimal.fromInt(years ? d.termMonths ~/ 12 : d.termMonths % 12),
      );
      if (years) {
        d.termYearsProblem = _flagged(_years);
      } else {
        d.termMonthsProblem = _flagged(_months);
      }
    }
    if (d.chargeDayExpr != null && d.chargeDay is DayOfMonthChargeDay) {
      flagSavedError(
        _chargeDayNumber,
        errors,
        'loan.chargeDay',
        Decimal.fromInt((d.chargeDay as DayOfMonthChargeDay).day),
      );
      d.chargeDayProblem = _flagged(_chargeDayNumber);
    }
  }

  static String? _flagged(FormulaEditingController c) =>
      c.formula.flagged ? formulaProblem(c.formula) : null;

  @override
  void dispose() {
    _principal.dispose();
    _years.dispose();
    _months.dispose();
    _rate.dispose();
    _chargeDayNumber.dispose();
    super.dispose();
  }

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  Future<DateTime?> _pickDate(DateTime initial, DateTime first) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(first) ? first : initial,
      firstDate: first,
      lastDate: DateTime(2150),
    );
    return picked == null
        ? null
        : DateTime(picked.year, picked.month, picked.day);
  }

  void _termChanged() {
    final yf = _years.formula, mf = _months.formula;
    // Empty counts as 0, as before (a plain number even out of range).
    final y = _years.typedInt ?? 0;
    final m = _months.typedInt ?? 0;
    d.termMonths = y * 12 + m;
    // The server adds the two texts up, so with a formula in either both
    // go (the plain one as its number).
    final any = yf.isFormula || mf.isFormula;
    d.termYearsExpr = any ? (yf.expr ?? '$y') : null;
    d.termMonthsExpr = any ? (mf.expr ?? '$m') : null;
    d.termYearsProblem = formulaProblem(yf);
    d.termMonthsProblem = formulaProblem(mf);
    _changed();
  }

  Future<void> _setType(InterestType t) async {
    if (t == d.interestType) return;
    if (t == InterestType.flat) {
      if (d.hasOffset) {
        // Spec 004: a flat-rate loan has no offset; unlink first.
        if (!widget.canEditOffset) {
          await showConfirmDialog(
            context,
            title: "Can't switch to a flat rate",
            message:
                'This loan has an offset account, and flat-rate loans '
                "can't. Only the stream owner can unlink it.",
            confirmLabel: 'OK',
            isDestructive: false,
          );
          return;
        }
        final ok = await showConfirmDialog(
          context,
          title: 'Unlink the offset account?',
          message:
              "Flat-rate loans can't have an offset account. Switching "
              'unlinks it.',
          confirmLabel: 'Unlink and switch',
          isDestructive: false,
        );
        if (!ok || !mounted) return;
        d.offsetStreamId = null;
      }
      final extra = d.periods.length - 1;
      if (extra > 0) {
        final ok = await showConfirmDialog(
          context,
          title: 'Switch to a flat rate?',
          message:
              'Flat-rate loans have one fixed rate. '
              '${extra == 1 ? 'The later rate change' : 'The $extra later rate changes'} '
              'will be removed.',
          confirmLabel: 'Switch',
          isDestructive: false,
        );
        if (!ok || !mounted) return;
      }
      d.interestType = InterestType.flat;
      d.mode = LoanMode.simple;
      d.periods = [
        d.periods.first
          ..type = RateType.fixed
          ..interestOnly = false
          ..offsetApplies = false,
      ];
    } else {
      // Back to reducing: the default schedule.
      d.interestType = InterestType.reducing;
      d.chargeSchedule = ChargeSchedule.monthly;
      d.chargeDay = const AnniversaryChargeDay();
      d.dayCount = DayCount.d365;
      d.periods.first.offsetApplies = true;
    }
    _rate.text = d.periods.first.rateText;
    _simpleBlocked = null;
    _changed();
  }

  void _setMode(LoanMode m) {
    if (m == d.mode) return;
    if (m == LoanMode.simple) {
      final why = d.simpleBlocker;
      if (why != null) {
        setState(() => _simpleBlocked = why);
        return;
      }
      _rate.text = d.periods.first.rateText;
    } else if (d.interestType != InterestType.flat) {
      // Simple mode applies the offset to the whole loan; keep that.
      d.periods.first.offsetApplies = true;
    }
    _simpleBlocked = null;
    d.mode = m;
    _changed();
  }

  String? _err(String k) => widget.errors[k];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flat = d.isFlat;
    final ro = widget.readOnly;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: AppTheme.textMuted,
    );
    final rowErrors = <int, Map<String, String>>{};
    for (final e in widget.errors.entries) {
      final m = RegExp(r'^(rate|from)-(\d+)$').firstMatch(e.key);
      if (m == null) continue;
      (rowErrors[int.parse(m.group(2)!)] ??= {})[m.group(1) == 'from'
              ? 'from'
              : 'rate'] =
          e.value;
    }
    final plan = flat ? flatPlanText(d) : null;

    return Column(
      key: const ValueKey('loan-form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _segmented<InterestType>(
          key: 'loan-interest-type',
          value: d.interestType,
          options: const {
            InterestType.reducing: 'Reducing balance',
            InterestType.flat: 'Flat rate',
          },
          onChanged: ro ? null : _setType,
        ),
        const SizedBox(height: 6),
        Text(
          flat
              ? 'Interest fixed when the loan starts, spread evenly over the '
                    'repayments'
              : 'Interest on what you still owe, worked out daily',
          style: small,
        ),
        const SizedBox(height: 12),
        _segmented<LoanMode>(
          key: 'loan-mode',
          value: d.mode,
          options: const {
            LoanMode.simple: 'Simple',
            LoanMode.advanced: 'Advanced',
          },
          onChanged: ro || flat ? null : _setMode,
        ),
        if (flat) ...[
          const SizedBox(height: 6),
          Text(
            'Flat-rate loans have one fixed rate',
            key: const ValueKey('loan-advanced-disabled'),
            style: small,
          ),
        ],
        if (_simpleBlocked != null) ...[
          const SizedBox(height: 6),
          Text(
            _simpleBlocked!,
            key: const ValueKey('loan-simple-blocked'),
            style: small?.copyWith(color: AppTheme.warning),
          ),
        ],
        const SizedBox(height: 14),
        _scoped(
          (scope) => FormulaField(
            key: const ValueKey('loan-principal'),
            spec: fieldSpecs['loan.principal']!,
            scope: scope,
            controller: _principal,
            focusNode: widget.principalFocus,
            enabled: !ro,
            label: 'Amount borrowed',
            prefixText: '\$ ',
            hintText: '0.00',
            errorText: _err('principal'),
            legacyKeyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => widget.onSubmit?.call(),
            onChanged: (f) {
              // Plain: the text as typed (as before); a formula: its value.
              d.principal = f.isFormula
                  ? (f.value?.toString() ?? '')
                  : _principal.text;
              d.principalExpr = f.isFormula ? f.expr : null;
              d.principalProblem = f.isFormula ? formulaProblem(f) : null;
              _changed();
            },
          ),
        ),
        const SizedBox(height: 12),
        _dateField(
          key: 'loan-start',
          label: 'Start (settlement) date',
          value: d.start,
          error: _err('start'),
          onTap: ro
              ? null
              : () async {
                  final p = await _pickDate(d.start, DateTime(1970));
                  if (p == null) return;
                  d.start = p;
                  d.periods.first.from = p;
                  d.sortPeriods();
                  _changed();
                },
        ),
        const SizedBox(height: 12),
        if (!d.advanced || flat)
          _scoped(
            (scope) => FormulaField(
              key: const ValueKey('loan-rate-0'),
              spec: fieldSpecs['loan.ratePct']!,
              scope: scope,
              controller: _rate,
              enabled: !ro,
              label: flat ? 'Flat rate % p.a.' : 'Interest rate % p.a.',
              suffixText: '%',
              errorText: _err('rate-0'),
              legacyKeyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              legacyFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
              ],
              onChanged: (f) {
                applyRate(d.periods.first, f);
                _changed();
              },
            ),
          ),
        if (!d.advanced || flat) const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _intField(
                key: 'loan-term-years',
                label: 'Term (years)',
                controller: _years,
                spec: 'loan.termYears',
                error: _err('term'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _intField(
                key: 'loan-term-months',
                label: 'Months',
                controller: _months,
                spec: 'loan.termMonths',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<RepaymentFrequency>(
          key: const ValueKey('loan-frequency'),
          initialValue: d.frequency,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Repayments'),
          items: [
            for (final f in RepaymentFrequency.values)
              DropdownMenuItem(value: f, child: Text(frequencyLabel(f))),
          ],
          onChanged: ro
              ? null
              : (f) {
                  if (f == null) return;
                  d.frequency = f;
                  // An explicit first repayment more than a period away
                  // no longer fits: back to the default.
                  final first = d.firstRepayment;
                  if (first != null && first.isAfter(d.periodAfter(d.start))) {
                    d.firstRepayment = null;
                  }
                  _changed();
                },
        ),
        const SizedBox(height: 12),
        _dateField(
          key: 'loan-first-repayment',
          label: 'First repayment',
          value: d.effectiveFirstRepayment,
          error: _err('first'),
          onTap: ro
              ? null
              : () async {
                  final p = await _pickDate(
                    d.effectiveFirstRepayment,
                    DateTime(d.start.year, d.start.month, d.start.day + 1),
                  );
                  if (p == null) return;
                  d.firstRepayment = p;
                  _changed();
                },
        ),
        if (!flat && !d.advanced) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  chargeLine(d),
                  key: const ValueKey('loan-charge-line'),
                  style: small,
                ),
              ),
              if (!ro)
                TextButton(
                  key: const ValueKey('loan-change-schedule'),
                  onPressed: () => _setMode(LoanMode.advanced),
                  child: const Text('Change'),
                ),
            ],
          ),
        ],
        if (!flat && d.advanced) ..._advanced(theme, small, rowErrors),
        if (flat) ...[
          const SizedBox(height: 12),
          Container(
            key: const ValueKey('loan-flat-plan'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan ?? 'Enter the amount, rate and term to see the plan',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  "Paying off early doesn't reduce the interest.",
                  style: small,
                ),
              ],
            ),
          ),
        ],
        if (!flat && widget.streamId != null) ...[
          const SizedBox(height: 16),
          LoanOffsetField(
            draft: d,
            loanStreamId: widget.streamId!,
            canEdit: !ro && widget.canEditOffset,
            onChanged: _changed,
          ),
        ],
        if (_err('other') case final e?) ...[
          const SizedBox(height: 10),
          Text(
            e,
            key: const ValueKey('loan-error'),
            style: small?.copyWith(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }

  List<Widget> _advanced(
    ThemeData theme,
    TextStyle? small,
    Map<int, Map<String, String>> rowErrors,
  ) {
    final ro = widget.readOnly;
    final dayValue = switch (d.chargeDay) {
      MonthEndChargeDay() => 'monthEnd',
      DayOfMonthChargeDay() => 'day',
      _ => 'anniversary',
    };
    return [
      const SizedBox(height: 16),
      Text('Rates', style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      RatePeriodsEditor(
        draft: d,
        streamId: widget.streamId,
        readOnly: ro,
        rowErrors: rowErrors,
        pickDate: _pickDate,
        onChanged: _changed,
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<ChargeSchedule>(
        key: const ValueKey('loan-charge-schedule'),
        initialValue: d.chargeSchedule,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Interest charged',
          helperText: "Interest compounds each time it's charged.",
        ),
        items: const [
          DropdownMenuItem(
            value: ChargeSchedule.monthly,
            child: Text('Monthly'),
          ),
          DropdownMenuItem(
            value: ChargeSchedule.onRepaymentDates,
            child: Text('On each repayment date'),
          ),
        ],
        onChanged: ro
            ? null
            : (v) {
                if (v == null) return;
                d.chargeSchedule = v;
                _changed();
              },
      ),
      if (d.chargeSchedule == ChargeSchedule.monthly) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const ValueKey('loan-charge-day'),
          initialValue: dayValue,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Charge day',
            errorText: _err('chargeDay'),
          ),
          items: [
            DropdownMenuItem(
              value: 'anniversary',
              child: Text('Loan anniversary (${ordinal(d.start.day)})'),
            ),
            const DropdownMenuItem(
              value: 'monthEnd',
              child: Text('Last day of month'),
            ),
            const DropdownMenuItem(value: 'day', child: Text('Day of month…')),
          ],
          onChanged: ro
              ? null
              : (v) {
                  d.chargeDay = switch (v) {
                    'monthEnd' => const MonthEndChargeDay(),
                    'day' => DayOfMonthChargeDay(
                      (_chargeDayNumber.typedInt ?? d.start.day).clamp(1, 31),
                    ),
                    _ => const AnniversaryChargeDay(),
                  };
                  _changed();
                },
        ),
        if (dayValue == 'day') ...[
          const SizedBox(height: 12),
          _scoped(
            (scope) => FormulaField(
              key: const ValueKey('loan-charge-day-number'),
              spec: fieldSpecs['loan.chargeDay']!,
              scope: scope,
              controller: _chargeDayNumber,
              enabled: !ro,
              label: 'Day of month (1–31)',
              helperText: 'Short months use their last day',
              legacyKeyboardType: TextInputType.number,
              legacyFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (f) {
                d.chargeDayExpr = f.isFormula ? f.expr : null;
                d.chargeDayProblem = formulaProblem(f);
                final n = _chargeDayNumber.typedInt;
                if (n == null || n < 1 || n > 31) {
                  // As before the day stays; the formula state still
                  // updates (Save is blocked by the problem).
                  if (f.isFormula) _changed();
                  return;
                }
                d.chargeDay = DayOfMonthChargeDay(n);
                _changed();
              },
            ),
          ),
        ],
      ],
      const SizedBox(height: 12),
      DropdownButtonFormField<DayCount>(
        key: const ValueKey('loan-day-count'),
        initialValue: d.dayCount,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Day count'),
        items: const [
          DropdownMenuItem(value: DayCount.d365, child: Text('365 days')),
          DropdownMenuItem(value: DayCount.actual, child: Text('Actual days')),
        ],
        onChanged: ro
            ? null
            : (v) {
                if (v == null) return;
                d.dayCount = v;
                _changed();
              },
      ),
    ];
  }

  Widget _segmented<T>({
    required String key,
    required T value,
    required Map<T, String> options,
    required ValueChanged<T>? onChanged,
  }) {
    return SegmentedButton<T>(
      key: ValueKey(key),
      showSelectedIcon: false,
      segments: [
        for (final e in options.entries)
          ButtonSegment(
            value: e.key,
            enabled: onChanged != null || e.key == value,
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(e.value, maxLines: 1, softWrap: false),
            ),
          ),
      ],
      selected: {value},
      onSelectionChanged: onChanged == null ? null : (s) => onChanged(s.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    );
  }

  /// [build] with the loan stream's variables (mine for a new stream).
  Widget _scoped(Widget Function(VariableScope scope) build) =>
      VariableScopeBuilder(
        streamId: widget.streamId,
        builder: (context, scope) => build(scope),
      );

  Widget _intField({
    required String key,
    required String label,
    required FormulaEditingController controller,
    required String spec,
    String? error,
  }) {
    final FieldSpec fieldSpec = fieldSpecs[spec]!;
    return _scoped(
      (scope) => FormulaField(
        key: ValueKey(key),
        spec: fieldSpec,
        scope: scope,
        controller: controller,
        enabled: !widget.readOnly,
        label: label,
        errorText: error,
        errorMaxLines: 2,
        // Empty is 0 (the other box may hold the whole term).
        allowEmpty: true,
        // Side by side: the value shows in the ✦ tooltip.
        previewInTooltip: true,
        legacyKeyboardType: TextInputType.number,
        legacyFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(3),
        ],
        onChanged: (_) => _termChanged(),
        extraValidator: (_) => d.termMonths < 1 || d.termMonths > 600
            ? 'A term of 1 month to 50 years'
            : null,
      ),
    );
  }

  Widget _dateField({
    required String key,
    required String label,
    required DateTime value,
    required VoidCallback? onTap,
    String? error,
  }) {
    return InkWell(
      key: ValueKey(key),
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          errorText: error,
          errorMaxLines: 2,
          suffixIcon: const Icon(Icons.calendar_month_rounded, size: 18),
        ),
        child: Text(formatOccurrenceDate(value)),
      ),
    );
  }
}
