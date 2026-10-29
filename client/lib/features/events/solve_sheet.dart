import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/recurrence_interval_field.dart';
import '../categories/categories_manager.dart';
import '../planning/plan_schedule.dart';

/// Opens the event planner. Any values in [initial] are treated as known.
///
/// With [saveOnCommit] the solved event is created and returned; otherwise
/// the unsaved solved event is returned for the caller to apply.
Future<SolveResult?> showSolveSheet(
  BuildContext context, {
  required String streamId,
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
          streamId: streamId,
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
      direction: EventDirection.credit,
      unit: RecurrenceUnit.weeks,
      startDate: startDate,
      endDate: endDate,
    );

class SolveSheet extends ConsumerStatefulWidget {
  const SolveSheet({
    super.key,
    required this.streamId,
    required this.initial,
    this.saveOnCommit = true,
    this.creditOnly = false,
    this.onPreview,
    this.onDone,
    this.readOnly = false,
  });

  /// Embedded (panel) use: called with the would-be event whenever
  /// the plan is fully solved, or null when it is not.
  final ValueChanged<BudgetEvent?>? onPreview;

  /// Embedded use: called instead of popping the route after a commit.
  final ValueChanged<SolveResult>? onDone;

  /// Viewer access: solve only, no "Create event".
  final bool readOnly;
  final String streamId;
  final SolveRequest initial;
  final bool saveOnCommit;

  /// The Plan feature: always a credit, no direction choice.
  final bool creditOnly;

  @override
  ConsumerState<SolveSheet> createState() => SolveSheetState();
}

/// Public so the Plan view can carry the shared schedule across modes.
class SolveSheetState extends ConsumerState<SolveSheet> {
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _total;
  late final TextEditingController _interval;
  late final TextEditingController _count;
  late EventDirection _direction;
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
    // A plan makes its own category: start from a name not taken yet.
    _name = TextEditingController(
      text: widget.saveOnCommit
          ? freeCategoryName(
              i.name,
              ref.read(categoriesProvider(widget.streamId)).valueOrNull ??
                  const <Category>[],
            )
          : i.name,
    );
    _amount = TextEditingController(text: i.amount?.toString() ?? '');
    _total = TextEditingController(text: i.targetTotal?.toString() ?? '');
    _interval = TextEditingController(text: i.interval?.toString() ?? '');
    _count = TextEditingController(text: i.occurrenceCount?.toString() ?? '');
    _direction = widget.creditOnly ? EventDirection.credit : i.direction;
    _unit = i.unit;
    _rounding = i.rounding;
    _startDate = i.startDate;
    _endDate = i.endDate;
    _scheduleSolve(immediate: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _amount.dispose();
    _total.dispose();
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
      _intError(_interval) != null ||
      _intError(_count) != null;

  SolveRequest _request() => SolveRequest(
    name: _name.text.trim().isEmpty ? widget.initial.name : _name.text.trim(),
    direction: _direction,
    unit: _unit,
    startDate: _startDate,
    endDate: _endDate,
    amount: _parseMoney(_amount),
    targetTotal: _parseMoney(_total),
    interval: _parseInt(_interval),
    occurrenceCount: _parseInt(_count),
    rounding: _rounding,
  );

  /// What the user typed in the shared schedule fields.
  PlanSchedule get schedule => PlanSchedule(
    startDate: _startDate,
    endDate: _endDate,
    amount: _parseMoney(_amount)?.toDouble(),
    interval: _parseInt(_interval),
    unit: _unit,
    count: _parseInt(_count),
  );

  /// Takes the shared schedule from the other mode and solves. Only income
  /// is planned here, so a negative amount is left out.
  set schedule(PlanSchedule v) {
    _startDate = v.startDate;
    _endDate = v.endDate;
    final a = v.amount;
    _amount.text = a == null || a <= 0 ? '' : planAmountText(a);
    _interval.text = v.interval?.toString() ?? '';
    _unit = v.unit;
    _count.text = v.count?.toString() ?? '';
    if (mounted) _changed();
  }

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
      final repo = ref.read(streamRepositoryProvider);
      final (result, defaulted) = await solveWithDefaults(
        _request(),
        (r) => repo.solve(widget.streamId, r),
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
    final t = _result?.event;
    cb(t?.copyWith(streamId: widget.streamId, direction: _direction));
  }

  /// Every [− N +] [unit ▾] (shared with the event editor). A blank
  /// N is calculated (✦) and shows as a hint.
  Widget _frequencyField(int? calculated) {
    final auto = _isSolved(SolveVar.interval) ? calculated : null;
    final typed = _parseInt(_interval);
    return RecurrenceIntervalField(
      keyPrefix: 'plan',
      caption: 'Frequency',
      controller: _interval,
      unit: _unit,
      autoInterval: auto,
      allowBlank: true,
      highlight: _isWanted(SolveVar.interval),
      errorText: _intError(_interval),
      helperText: typed == null && auto != null
          ? '✦ Calculated: every $auto ${unitLabel(_unit, auto)}'
          : 'Leave the number blank to find the spacing that fits',
      onChanged: _changed,
      onUnitChanged: (u) {
        _unit = u;
        _changed();
      },
      onClear: () {
        _interval.clear();
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
                widget.creditOnly ? 'Plan income' : 'Plan an event',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
            ],
            Text(
              widget.creditOnly
                  ? 'Spread a total over payments coming in. Fill in what '
                        'you know — blank fields are calculated (✦) and update '
                        'as you type. Clear a field to have it calculated again.'
                  : 'Fill in what you know and leave the rest blank — blank '
                        'fields are calculated. Any four of start date, total, '
                        'amount each time, frequency, count and end date determine '
                        'the event.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('plan-name'),
              controller: _name,
              onChanged: (_) => setState(() => _nameTaken = null),
              decoration: InputDecoration(
                labelText: 'Name',
                helperText: _nameProblem == null && widget.saveOnCommit
                    ? 'Its events get a new category with this name'
                    : null,
                errorText: _nameProblem,
              ),
            ),
            if (!widget.creditOnly) ...[
              const SizedBox(height: 12),
              SegmentedButton<EventDirection>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: EventDirection.credit,
                    label: Text('Credit'),
                    icon: Icon(Icons.arrow_upward),
                  ),
                  ButtonSegment(
                    value: EventDirection.debit,
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
            _MoneyField(
              key: const ValueKey('plan-total'),
              controller: _total,
              label: 'Total amount',
              help: 'Sum of every payment',
              calculated: _isSolved(SolveVar.total) ? values?.total : null,
              wanted: _isWanted(SolveVar.total),
              error: _moneyError(_total),
              onChanged: _changed,
            ),
            const SizedBox(height: 12),
            // The schedule, in the same order as "Reach a balance".
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
            const SizedBox(height: 12),
            _MoneyField(
              key: const ValueKey('plan-amount'),
              controller: _amount,
              label: 'Amount each time',
              help: 'Amount of each payment',
              calculated: _isSolved(SolveVar.amount) ? values?.amount : null,
              wanted: _isWanted(SolveVar.amount),
              error: _moneyError(_amount),
              onChanged: _changed,
            ),
            const SizedBox(height: 16),
            _frequencyField(values?.interval),
            const SizedBox(height: 12),
            _IntField(
              controller: _count,
              label: 'Count',
              suffix: 'times',
              help: 'How many payments, including the first',
              calculated: _isSolved(SolveVar.count) ? values?.count : null,
              wanted: _isWanted(SolveVar.count),
              error: _intError(_count),
              onChanged: _changed,
            ),
            if (_total.text.trim().isNotEmpty) ...[
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
            // A complete plan shows no summary: the fields already say it.
            if (_StatusPanel.shows(_result, _error)) ...[
              _StatusPanel(result: _result, error: _error, solving: _solving),
              const SizedBox(height: 20),
            ],
            FilledButton(
              key: const ValueKey('solve-commit'),
              onPressed:
                  !(widget.readOnly && widget.saveOnCommit) &&
                      _result?.isComplete == true &&
                      !_solving &&
                      !_saving &&
                      _nameProblem == null
                  ? _commit
                  : null,
              child: Text(
                widget.readOnly && widget.saveOnCommit
                    ? 'View only: can’t create'
                    : _saving
                    ? 'Saving…'
                    : (!widget.saveOnCommit
                          ? 'Use these values'
                          // Docked in the Plan view: the same words as
                          // "Reach a balance".
                          : widget.onPreview != null
                          ? 'Add plan to stream'
                          : 'Create event'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The server said the name is taken (someone else made it meanwhile).
  String? _nameTaken;

  /// Why the plan's name can't name its new category (saving only).
  String? get _nameProblem {
    if (!widget.saveOnCommit || widget.readOnly) return null;
    if (_nameTaken != null) return _nameTaken;
    final list = ref.watch(categoriesProvider(widget.streamId)).valueOrNull;
    if (list == null) return null;
    final name = _name.text.trim().isEmpty ? widget.initial.name : _name.text;
    return categoryNameProblem(name, list);
  }

  Future<void> _commit() async {
    final result = _result;
    final event = result?.event;
    if (result == null || event == null) return;
    if (_nameProblem != null) return;
    final named = event.copyWith(
      streamId: widget.streamId,
      name: _name.text.trim().isEmpty ? widget.initial.name : _name.text.trim(),
      direction: _direction,
    );

    if (!widget.saveOnCommit) {
      final done = _withEvent(result, named);
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
          .read(eventsProvider(widget.streamId).notifier)
          .create(
            named,
            newCategory: (
              name: normalizeCategoryName(named.name),
              color: pickCategoryColor(
                ref.read(categoriesProvider(widget.streamId)).valueOrNull ??
                    const <Category>[],
              ),
            ),
          );
      if (mounted) {
        final done = _withEvent(
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
          if (error is ApiException && error.statusCode == 409) {
            _nameTaken = 'A category with this name already exists';
          } else {
            _error = friendlyError(error);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  SolveResult _withEvent(
    SolveResult result,
    BudgetEvent event, {
    String? message,
  }) => SolveResult(
    event: event,
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

  @override
  Widget build(BuildContext context) {
    final hasValue = controller.text.trim().isNotEmpty;
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
  });

  /// Whether there is anything to say: an error, solving / invalid input,
  /// already on track, or a hint for the missing fields. A complete plan
  /// shows no panel at all.
  static bool shows(SolveResult? result, String? error) =>
      error != null || result == null || result.onTrack || !result.isComplete;

  final SolveResult? result;
  final String? error;
  final bool solving;

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
    if (r != null && r.onTrack) {
      return _panel(
        context,
        color: scheme.secondaryContainer,
        icon: Icons.verified_outlined,
        iconColor: AppTheme.creditColor,
        children: [Text(r.message ?? 'Already on track.')],
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

    // Complete: the parent leaves the panel out ([shows] is false).
    return const SizedBox.shrink();
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
