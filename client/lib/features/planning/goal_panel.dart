import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/api_client.dart';
import '../../data/frequency.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/money_text.dart';
import '../../widgets/recurrence_interval_field.dart';
import '../timeline/duration_format.dart';
import 'goal_models.dart';

/// Variables shown in the solver, in order.
const goalRows = [
  GoalVar.startBalance,
  GoalVar.targetBalance,
  GoalVar.startDate,
  GoalVar.endDate,
  GoalVar.amount,
  GoalVar.interval,
  GoalVar.count,
  GoalVar.oneOff,
  GoalVar.rate,
];

/// "Plan a goal": every variable is known (🔒, typed or a default) except
/// the one solve slot (✦), which is derived live as you type. Tap ✦ on
/// another row to move the slot there; the old answer is locked in so you
/// can keep experimenting from it.
class GoalPanel extends ConsumerStatefulWidget {
  const GoalPanel({
    super.key,
    required this.account,
    required this.onResult,
    this.initial,
    this.onSaveScenario,
  });

  /// "Save as scenario": stores the current request as a what-if.
  final ValueChanged<GoalRequest>? onSaveScenario;

  final Account account;

  /// Every solve (null while incomplete or failed), for the chart preview.
  final void Function(GoalRequest request, GoalResult? result) onResult;
  final GoalRequest? initial;

  @override
  ConsumerState<GoalPanel> createState() => GoalPanelState();
}

class GoalPanelState extends ConsumerState<GoalPanel> {
  late GoalVar _solveFor;
  late GoalMode _mode;
  late RecurrenceUnit _unit;
  int _interval = 1;
  DateTime? _startDate;
  DateTime? _endDate;
  final _money = <GoalVar, TextEditingController>{
    GoalVar.startBalance: TextEditingController(),
    GoalVar.targetBalance: TextEditingController(),
    GoalVar.amount: TextEditingController(),
    GoalVar.oneOff: TextEditingController(),
    GoalVar.rate: TextEditingController(),
  };
  final _count = TextEditingController();
  final _intervalText = TextEditingController(text: '1');

  Timer? _debounce;
  int _seq = 0;
  bool _solving = false;
  bool _saving = false;
  GoalResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    load(widget.initial ?? const GoalRequest(solveFor: GoalVar.amount));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in _money.values) {
      c.dispose();
    }
    _count.dispose();
    _intervalText.dispose();
    super.dispose();
  }

  /// Replaces every field with [r] (prefill, scenario load) and solves.
  void load(GoalRequest r) {
    _solveFor = r.solveFor;
    _mode = r.mode;
    _unit = r.unit;
    _interval = r.interval ?? 1;
    _intervalText.text = '$_interval';
    _startDate = r.startDate;
    _endDate = r.endDate;
    String m(double? v) => v == null ? '' : _plain(v);
    _money[GoalVar.startBalance]!.text = m(r.startBalance);
    _money[GoalVar.targetBalance]!.text = m(r.targetBalance);
    _money[GoalVar.amount]!.text = m(r.amount);
    _money[GoalVar.oneOff]!.text = m(r.oneOff);
    _money[GoalVar.rate]!.text = m(r.rate);
    _count.text = r.count?.toString() ?? '';
    if (mounted) setState(() {});
    _schedule(immediate: true);
  }

  /// Sets the target point (dragged on the chart): the end date and the
  /// target balance, solved live.
  void setTarget(DateTime date, double balance) {
    _endDate = DateTime(date.year, date.month, date.day);
    _money[GoalVar.targetBalance]!.text = _plain(
      (balance / 10).roundToDouble() * 10,
    );
    if (_solveFor == GoalVar.endDate || _solveFor == GoalVar.targetBalance) {
      _solveFor = GoalVar.amount;
    }
    setState(() {});
    // Short debounce: drags fire every frame.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 60), _solve);
  }

  GoalRequest get request => _request();

  static String _plain(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  double? _num(GoalVar v) =>
      _solveFor == v ? null : double.tryParse(_money[v]!.text.trim());

  GoalRequest _request() => GoalRequest(
    solveFor: _solveFor,
    mode: _mode,
    unit: _unit,
    startDate: _solveFor == GoalVar.startDate ? null : _startDate,
    endDate: _solveFor == GoalVar.endDate ? null : _endDate,
    startBalance: _num(GoalVar.startBalance),
    targetBalance: _num(GoalVar.targetBalance),
    amount: _num(GoalVar.amount),
    interval: _solveFor == GoalVar.interval ? null : _interval,
    count: _solveFor == GoalVar.count ? null : int.tryParse(_count.text.trim()),
    oneOff: _num(GoalVar.oneOff),
    rate: _num(GoalVar.rate),
  );

  String? _fieldError(GoalVar v) {
    if (v == GoalVar.count) {
      final t = _count.text.trim();
      if (t.isEmpty) return null;
      final n = int.tryParse(t);
      return n == null || n < 0 ? 'Whole number' : null;
    }
    final c = _money[v];
    if (c == null) return null;
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t) == null ? 'Invalid number' : null;
  }

  void _changed() {
    setState(() {});
    _schedule();
  }

  void _schedule({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 250),
      _solve,
    );
  }

  Future<void> _solve() async {
    final seq = ++_seq;
    if (goalRows.any((v) => _fieldError(v) != null)) {
      setState(() {
        _result = null;
        _error = null;
      });
      widget.onResult(_request(), null);
      return;
    }
    final req = _request();
    setState(() => _solving = true);
    try {
      final r = await ref
          .read(accountRepositoryProvider)
          .goal(widget.account.id, req);
      if (!mounted || seq != _seq) return;
      setState(() {
        _result = r;
        _error = null;
      });
      widget.onResult(req, r.isComplete ? r : null);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _result = null;
        _error = friendlyError(e);
      });
      widget.onResult(req, null);
    } finally {
      if (mounted && seq == _seq) setState(() => _solving = false);
    }
  }

  /// Moves the solve slot to [v], locking the previous answer in.
  void _solveSlot(GoalVar v) {
    if (v == _solveFor) return;
    final solved = _result?.values?.of(_solveFor);
    if (solved != null) _setField(_solveFor, solved);
    _solveFor = v;
    _changed();
  }

  void _setField(GoalVar v, Object value) {
    switch (v) {
      case GoalVar.startDate:
        _startDate = value as DateTime;
      case GoalVar.endDate:
        _endDate = value as DateTime;
      case GoalVar.interval:
        _interval = value as int;
        _intervalText.text = '$_interval';
      case GoalVar.count:
        _count.text = '$value';
      default:
        _money[v]!.text = _plain(value as double);
    }
  }

  // --- formatting ------------------------------------------------------------
  String _money2(double v) => formatMoneyAmount(v, decimalDigits: 2);
  String _date(DateTime d) => DateFormat('d MMM y').format(d);
  String _every(int n, RecurrenceUnit u) {
    final p = FrequencyPreset.of(once: false, interval: n, unit: u);
    if (p != FrequencyPreset.custom) return p.label.toLowerCase();
    return 'every $n ${_unitWord(u, n)}';
  }

  String _unitWord(RecurrenceUnit u, int n) {
    final w = switch (u) {
      RecurrenceUnit.days => 'day',
      RecurrenceUnit.weeks => 'week',
      RecurrenceUnit.months => 'month',
      RecurrenceUnit.years => 'year',
    };
    return n == 1 ? w : '${w}s';
  }

  String _solvedText(GoalVar v, GoalValues x) => switch (v) {
    GoalVar.startBalance => _money2(x.startBalance),
    GoalVar.targetBalance => _money2(x.targetBalance),
    GoalVar.amount => _money2(x.amount),
    GoalVar.oneOff => _money2(x.oneOff),
    GoalVar.rate => '${x.rate.toStringAsFixed(2)}% a year',
    GoalVar.startDate => _date(x.startDate),
    GoalVar.endDate => _date(x.endDate),
    GoalVar.count => '${x.count} times',
    GoalVar.interval => _every(x.interval, x.unit),
  };

  // --- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Lock what you know and pick the one value to solve (✦). It '
            'updates live, and the dashed line on the chart shows the plan.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          SegmentedButton<GoalMode>(
            key: const ValueKey('goal-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: GoalMode.onDate,
                label: Text('On end date'),
                icon: Icon(Icons.flag_outlined, size: 16),
              ),
              ButtonSegment(
                value: GoalMode.floor,
                label: Text('Stay above'),
                icon: Icon(Icons.vertical_align_bottom_rounded, size: 16),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) {
              _mode = s.first;
              _changed();
            },
          ),
          const SizedBox(height: 12),
          for (final v in goalRows) ...[
            _row(context, v),
            const SizedBox(height: 8),
          ],
          ...extraRows(context),
          const SizedBox(height: 6),
          _status(context),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('goal-add-transactions'),
            onPressed:
                !widget.account.role.canEdit ||
                    _saving ||
                    _solving ||
                    (_result?.toTransactions(widget.account.id).isEmpty ?? true)
                ? null
                : _addTransactions,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(
              !widget.account.role.canEdit
                  ? 'View only: can’t add to account'
                  : (_saving ? 'Adding…' : 'Add plan to account'),
            ),
          ),
          if (widget.onSaveScenario != null && widget.account.role.canEdit) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('goal-save-scenario'),
              onPressed: _result?.isComplete ?? false
                  ? () => widget.onSaveScenario!(_request())
                  : null,
              icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: const Text('Save as scenario'),
            ),
          ],
          ...footer(context),
        ],
      ),
    );
  }

  /// Hook for extra variable rows (rate) below the main ones.
  List<Widget> extraRows(BuildContext context) => const [];

  /// Hook for widgets under the add button (scenarios).
  List<Widget> footer(BuildContext context) => const [];

  bool _wanted(GoalVar v) =>
      _result != null &&
      !_result!.isComplete &&
      _result!.needsOneOf.contains(v);

  String _hint(GoalVar v) {
    final r = _result;
    return switch (v) {
      GoalVar.startBalance =>
        r?.projectedStartBalance == null
            ? 'Projected'
            : 'Projected ${_money2(r!.projectedStartBalance!)}',
      GoalVar.startDate => 'Today',
      GoalVar.amount => 'None (+ in, − out)',
      GoalVar.count => 'Every time until the end date',
      GoalVar.oneOff => 'None (− for a purchase)',
      GoalVar.rate => '0% a year, compounded daily',
      GoalVar.targetBalance || GoalVar.endDate => 'Required',
      GoalVar.interval => '',
    };
  }

  Widget _row(BuildContext context, GoalVar v) {
    final scheme = Theme.of(context).colorScheme;
    final solving = v == _solveFor;
    final values = _result?.values;
    Widget field;
    if (solving) {
      field = InputDecorator(
        key: ValueKey('goal-solved-${v.name}'),
        decoration: InputDecoration(
          labelText: v.label,
          floatingLabelBehavior: FloatingLabelBehavior.always,
          prefixIcon: Icon(Icons.auto_awesome, color: scheme.primary),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: scheme.primary),
          ),
        ),
        child: Text(
          values == null
              ? (_solving ? 'Solving…' : '—')
              : _solvedText(v, values),
          style: TextStyle(
            color: scheme.primary,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    } else {
      field = switch (v) {
        GoalVar.startDate || GoalVar.endDate => _dateField(context, v),
        GoalVar.interval => _frequencyField(context),
        GoalVar.count => _textField(context, v, _count, number: true),
        _ => _textField(context, v, _money[v]!),
      };
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: field),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: IconButton(
            key: ValueKey('goal-toggle-${v.name}'),
            tooltip: solving ? 'Solving for this' : 'Solve for ${v.label}',
            isSelected: solving,
            onPressed: () => _solveSlot(v),
            icon: const Icon(Icons.lock_outline_rounded, size: 20),
            selectedIcon: Icon(Icons.auto_awesome, color: scheme.primary),
          ),
        ),
      ],
    );
  }

  InputDecoration _decoration(
    BuildContext context,
    GoalVar v, {
    required bool empty,
    String? error,
    VoidCallback? onClear,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final wanted = _wanted(v);
    return InputDecoration(
      labelText: v.label,
      hintText: _hint(v),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      errorText: error,
      helperText: wanted ? 'Needed to solve' : null,
      helperStyle: wanted ? TextStyle(color: scheme.tertiary) : null,
      enabledBorder: wanted
          ? OutlineInputBorder(borderSide: BorderSide(color: scheme.tertiary))
          : null,
      suffixIcon: empty || onClear == null
          ? null
          : IconButton(
              tooltip: 'Clear (use the default)',
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: onClear,
            ),
    );
  }

  Widget _textField(
    BuildContext context,
    GoalVar v,
    TextEditingController c, {
    bool number = false,
  }) {
    return TextField(
      key: ValueKey('goal-field-${v.name}'),
      controller: c,
      keyboardType: number
          ? TextInputType.number
          : const TextInputType.numberWithOptions(decimal: true, signed: true),
      onChanged: (_) => _changed(),
      decoration: _decoration(
        context,
        v,
        empty: c.text.isEmpty,
        error: _fieldError(v),
        onClear: () {
          c.clear();
          _changed();
        },
      ),
    );
  }

  Widget _dateField(BuildContext context, GoalVar v) {
    final value = v == GoalVar.startDate ? _startDate : _endDate;
    Future<void> pick() async {
      final picked = await showDatePicker(
        context: context,
        initialDate:
            value ??
            (v == GoalVar.endDate
                ? DateTime.now().add(const Duration(days: 90))
                : DateTime.now()),
        firstDate: DateTime(1970),
        lastDate: DateTime(2100),
      );
      if (picked == null) return;
      if (v == GoalVar.startDate) {
        _startDate = picked;
      } else {
        _endDate = picked;
      }
      _changed();
    }

    final r = _result?.values;
    final span = v == GoalVar.endDate && value != null
        ? formatSpanDuration(
            _startDate ?? r?.startDate ?? DateTime.now(),
            value,
            precision: DurationPrecision.days,
          )
        : null;
    return InkWell(
      key: ValueKey('goal-field-${v.name}'),
      onTap: pick,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        isEmpty: value == null,
        decoration: _decoration(
          context,
          v,
          empty: value == null,
          onClear: () {
            if (v == GoalVar.startDate) {
              _startDate = null;
            } else {
              _endDate = null;
            }
            _changed();
          },
        ).copyWith(helperText: span == null ? null : 'Duration: $span'),
        child: Text(value == null ? '' : _date(value)),
      ),
    );
  }

  /// Every [− N +] [unit ▾] (shared with the transaction editor).
  Widget _frequencyField(BuildContext context) => RecurrenceIntervalField(
    keyPrefix: 'goal-field-interval',
    caption: GoalVar.interval.label,
    controller: _intervalText,
    unit: _unit,
    onChanged: () {
      final n = int.tryParse(_intervalText.text.trim());
      if (n != null && n >= 1) _interval = n;
      _changed();
    },
    onUnitChanged: (u) {
      _unit = u;
      _changed();
    },
  );

  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget panel(
      Color color,
      IconData icon,
      List<Widget> children, {
      Color? iconColor,
    }) => Container(
      key: const ValueKey('goal-status'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
    if (_error != null) {
      return panel(scheme.errorContainer, Icons.error_outline, [
        Text(_error!),
      ], iconColor: scheme.error);
    }
    final r = _result;
    if (r == null) {
      return panel(scheme.surfaceContainerHighest, Icons.hourglass_empty, [
        Text(_solving ? 'Solving…' : 'Fix the highlighted fields.'),
      ]);
    }
    if (!r.isComplete) {
      final names = r.needsOneOf.map((v) => v.label.toLowerCase()).join(', ');
      return panel(scheme.tertiaryContainer, Icons.lightbulb_outline, [
        Text(
          r.needsOneOf.length == 1
              ? 'Fill in one more: $names.'
              : 'Fill in ${r.needsOneOf.length} more: $names.',
        ),
      ], iconColor: scheme.tertiary);
    }
    final x = r.values!;
    final small = theme.textTheme.bodySmall;
    return panel(scheme.secondaryContainer, Icons.check_circle_outline, [
      Text(
        headline(r, x),
        key: const ValueKey('goal-headline'),
        style: theme.textTheme.titleSmall,
      ),
      const SizedBox(height: 4),
      if (r.endBalance != null)
        Text(
          'End balance ${_money2(r.endBalance!)} on ${_date(x.endDate)}'
          '${r.baselineEndBalance == null ? '' : ' (without the plan ${_money2(r.baselineEndBalance!)})'}',
          style: small,
        ),
      if (r.lowestBalance != null && r.lowestDate != null)
        Text(
          'Lowest ${_money2(r.lowestBalance!)} on ${_date(r.lowestDate!)}',
          key: const ValueKey('goal-lowest'),
          style: small,
        ),
      Text(
        r.alertDate == null
            ? 'Stays above the alert line'
            : 'Hits the alert line on ${_date(r.alertDate!)}',
        key: const ValueKey('goal-alert'),
        style: small?.copyWith(
          color: r.alertDate == null
              ? AppTheme.creditColor
              : AppTheme.debitColor,
        ),
      ),
      if (r.affordability case final a?) ..._affordability(context, a),
      if ((r.values?.rate ?? 0) != 0)
        Text(
          'Interest compounds daily on the whole balance; '
          '"Add plan" adds the payments only, not the interest.',
          key: const ValueKey('goal-rate-note'),
          style: small,
        ),
      ...statusExtras(context, r),
      if (r.note != null) Text(r.note!, style: small),
    ]);
  }

  /// Purchase check (a negative one-off): yes/no, the worst point after it
  /// and the last day the balance stays above the alert line.
  List<Widget> _affordability(BuildContext context, Affordability a) {
    final theme = Theme.of(context);
    final color = a.affordable ? AppTheme.creditColor : AppTheme.debitColor;
    return [
      const SizedBox(height: 4),
      Row(
        key: const ValueKey('goal-affordability'),
        children: [
          Icon(
            a.affordable ? Icons.check_circle_rounded : Icons.cancel_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              a.affordable
                  ? 'Affordable — stays at or above the alert line'
                  : 'Not affordable — dips below the alert line',
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      if (a.worstDate != null && a.worstBalance != null)
        Text(
          'Worst point ${_money2(a.worstBalance!)} on ${_date(a.worstDate!)}',
          key: const ValueKey('goal-afford-worst'),
          style: theme.textTheme.bodySmall,
        ),
      Text(
        a.safeUntil == null
            ? 'Below the alert line straight away'
            : 'Safe until ${_date(a.safeUntil!)}',
        key: const ValueKey('goal-afford-safe'),
        style: theme.textTheme.bodySmall,
      ),
    ];
  }

  /// Hook for extra status lines.
  List<Widget> statusExtras(BuildContext context, GoalResult r) => const [];

  /// One sentence answering the solved question.
  String headline(GoalResult r, GoalValues x) {
    final when = x.count == 1
        ? 'once'
        : '${_every(x.interval, x.unit)} '
              '(${x.count} times)';
    return switch (r.solveFor) {
      GoalVar.amount =>
        x.amount >= 0
            ? 'Put in ${_money2(x.amount)} $when'
            : 'You can take out ${_money2(-x.amount)} $when',
      GoalVar.targetBalance =>
        _mode == GoalMode.floor
            ? 'Lowest balance: ${_money2(x.targetBalance)}'
            : 'Balance on ${_date(x.endDate)}: ${_money2(x.targetBalance)}',
      GoalVar.endDate =>
        _mode == GoalMode.floor
            ? 'Stays at or above ${_money2(x.targetBalance)} until ${_date(x.endDate)}'
            : 'Reaches ${_money2(x.targetBalance)} on ${_date(x.endDate)} '
                  '(${formatSpanDuration(x.startDate, x.endDate, precision: DurationPrecision.days)})',
      GoalVar.count => '${x.count} payments of ${_money2(x.amount)} are enough',
      GoalVar.interval => '${_every(x.interval, x.unit)} is often enough',
      GoalVar.startDate => 'Start by ${_date(x.startDate)} at the latest',
      GoalVar.startBalance =>
        'Needs ${_money2(x.startBalance)} at the start of ${_date(x.startDate)}'
            '${r.projectedStartBalance == null ? '' : ' (projected ${_money2(r.projectedStartBalance!)})'}',
      GoalVar.oneOff =>
        x.oneOff <= 0
            ? 'You can spend up to ${_money2(-x.oneOff)} on ${_date(x.startDate)}'
            : 'Needs a one-off of ${_money2(x.oneOff)} on ${_date(x.startDate)}',
      GoalVar.rate => 'Needs ${x.rate.toStringAsFixed(2)}% a year',
    };
  }

  Future<void> _addTransactions() async {
    final txs = _result?.toTransactions(widget.account.id) ?? const [];
    if (txs.isEmpty) return;
    setState(() => _saving = true);
    try {
      final notifier = ref.read(
        transactionsProvider(widget.account.id).notifier,
      );
      for (final t in txs) {
        await notifier.create(t);
      }
      ref.invalidate(balanceProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added ${txs.length} transaction${txs.length == 1 ? '' : 's'}',
            ),
          ),
        );
      }
      _schedule(immediate: true);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
