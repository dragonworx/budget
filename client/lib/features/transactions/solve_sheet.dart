import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/frequency.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';

/// Opens the transaction planner. Any values in [initial] are treated as known.
///
/// With [saveOnCommit] the solved transaction is created and returned; otherwise
/// the unsaved solved transaction is returned for the caller to apply.
Future<SolveResult?> showSolveSheet(
  BuildContext context, {
  required String accountId,
  DateTime? startDate,
  DateTime? endDate,
  SolveRequest? initial,
  bool saveOnCommit = true,
}) {
  return showModalBottomSheet<SolveResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SolveSheet(
          accountId: accountId,
          initial:
              initial ??
              defaultPlanRequest(startDate: startDate, endDate: endDate),
          creditOnly: initial == null,
          saveOnCommit: saveOnCommit,
        ),
      );
    },
  );
}

/// The planner's starting point: a weekly credit, nothing else known.
SolveRequest defaultPlanRequest({DateTime? startDate, DateTime? endDate}) =>
    SolveRequest(
      name: 'Planned income',
      direction: TransactionDirection.credit,
      unit: RecurrenceUnit.weeks,
      startDate: startDate,
      endDate: endDate,
    );

class SolveSheet extends ConsumerStatefulWidget {
  const SolveSheet({
    super.key,
    required this.accountId,
    required this.initial,
    this.saveOnCommit = true,
    this.creditOnly = false,
    this.onPreview,
    this.onDone,
    this.readOnly = false,
  });

  /// Embedded (panel) use: called with the would-be transaction whenever
  /// the plan is fully solved, or null when it is not.
  final ValueChanged<Transaction?>? onPreview;

  /// Embedded use: called instead of popping the route after a commit.
  final ValueChanged<SolveResult>? onDone;

  /// Viewer access: solve only, no "Create transaction".
  final bool readOnly;
  final String accountId;
  final SolveRequest initial;
  final bool saveOnCommit;

  /// The Plan feature: always a credit, no direction choice.
  final bool creditOnly;

  @override
  ConsumerState<SolveSheet> createState() => _SolveSheetState();
}

class _SolveSheetState extends ConsumerState<SolveSheet> {
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _total;
  late final TextEditingController _targetBalance;
  final TextEditingController _balanceTotal = TextEditingController();
  late final TextEditingController _interval;
  late final TextEditingController _count;
  late TransactionDirection _direction;
  late RecurrenceUnit _unit;
  late RoundingMode _rounding;
  DateTime? _startDate;
  DateTime? _endDate;

  Timer? _debounce;
  int _requestSeq = 0;
  bool _solving = false;
  bool _saving = false;
  SolveResult? _result;
  String? _error;

  /// Blank fields filled with a default (start today, every 1) because
  /// nothing else determines them; shown as auto like calculated fields.
  Set<SolveVar> _defaulted = const {};

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _name = TextEditingController(text: i.name);
    _amount = TextEditingController(text: i.amount?.toString() ?? '');
    _total = TextEditingController(text: i.targetTotal?.toString() ?? '');
    _targetBalance = TextEditingController(
      text: i.targetBalance?.toString() ?? '',
    );
    _interval = TextEditingController(text: i.interval?.toString() ?? '');
    _count = TextEditingController(text: i.occurrenceCount?.toString() ?? '');
    _direction = widget.creditOnly ? TransactionDirection.credit : i.direction;
    _unit = i.unit;
    _rounding = i.rounding;
    _startDate = i.startDate;
    _endDate = i.endDate;
    final typed = int.tryParse(_interval.text.trim());
    _freqCustom =
        typed != null &&
        FrequencyPreset.of(once: false, interval: typed, unit: _unit) ==
            FrequencyPreset.custom;
    _scheduleSolve(immediate: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _amount.dispose();
    _total.dispose();
    _targetBalance.dispose();
    _balanceTotal.dispose();
    _interval.dispose();
    _count.dispose();
    super.dispose();
  }

  // --- Input parsing -------------------------------------------------------

  Decimal? _parseMoney(TextEditingController c) =>
      Decimal.tryParse(c.text.trim());

  int? _parseInt(TextEditingController c) => int.tryParse(c.text.trim());

  String? _moneyError(TextEditingController c) {
    final raw = c.text.trim();
    if (raw.isEmpty) return null;
    final v = Decimal.tryParse(raw);
    if (v == null) return 'Invalid amount';
    if (v <= Decimal.zero) return 'Must be > 0';
    return null;
  }

  /// A target balance may be any amount (even zero or negative).
  String? _balanceError(TextEditingController c) {
    final raw = c.text.trim();
    if (raw.isEmpty) return null;
    return Decimal.tryParse(raw) == null ? 'Invalid amount' : null;
  }

  bool get _balanceMode => _targetBalance.text.trim().isNotEmpty;

  String? _intError(TextEditingController c) {
    final raw = c.text.trim();
    if (raw.isEmpty) return null;
    final v = int.tryParse(raw);
    if (v == null || v < 1) return 'Whole number ≥ 1';
    return null;
  }

  bool get _hasInputErrors =>
      _moneyError(_amount) != null ||
      _moneyError(_total) != null ||
      _balanceError(_targetBalance) != null ||
      _intError(_interval) != null ||
      _intError(_count) != null;

  SolveRequest _request() => SolveRequest(
    name: _name.text.trim().isEmpty ? widget.initial.name : _name.text.trim(),
    direction: _direction,
    unit: _unit,
    startDate: _startDate,
    endDate: _endDate,
    amount: _parseMoney(_amount),
    targetTotal: _balanceMode ? null : _parseMoney(_total),
    targetBalance: _parseMoney(_targetBalance),
    interval: _parseInt(_interval),
    occurrenceCount: _parseInt(_count),
    rounding: _rounding,
  );

  // --- Solving -------------------------------------------------------------

  void _changed() {
    setState(() {});
    _scheduleSolve();
  }

  void _scheduleSolve({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 300),
      _solve,
    );
  }

  Future<void> _solve() async {
    final seq = ++_requestSeq;
    if (_hasInputErrors) {
      setState(() {
        _result = null;
        _error = null;
        _solving = false;
      });
      return;
    }
    setState(() => _solving = true);
    try {
      final repo = ref.read(accountRepositoryProvider);
      final (result, defaulted) = await solveWithDefaults(
        _request(),
        (r) => repo.solve(widget.accountId, r),
        today: DateTime.now(),
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _result = result;
        _defaulted = defaulted;
        _error = null;
      });
      _emitPreview();
    } catch (error) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _result = null;
        _error = friendlyError(error);
      });
      _emitPreview();
    } finally {
      if (mounted && seq == _requestSeq) setState(() => _solving = false);
    }
  }

  void _emitPreview() {
    final cb = widget.onPreview;
    if (cb == null) return;
    final t = _result?.transaction;
    cb(t?.copyWith(accountId: widget.accountId, direction: _direction));
  }

  /// Custom… chosen: show the unit + Every inputs.
  bool _freqCustom = false;

  /// Frequency presets; a blank Every is auto (✦) and shows the matching
  /// preset for the calculated / assumed spacing.
  Widget _frequencyField(int? autoInterval) {
    final typed = _parseInt(_interval);
    final FrequencyPreset? value = _freqCustom
        ? FrequencyPreset.custom
        : (typed == null
              ? null
              : FrequencyPreset.of(once: false, interval: typed, unit: _unit));
    final auto = _isSolved(SolveVar.interval) ? autoInterval : null;
    final autoPreset = auto == null
        ? null
        : FrequencyPreset.of(once: false, interval: auto, unit: _unit);
    final autoLabel = autoPreset == null
        ? null
        : (autoPreset == FrequencyPreset.custom
              ? 'Every $auto ${unitLabel(_unit, auto!)}'
              : autoPreset.label);
    final scheme = Theme.of(context).colorScheme;
    return DropdownButtonFormField<FrequencyPreset>(
      key: ValueKey('plan-frequency-${value?.name}-$autoLabel'),
      initialValue: value,
      isExpanded: true,
      hint: autoLabel == null
          ? null
          : Text(
              autoLabel,
              style: TextStyle(
                color: scheme.primary,
                fontStyle: FontStyle.italic,
              ),
            ),
      decoration: _decoration(
        context,
        label: 'Frequency',
        hasValue: value != null,
        wanted: _isWanted(SolveVar.interval),
        hint: autoLabel,
        helper: _helperFor(
          hasValue: value != null,
          wanted: _isWanted(SolveVar.interval),
          help: 'Clear to have the spacing calculated',
          calculated: autoLabel,
        ),
        onClear: () {
          _freqCustom = false;
          _interval.clear();
          _changed();
        },
      ).copyWith(hintText: null),
      items: [
        for (final p in [...FrequencyPreset.repeating, FrequencyPreset.custom])
          DropdownMenuItem(value: p, child: Text(p.label)),
      ],
      onChanged: (p) {
        if (p == null) return;
        _freqCustom = p == FrequencyPreset.custom;
        if (p.repeats) {
          _interval.text = '${p.interval}';
          _unit = p.unit!;
        }
        _changed();
      },
    );
  }

  bool _isSolved(SolveVar v) =>
      (_result?.solved.contains(v) ?? false) || _defaulted.contains(v);

  bool _isWanted(SolveVar v) =>
      _result != null &&
      !_result!.isComplete &&
      _result!.needsOneOf.contains(v);

  // --- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final values = _result?.values;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Docked in the plan panel, the panel header is the title.
            if (widget.onPreview == null) ...[
              Text(
                widget.creditOnly ? 'Plan income' : 'Plan a transaction',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
            ],
            Text(
              widget.creditOnly
                  ? 'Plan money coming in. Fill in what you know — blank '
                        'fields are calculated (✦) and update as you type. '
                        'Clear a field to have it calculated again.'
                  : 'Fill in what you know and leave the rest blank — blank '
                        'fields are calculated. Any four of start date, total, '
                        'increment, frequency, count and end date determine '
                        'the transaction.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            if (!widget.creditOnly) ...[
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
                  _direction = value.first;
                  _changed();
                },
              ),
            ],
            const SizedBox(height: 16),
            _DateField(
              label: 'Start date',
              value: _startDate,
              calculated: _isSolved(SolveVar.startDate)
                  ? values?.startDate
                  : null,
              wanted: _isWanted(SolveVar.startDate),
              firstDate: DateTime(1970),
              lastDate: _endDate ?? DateTime(2100),
              onChanged: (date) {
                _startDate = date;
                _changed();
              },
            ),
            const SizedBox(height: 12),
            _MoneyField(
              key: const ValueKey('plan-target-balance'),
              controller: _targetBalance,
              label: 'Target balance (optional)',
              optional: true,
              help:
                  'Balance wanted on the end date; the total becomes the '
                  'gap from what is already projected',
              calculated: null,
              wanted: false,
              error: _balanceError(_targetBalance),
              onChanged: _changed,
            ),
            const SizedBox(height: 12),
            if (_balanceMode)
              _MoneyField(
                key: const ValueKey('plan-total-from-balance'),
                controller: _balanceTotal,
                label: 'Total amount',
                help: 'From the target balance',
                calculated: _result?.balanceTarget?.gap.abs(),
                wanted: false,
                error: null,
                readOnly: true,
                onChanged: () {},
              )
            else
              _MoneyField(
                controller: _total,
                label: 'Total amount',
                help: 'Sum of every occurrence',
                calculated: _isSolved(SolveVar.total) ? values?.total : null,
                wanted: _isWanted(SolveVar.total),
                error: _moneyError(_total),
                onChanged: _changed,
              ),
            const SizedBox(height: 12),
            _MoneyField(
              controller: _amount,
              label: 'Increment amount',
              help: 'Amount of each occurrence',
              calculated: _isSolved(SolveVar.amount) ? values?.amount : null,
              wanted: _isWanted(SolveVar.amount),
              error: _moneyError(_amount),
              onChanged: _changed,
            ),
            const SizedBox(height: 16),
            _frequencyField(values?.interval),
            if (_freqCustom) ...[
              const SizedBox(height: 12),
              SegmentedButton<RecurrenceUnit>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: RecurrenceUnit.days,
                    label: Text('Daily'),
                  ),
                  ButtonSegment(
                    value: RecurrenceUnit.weeks,
                    label: Text('Weekly'),
                  ),
                  ButtonSegment(
                    value: RecurrenceUnit.months,
                    label: Text('Monthly'),
                  ),
                  ButtonSegment(
                    value: RecurrenceUnit.years,
                    label: Text('Yearly'),
                  ),
                ],
                selected: {_unit},
                onSelectionChanged: (value) {
                  _unit = value.first;
                  _changed();
                },
              ),
              const SizedBox(height: 12),
              _IntField(
                controller: _interval,
                label: 'Every',
                suffix: unitLabel(
                  _unit,
                  _parseInt(_interval) ?? values?.interval ?? 1,
                ),
                help: 'Leave blank to find the spacing that fits',
                calculated: _isSolved(SolveVar.interval)
                    ? values?.interval
                    : null,
                wanted: _isWanted(SolveVar.interval),
                error: _intError(_interval),
                onChanged: _changed,
              ),
            ],
            const SizedBox(height: 12),
            _IntField(
              controller: _count,
              label: 'Count',
              suffix: 'times',
              help: 'How many occurrences, including the first',
              calculated: _isSolved(SolveVar.count) ? values?.count : null,
              wanted: _isWanted(SolveVar.count),
              error: _intError(_count),
              onChanged: _changed,
            ),
            const SizedBox(height: 12),
            _DateField(
              label: 'End date',
              value: _endDate,
              calculated: _isSolved(SolveVar.endDate) ? values?.endDate : null,
              wanted: _isWanted(SolveVar.endDate),
              firstDate: _startDate ?? DateTime(1970),
              lastDate: DateTime(2100),
              onChanged: (date) {
                _endDate = date;
                _changed();
              },
            ),
            if (_total.text.trim().isNotEmpty || _balanceMode) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<RoundingMode>(
                initialValue: _rounding,
                decoration: const InputDecoration(
                  labelText: 'When the total does not divide evenly',
                ),
                items: const [
                  DropdownMenuItem(
                    value: RoundingMode.nearest,
                    child: Text('Get as close as possible'),
                  ),
                  DropdownMenuItem(
                    value: RoundingMode.atLeast,
                    child: Text('Reach at least the total'),
                  ),
                  DropdownMenuItem(
                    value: RoundingMode.atMost,
                    child: Text('Stay at or under the total'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  _rounding = value;
                  _changed();
                },
              ),
            ],
            const SizedBox(height: 20),
            _StatusPanel(
              result: _result,
              error: _error,
              solving: _solving,
              direction: _direction,
              unit: _unit,
              defaulted: _defaulted,
            ),
            const SizedBox(height: 20),
            FilledButton(
              key: const ValueKey('solve-commit'),
              onPressed:
                  !(widget.readOnly && widget.saveOnCommit) &&
                      _result?.isComplete == true &&
                      !_solving &&
                      !_saving
                  ? _commit
                  : null,
              child: Text(
                widget.readOnly && widget.saveOnCommit
                    ? 'View only: can’t create'
                    : _saving
                    ? 'Saving…'
                    : (widget.saveOnCommit
                          ? 'Create transaction'
                          : 'Use these values'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _commit() async {
    final result = _result;
    final transaction = result?.transaction;
    if (result == null || transaction == null) return;
    final named = transaction.copyWith(
      accountId: widget.accountId,
      name: _name.text.trim().isEmpty ? widget.initial.name : _name.text.trim(),
      direction: _direction,
    );

    if (!widget.saveOnCommit) {
      final done = _withTransaction(result, named);
      if (widget.onDone != null) {
        widget.onDone!(done);
      } else {
        Navigator.of(context).pop(done);
      }
      return;
    }

    setState(() => _saving = true);
    try {
      final created = await ref
          .read(transactionsProvider(widget.accountId).notifier)
          .create(named);
      if (mounted) {
        final done = _withTransaction(
          result,
          created,
          message: 'Created ${created.name}',
        );
        if (widget.onDone != null) {
          widget.onDone!(done);
        } else {
          Navigator.of(context).pop(done);
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = friendlyError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  SolveResult _withTransaction(
    SolveResult result,
    Transaction transaction, {
    String? message,
  }) => SolveResult(
    transaction: transaction,
    previewOccurrences: result.previewOccurrences,
    values: result.values,
    solved: result.solved,
    message: message,
  );
}

String unitLabel(RecurrenceUnit unit, int count) {
  final one = count == 1;
  return switch (unit) {
    RecurrenceUnit.days => one ? 'day' : 'days',
    RecurrenceUnit.weeks => one ? 'week' : 'weeks',
    RecurrenceUnit.months => one ? 'month' : 'months',
    RecurrenceUnit.years => one ? 'year' : 'years',
  };
}

/// Helper line for a planner field: calculated value, a prompt to fill it
/// in, or the default explanation.
String _helperFor({
  required bool hasValue,
  required bool wanted,
  required String help,
  String? calculated,
}) {
  if (hasValue) return help;
  if (calculated != null) return 'Calculated: $calculated';
  if (wanted) return 'Fill in if known — this would help solve the rest';
  return 'Unknown — leave blank to calculate';
}

TextStyle? _helperStyle(
  BuildContext context, {
  required bool hasValue,
  required bool wanted,
  required bool calculated,
}) {
  final scheme = Theme.of(context).colorScheme;
  if (hasValue) return null;
  if (calculated) return TextStyle(color: scheme.primary);
  if (wanted) return TextStyle(color: scheme.tertiary);
  return null;
}

class _MoneyField extends StatelessWidget {
  const _MoneyField({
    super.key,
    this.readOnly = false,
    this.optional = false,
    required this.controller,
    required this.label,
    required this.help,
    required this.calculated,
    required this.wanted,
    required this.error,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String help;
  final Decimal? calculated;
  final bool wanted;
  final String? error;
  final VoidCallback onChanged;
  final bool readOnly;

  /// Not part of the solve: blank means "not used", not "calculate".
  final bool optional;

  @override
  Widget build(BuildContext context) {
    final hasValue = controller.text.trim().isNotEmpty;
    return TextField(
      controller: controller,
      readOnly: readOnly,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => onChanged(),
      decoration: _decoration(
        context,
        label: label,
        hasValue: hasValue,
        wanted: wanted,
        error: error,
        hint: calculated?.toString(),
        helper: optional && !hasValue
            ? help
            : _helperFor(
                hasValue: hasValue,
                wanted: wanted,
                help: help,
                calculated: calculated?.toString(),
              ),
        onClear: () {
          controller.clear();
          onChanged();
        },
      ),
    );
  }
}

class _IntField extends StatelessWidget {
  const _IntField({
    required this.controller,
    required this.label,
    required this.suffix,
    required this.help,
    required this.calculated,
    required this.wanted,
    required this.error,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String suffix;
  final String help;
  final int? calculated;
  final bool wanted;
  final String? error;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final hasValue = controller.text.trim().isNotEmpty;
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      onChanged: (_) => onChanged(),
      decoration: _decoration(
        context,
        label: label,
        hasValue: hasValue,
        wanted: wanted,
        error: error,
        hint: calculated?.toString(),
        helper: _helperFor(
          hasValue: hasValue,
          wanted: wanted,
          help: help,
          calculated: calculated == null ? null : '$calculated $suffix',
        ),
        suffixText: suffix,
        onClear: () {
          controller.clear();
          onChanged();
        },
      ),
    );
  }
}

InputDecoration _decoration(
  BuildContext context, {
  required String label,
  required bool hasValue,
  required bool wanted,
  required String helper,
  String? error,
  String? hint,
  String? suffixText,
  required VoidCallback onClear,
}) {
  final scheme = Theme.of(context).colorScheme;
  return InputDecoration(
    labelText: label,
    floatingLabelBehavior: hint != null ? FloatingLabelBehavior.always : null,
    hintText: hint,
    hintStyle: TextStyle(color: scheme.primary, fontStyle: FontStyle.italic),
    helperText: helper,
    helperStyle: _helperStyle(
      context,
      hasValue: hasValue,
      wanted: wanted,
      calculated: hint != null,
    ),
    errorText: error,
    suffixText: suffixText,
    prefixIcon: hasValue
        ? null
        : Icon(
            hint != null ? Icons.auto_awesome : Icons.help_outline,
            color: hint != null
                ? scheme.primary
                : (wanted ? scheme.tertiary : null),
          ),
    suffixIcon: hasValue
        ? IconButton(
            tooltip: 'Clear — calculate instead',
            icon: const Icon(Icons.close),
            onPressed: onClear,
          )
        : null,
    enabledBorder: wanted
        ? OutlineInputBorder(borderSide: BorderSide(color: scheme.tertiary))
        : null,
  );
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.calculated,
    required this.wanted,
    required this.firstDate,
    required this.lastDate,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final DateTime? calculated;
  final bool wanted;
  final DateTime firstDate;
  final DateTime lastDate;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasValue = value != null;
    final calc = calculated;

    Future<void> pick() async {
      final initial = value ?? calc ?? DateTime.now();
      final picked = await showDatePicker(
        context: context,
        initialDate: initial.isBefore(firstDate)
            ? firstDate
            : (initial.isAfter(lastDate) ? lastDate : initial),
        firstDate: firstDate,
        lastDate: lastDate,
      );
      if (picked != null) onChanged(picked);
    }

    return InkWell(
      onTap: pick,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        isEmpty: !hasValue && calc == null,
        decoration:
            _decoration(
              context,
              label: label,
              hasValue: hasValue,
              wanted: wanted,
              hint: calc == null ? null : formatDate(calc),
              helper: _helperFor(
                hasValue: hasValue,
                wanted: wanted,
                help: 'Tap to change',
                calculated: calc == null ? null : formatDate(calc),
              ),
              onClear: () => onChanged(null),
            ).copyWith(
              suffixIcon: hasValue
                  ? IconButton(
                      tooltip: 'Clear — calculate instead',
                      icon: const Icon(Icons.close),
                      onPressed: () => onChanged(null),
                    )
                  : Icon(Icons.calendar_today_outlined, color: scheme.outline),
            ),
        child: Text(
          hasValue
              ? formatDate(value!)
              : (calc == null ? '' : formatDate(calc)),
          style: hasValue
              ? null
              : TextStyle(color: scheme.primary, fontStyle: FontStyle.italic),
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.result,
    required this.error,
    required this.solving,
    required this.direction,
    required this.unit,
    this.defaulted = const {},
  });

  final Set<SolveVar> defaulted;
  final SolveResult? result;
  final String? error;
  final bool solving;
  final TransactionDirection direction;
  final RecurrenceUnit unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (error != null) {
      return _panel(
        context,
        color: scheme.errorContainer,
        icon: Icons.error_outline,
        iconColor: scheme.error,
        children: [Text(error!, style: theme.textTheme.bodyMedium)],
      );
    }

    final r = result;
    final bt = r?.balanceTarget;
    final btLine = bt == null
        ? null
        : Text(
            'Projected ${bt.projectedBalance} on the end date without this '
            'plan; target ${bt.targetBalance}, gap ${bt.gap}.',
            key: const ValueKey('plan-balance-target-info'),
            style: theme.textTheme.bodySmall,
          );
    if (r != null && r.onTrack) {
      return _panel(
        context,
        color: scheme.secondaryContainer,
        icon: Icons.verified_outlined,
        iconColor: AppTheme.creditColor,
        children: [Text(r.message ?? 'Already on track.'), ?btLine],
      );
    }
    if (r == null) {
      return _panel(
        context,
        color: scheme.surfaceContainerHighest,
        icon: solving ? Icons.hourglass_empty : Icons.edit_note,
        children: [
          Text(
            solving ? 'Solving…' : 'Fix the highlighted fields to continue.',
          ),
        ],
      );
    }

    if (!r.isComplete) {
      final names = _joinOr(r.needsOneOf.map((v) => v.label).toList());
      final text = r.needsMore == 1
          ? 'Fill in one more: $names.'
          : 'Fill in ${r.needsMore} more of: $names.';
      return _panel(
        context,
        color: scheme.tertiaryContainer,
        icon: Icons.lightbulb_outline,
        iconColor: scheme.tertiary,
        children: [Text(text, style: theme.textTheme.bodyMedium)],
      );
    }

    final v = r.values;
    final transaction = r.transaction!;
    final once = transaction.recurrenceMode == RecurrenceMode.once;
    final directionColor = direction == TransactionDirection.credit
        ? AppTheme.creditColor
        : AppTheme.debitColor;
    final schedule = once
        ? 'once on ${formatDate(v.startDate!)}'
        : 'every ${v.interval == 1 ? '' : '${v.interval} '}'
              '${unitLabel(unit, v.interval ?? 1)}, ${v.count} times, '
              '${formatDate(v.startDate!)} → '
              '${formatDate(v.lastOccurrenceDate ?? v.endDate!)}';
    final rounded =
        v.total != null && v.actualTotal != null && v.total != v.actualTotal;
    final dates = r.previewOccurrences.map((o) => o.date).toList();

    return _panel(
      context,
      color: scheme.secondaryContainer,
      icon: Icons.check_circle_outline,
      iconColor: directionColor,
      children: [
        Text(
          '${direction == TransactionDirection.credit ? 'Credit' : 'Debit'} '
          '${v.amount} $schedule',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text('Total ${v.actualTotal ?? v.total}'),
        ?btLine,
        if (rounded)
          Text(
            'Rounded from the ${v.total} target.',
            style: theme.textTheme.bodySmall,
          ),
        if (r.solved.isNotEmpty)
          Text(
            'Calculated: ${_joinAnd(r.solved.map((s) => s.label).toList())}.',
            style: theme.textTheme.bodySmall,
          ),
        if (defaulted.isNotEmpty)
          Text(
            'Assumed: ${_joinAnd([for (final d in defaulted) d == SolveVar.startDate ? 'starting today' : 'every 1 ${unitLabel(unit, 1)}'])} — enter a value to change.',
            style: theme.textTheme.bodySmall,
          ),
        if (dates.length > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final d in dates.take(8))
                Chip(
                  label: Text(formatDate(d)),
                  visualDensity: VisualDensity.compact,
                ),
              if (dates.length > 8)
                Chip(
                  label: Text('+${dates.length - 8} more'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _panel(
    BuildContext context, {
    required Color color,
    required IconData icon,
    Color? iconColor,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

String _joinOr(List<String> items) => _join(items, 'or');

String _joinAnd(List<String> items) => _join(items, 'and');

String _join(List<String> items, String word) {
  if (items.isEmpty) return '';
  if (items.length == 1) return items.first;
  return '${items.sublist(0, items.length - 1).join(', ')} $word ${items.last}';
}

/// Solves [user] (only what the user entered). If that is incomplete and the
/// start date or spacing is still unknown, retries with sensible defaults
/// (start today, every 1 unit) for those — they then show as auto values
/// like any calculated field, and typing a value takes them over.
/// Returns the result and which fields were defaulted.
Future<(SolveResult, Set<SolveVar>)> solveWithDefaults(
  SolveRequest user,
  Future<SolveResult> Function(SolveRequest request) solve, {
  required DateTime today,
}) async {
  final first = await solve(user);
  if (first.isComplete) return (first, const <SolveVar>{});
  final canStart =
      user.startDate == null && !first.solved.contains(SolveVar.startDate);
  final canInterval =
      user.interval == null && !first.solved.contains(SolveVar.interval);
  final start = DateTime(today.year, today.month, today.day);
  // Fewest assumptions first: spacing alone (so a start can be calculated
  // back from the end), then start alone, then both.
  final options = <Set<SolveVar>>[
    if (canInterval) {SolveVar.interval},
    if (canStart) {SolveVar.startDate},
    if (canInterval && canStart) {SolveVar.interval, SolveVar.startDate},
  ];
  (SolveResult, Set<SolveVar>)? fallback;
  for (final option in options) {
    try {
      final r = await solve(
        user.withDefaults(
          startDate: option.contains(SolveVar.startDate) ? start : null,
          interval: option.contains(SolveVar.interval) ? 1 : null,
        ),
      );
      if (r.isComplete) return (r, option);
      fallback = (r, option);
    } catch (_) {
      // These defaults conflict with what was entered; try the next.
    }
  }
  return fallback ?? (first, const <SolveVar>{});
}
