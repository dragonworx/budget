import 'dart:async';

import 'package:budget_formula/budget_formula.dart'
    show decimalOfDouble, fieldSpecs, parseLegacyDoubleRaw, parseLegacyInt;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/api_client.dart';
import '../../data/frequency.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../widgets/formula/formula_field.dart';
import '../../widgets/formula/formula_style.dart' show formatFieldValue;
import '../../widgets/money_text.dart';
import '../../widgets/recurrence_interval_field.dart';
import '../timeline/duration_format.dart';
import '../categories/categories_manager.dart';
import 'goal_models.dart';
import 'plan_schedule.dart';

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

/// "Reach a balance" (the Plan view's balance mode): every variable is known (🔒, typed or a default) except
/// the one solve slot (✦), which is derived live as you type. Tap ✦ on
/// another row to move the slot there; the old answer is locked in so you
/// can keep experimenting from it.
class GoalPanel extends ConsumerStatefulWidget {
  const GoalPanel({
    super.key,
    required this.stream,
    required this.onResult,
    this.initial,
    this.onSaveScenario,
  });

  /// "Save as scenario": stores the current request as a what-if.
  final ValueChanged<GoalRequest>? onSaveScenario;

  final BudgetStream stream;

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
  // Formulas (spec 013 D11): worked out here against the stream owner's
  // variables; the goal solve gets numbers, a saved scenario also keeps
  // the formulas (`request.exprs`).
  late final Map<GoalVar, FormulaEditingController> _money;
  late final FormulaEditingController _count;

  /// The plan's name: its events get a new category with this name.
  final _name = TextEditingController();
  String? _nameTaken;
  late final FormulaEditingController _intervalText;

  /// The numbers a loaded scenario stored for its formulas: used until
  /// the formula is edited or "Use new value" is tapped (D11).
  final _saved = <GoalVar, double>{};

  Timer? _debounce;
  int _seq = 0;
  bool _solving = false;
  bool _saving = false;
  GoalResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    final on = ServerFeatures.variables;
    FormulaEditingController field(String spec, {String text = ''}) {
      final c = FormulaEditingController(
        text: text,
        spec: fieldSpecs[spec]!,
        formulasEnabled: on,
      );
      // Variables arriving (or changing) re-resolve a formula: solve again.
      if (on) c.addListener(_formulaMaybeChanged);
      return c;
    }

    _money = {
      for (final v in const [
        GoalVar.startBalance,
        GoalVar.targetBalance,
        GoalVar.amount,
        GoalVar.oneOff,
        GoalVar.rate,
      ])
        v: field('goal.${v.name}'),
    };
    _count = field('goal.count');
    _intervalText = field('goal.interval', text: '1');
    load(widget.initial ?? const GoalRequest(solveFor: GoalVar.amount));
    _name.text = freeCategoryName(
      'Goal',
      ref.read(categoriesProvider(widget.stream.id)).valueOrNull ??
          const <Category>[],
    );
  }

  /// Why [_name] can't name the plan's new category, if it can't.
  String? get _nameProblem {
    if (!widget.stream.role.canEdit) return null;
    if (_nameTaken != null) return _nameTaken;
    final list = ref.watch(categoriesProvider(widget.stream.id)).valueOrNull;
    if (list == null) return null;
    return categoryNameProblem(_name.text, list);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in _money.values) {
      c.dispose();
    }
    _count.dispose();
    _name.dispose();
    _intervalText.dispose();
    super.dispose();
  }

  /// Replaces every field with [r] (prefill, scenario load) and solves.
  void load(GoalRequest r) {
    _saved.clear();
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
    // A saved scenario's formulas replace their numbers in the fields; the
    // numbers stay in use until the formula is edited or "Use new value".
    final exprs = ServerFeatures.variables ? r.exprs : null;
    if (exprs != null) {
      final stored = r.toJson(withExprs: false);
      for (final e in exprs.entries) {
        final v = GoalVar.values.where((g) => g.name == e.key).firstOrNull;
        final c = v == null ? null : _ctl(v);
        final n = stored[e.key];
        if (c == null || v == _solveFor || n is! num) continue;
        c.text = e.value;
        _saved[v!] = n.toDouble();
      }
    }
    _lastFormulaValues.clear();
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
    _saved.remove(GoalVar.targetBalance);
    if (_solveFor == GoalVar.endDate || _solveFor == GoalVar.targetBalance) {
      _solveFor = GoalVar.amount;
    }
    setState(() {});
    // Short debounce: drags fire every frame.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 60), _solve);
  }

  GoalRequest get request => _request();

  /// What the user locked in the shared schedule fields (the solve slot and
  /// the default "every 1" are left blank).
  PlanSchedule get schedule {
    final amount = _solveFor == GoalVar.amount ? null : _dbl(GoalVar.amount);
    return PlanSchedule(
      startDate: _solveFor == GoalVar.startDate ? null : _startDate,
      endDate: _solveFor == GoalVar.endDate ? null : _endDate,
      amount: amount,
      interval: _solveFor == GoalVar.interval || _interval == 1
          ? null
          : _interval,
      unit: _unit,
      count: _solveFor == GoalVar.count ? null : _int(GoalVar.count),
    );
  }

  /// Takes the shared schedule from the other mode and solves.
  set schedule(PlanSchedule v) {
    _saved
      ..remove(GoalVar.amount)
      ..remove(GoalVar.interval)
      ..remove(GoalVar.count);
    _startDate = v.startDate;
    _endDate = v.endDate;
    _money[GoalVar.amount]!.text = v.amount == null
        ? ''
        : planAmountText(v.amount!);
    _interval = v.interval ?? 1;
    _intervalText.text = '$_interval';
    _unit = v.unit;
    _count.text = v.count?.toString() ?? '';
    // A carried value is locked: move the solve slot off it (to the amount,
    // else the end date, else the target balance).
    final carried = {
      if (v.startDate != null) GoalVar.startDate,
      if (v.endDate != null) GoalVar.endDate,
      if (v.amount != null) GoalVar.amount,
      if (v.interval != null) GoalVar.interval,
      if (v.count != null) GoalVar.count,
    };
    if (carried.contains(_solveFor)) {
      _solveFor = [GoalVar.amount, GoalVar.endDate].firstWhere(
        (g) => !carried.contains(g),
        orElse: () => GoalVar.targetBalance,
      );
    }
    if (mounted) _changed();
  }

  static String _plain(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  double? _num(GoalVar v) => _solveFor == v ? null : _dbl(v);

  /// The text field behind [v] (null for the dates).
  FormulaEditingController? _ctl(GoalVar v) => switch (v) {
    GoalVar.count => _count,
    GoalVar.interval => _intervalText,
    _ => _money[v],
  };

  /// [v]'s number: a loaded scenario's stored number while it stands, a
  /// formula's value (null while it has an error or waits for
  /// variables), else today's `double.tryParse` of the text.
  double? _dbl(GoalVar v) {
    final saved = _saved[v];
    if (saved != null) return saved;
    final c = _money[v]!;
    if (c.showsFormula) {
      return c.formula.isValid ? c.formula.value?.toDouble() : null;
    }
    return parseLegacyDoubleRaw(c.text)?.toDouble();
  }

  /// [_dbl] for the whole-number fields (count, interval).
  int? _int(GoalVar v) {
    final saved = _saved[v];
    if (saved != null) return saved.toInt();
    final c = _ctl(v)!;
    if (c.showsFormula) return c.formula.isValid ? c.formula.intValue : null;
    return parseLegacyInt(c.text);
  }

  /// A formula with an error (or waiting for variables) that isn't
  /// covered by a stored number: the field says why; nothing is solved.
  bool _formulaBlocked(GoalVar v) {
    if (v == _solveFor || _saved.containsKey(v)) return false;
    final c = _ctl(v);
    return c != null && c.showsFormula && !c.formula.isValid;
  }

  /// The formulas behind the request's numbers, by [GoalVar.name].
  Map<String, String>? _exprs() {
    if (!ServerFeatures.variables) return null;
    final out = <String, String>{};
    for (final v in goalRows) {
      final c = _ctl(v);
      if (c == null || v == _solveFor || !c.showsFormula) continue;
      if (!c.formula.isValid && !_saved.containsKey(v)) continue;
      out[v.name] = c.formula.expr ?? c.text.trim();
    }
    return out.isEmpty ? null : out;
  }

  /// What each formula last resolved to, so only a real change re-solves.
  final _lastFormulaValues = <FormulaEditingController, Object?>{};

  void _formulaMaybeChanged() {
    var changed = false;
    for (final v in goalRows) {
      final c = _ctl(v);
      if (c == null) continue;
      final f = c.formula;
      final now = c.showsFormula ? (f.value, f.message, f.pending) : null;
      if (_lastFormulaValues[c] != now) {
        _lastFormulaValues[c] = now;
        if (now != null) changed = true;
      }
    }
    if (changed && mounted) _schedule();
  }

  /// "Values changed since saved: X → Y" for a loaded scenario's formula
  /// that now works out differently; null otherwise.
  (String, String)? _changedSinceSaved(GoalVar v) {
    final saved = _saved[v];
    final c = _ctl(v);
    if (saved == null || c == null || !c.showsFormula) return null;
    final f = c.formula;
    if (!f.isValid || f.value == null) return null;
    final was = decimalOfDouble(saved);
    if (was == null) return null;
    if (f.value == was) return null;
    return (formatFieldValue(was, c.spec), formatFieldValue(f.value!, c.spec));
  }

  /// "Use new value": the formula's value replaces the stored number.
  void _useNewValue(GoalVar v) {
    _saved.remove(v);
    if (v == GoalVar.interval) {
      final n = _int(v);
      if (n != null && n >= 1) _interval = n;
    }
    _changed();
  }

  /// Gives every field the current variables before the rows are built
  /// (so the "changed since saved" lines see them), and solves again if
  /// a formula now works out differently.
  void _syncScope() {
    if (!ServerFeatures.variables) return;
    final scope = _scope();
    for (final v in goalRows) {
      _ctl(v)?.configure(scope: scope, notify: false);
    }
    _formulaMaybeChanged();
  }

  VariableScope _scope() => ServerFeatures.variables
      ? scopeFor(ref, streamId: widget.stream.id)
      : VariableScope.empty;

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
    count: _solveFor == GoalVar.count ? null : _int(GoalVar.count),
    oneOff: _num(GoalVar.oneOff),
    rate: _num(GoalVar.rate),
    exprs: _exprs(),
  );

  /// Plain text only (a formula's errors show in its field).
  String? _fieldError(GoalVar v) {
    if (v == GoalVar.count) {
      if (_count.showsFormula) return null;
      final t = _count.text.trim();
      if (t.isEmpty) return null;
      final n = parseLegacyInt(t);
      return n == null || n < 0 ? 'Whole number' : null;
    }
    final c = _money[v];
    if (c == null || c.showsFormula) return null;
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return parseLegacyDoubleRaw(t) == null ? 'Invalid number' : null;
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
    if (goalRows.any((v) => _fieldError(v) != null || _formulaBlocked(v))) {
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
          .read(streamRepositoryProvider)
          .goal(widget.stream.id, req);
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
    _saved.remove(v);
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
    _syncScope();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Reach a balance: lock what you know and pick the one value to '
            'solve (✦). It updates live, and the dashed line on the chart '
            'shows the plan.',
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
          // A complete plan shows no summary: the fields (and the dashed
          // line on the chart) already say it.
          if (_showsStatus) ...[
            _status(context),
            const SizedBox(height: 12),
          ] else
            const SizedBox(height: 6),
          if (widget.stream.role.canEdit) ...[
            TextField(
              key: const ValueKey('goal-name'),
              controller: _name,
              onChanged: (_) => setState(() => _nameTaken = null),
              decoration: InputDecoration(
                labelText: 'Plan name',
                helperText: _nameProblem == null
                    ? 'Its events get a new category with this name'
                    : null,
                errorText: _nameProblem,
              ),
            ),
            const SizedBox(height: 10),
          ],
          FilledButton.icon(
            key: const ValueKey('goal-add-events'),
            onPressed:
                !widget.stream.role.canEdit ||
                    _nameProblem != null ||
                    _saving ||
                    _solving ||
                    (_result?.toEvents(widget.stream.id).isEmpty ?? true)
                ? null
                : _addEvents,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(
              !widget.stream.role.canEdit
                  ? 'View only: can’t add to stream'
                  : (_saving ? 'Adding…' : 'Add plan to stream'),
            ),
          ),
          if (widget.onSaveScenario != null && widget.stream.role.canEdit) ...[
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

  bool get _showsStatus =>
      _error != null || _result == null || !_result!.isComplete;

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
    FormulaEditingController c, {
    bool number = false,
  }) {
    final d = _decoration(
      context,
      v,
      empty: c.text.isEmpty,
      error: _fieldError(v),
      onClear: () {
        c.clear();
        _saved.remove(v);
        _changed();
      },
    );
    final field = FormulaField(
      key: ValueKey('goal-field-${v.name}'),
      spec: c.spec,
      scope: _scope(),
      controller: c,
      legacyKeyboardType: number
          ? TextInputType.number
          : const TextInputType.numberWithOptions(decimal: true, signed: true),
      allowEmpty: true,
      plainErrors: false,
      label: d.labelText,
      hintText: d.hintText,
      floatingLabelBehavior: d.floatingLabelBehavior,
      helperText: d.helperText,
      helperStyle: d.helperStyle,
      errorText: d.errorText,
      enabledBorder: d.enabledBorder,
      trailing: d.suffixIcon,
      onChanged: (_) {
        _saved.remove(v);
        _changed();
      },
    );
    return _withChangedLine(context, v, field);
  }

  /// [field] with the "Values changed since saved" line under it, when a
  /// loaded scenario's formula now works out differently.
  Widget _withChangedLine(BuildContext context, GoalVar v, Widget field) {
    final changed = _changedSinceSaved(v);
    if (changed == null) return field;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 2),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            children: [
              Text(
                'Values changed since saved: ${changed.$1} → ${changed.$2}',
                key: ValueKey('goal-field-${v.name}-changed'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
              TextButton(
                key: ValueKey('goal-field-${v.name}-use-new'),
                onPressed: () => _useNewValue(v),
                child: const Text('Use new value'),
              ),
            ],
          ),
        ),
      ],
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

  /// Every [− N +] [unit ▾] (shared with the event editor).
  Widget _frequencyField(BuildContext context) => _withChangedLine(
    context,
    GoalVar.interval,
    RecurrenceIntervalField(
      keyPrefix: 'goal-field-interval',
      caption: GoalVar.interval.label,
      controller: _intervalText,
      spec: _intervalText.spec,
      scope: _scope(),
      unit: _unit,
      onChanged: () {
        _saved.remove(GoalVar.interval);
        final n = _int(GoalVar.interval);
        if (n != null && n >= 1) _interval = n;
        _changed();
      },
      onUnitChanged: (u) {
        _unit = u;
        _changed();
      },
    ),
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
    // Complete: the build leaves the panel out ([_showsStatus] is false).
    return const SizedBox.shrink();
  }

  Future<void> _addEvents() async {
    if (_nameProblem != null) return;
    final name = normalizeCategoryName(_name.text);
    final txs =
        _result?.toEvents(widget.stream.id, name: name, oneOffSuffix: false) ??
        const [];
    if (txs.isEmpty) return;
    setState(() => _saving = true);
    try {
      final notifier = ref.read(eventsProvider(widget.stream.id).notifier);
      // The first event makes the plan's category; the rest join it.
      String? categoryId;
      for (final t in txs) {
        final created = categoryId == null
            ? await notifier.create(
                t,
                newCategory: (
                  name: name,
                  color: pickCategoryColor(
                    ref
                            .read(categoriesProvider(widget.stream.id))
                            .valueOrNull ??
                        const <Category>[],
                  ),
                ),
              )
            : await notifier.create(t.copyWith(categoryId: categoryId));
        categoryId ??= created.categoryId;
      }
      if (mounted) {
        _name.text = freeCategoryName(name, [
          ...?ref.read(categoriesProvider(widget.stream.id)).valueOrNull,
          Category(id: '', streamId: '', name: name, color: '#000000'),
        ]);
      }
      ref.invalidate(balanceProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added ${txs.length} event${txs.length == 1 ? '' : 's'}',
            ),
          ),
        );
      }
      _schedule(immediate: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          if (e is ApiException && e.statusCode == 409) {
            _nameTaken = 'A category with this name already exists';
          } else {
            _error = friendlyError(e);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
