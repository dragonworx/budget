import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/money_text.dart';
import '../../widgets/ui.dart';
import '../timeline/occurrence_dates.dart';
import '../timeline/occurrence_info.dart';
import 'solve_sheet.dart';

enum EditorAction { created, saved, deleted, skipsChanged }

/// What happened in one editor session, so callers can report it
/// accurately (and offer undo).
class EditorOutcome {
  const EditorOutcome({
    required this.action,
    required this.transaction,
    this.previous,
    this.skipped = const {},
    this.restored = const {},
    this.skippedBefore = const {},
  });

  final EditorAction action;

  /// Created / saved / deleted series (for skips: the series).
  final Transaction transaction;

  /// The series as it was before a save (for undo).
  final Transaction? previous;

  /// Occurrences newly skipped / restored in this session.
  final Set<DateTime> skipped;
  final Set<DateTime> restored;

  /// Skipped occurrences when the editor opened (to restore after undoing
  /// a delete).
  final Set<DateTime> skippedBefore;
}

/// Opens the transaction series editor as a side panel.
///
/// [focusDate] is the occurrence the user clicked on the timeline: it is
/// highlighted in the preview and offers skip / unskip. [skippedDates] are
/// that series' currently skipped occurrences. Returns the saved (or
/// deleted) transaction when anything changed, else null.
Future<EditorOutcome?> showTransactionEditor(
  BuildContext context, {
  required String accountId,
  Transaction? existing,
  DateTime? initialDate,
  bool onceOnly = false,
  DateTime? focusDate,
  Set<DateTime> skippedDates = const {},
  String currency = '',
}) {
  return showSidePanel<EditorOutcome>(
    context,
    label: existing == null ? 'New transaction' : 'Edit transaction',
    builder: (context) => TransactionEditor(
      accountId: accountId,
      existing: existing,
      initialDate: initialDate,
      onceOnly: onceOnly,
      focusDate: focusDate,
      skippedDates: skippedDates,
      currency: currency,
    ),
  );
}

class TransactionEditor extends ConsumerStatefulWidget {
  const TransactionEditor({
    super.key,
    required this.accountId,
    this.existing,
    this.initialDate,
    this.onceOnly = false,
    this.focusDate,
    this.skippedDates = const {},
    this.currency = '',
    this.onDone,
    this.onClosePanel,
  });

  /// Called instead of popping the route when embedded in another panel.
  final ValueChanged<EditorOutcome?>? onDone;

  /// When embedded: closes the whole host panel (the X button).
  final ValueChanged<EditorOutcome?>? onClosePanel;

  final String accountId;
  final Transaction? existing;
  final DateTime? initialDate;
  final bool onceOnly;
  final DateTime? focusDate;
  final Set<DateTime> skippedDates;
  final String currency;

  @override
  ConsumerState<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends ConsumerState<TransactionEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _interval;
  late final TextEditingController _count;
  late TransactionDirection _direction;
  late RecurrenceMode _recurrenceMode;
  late RecurrenceUnit _unit;
  late EndMode _endMode;
  late DateTime _startDate;
  DateTime? _endDate;
  late bool _enabled;
  bool _saving = false;
  String? _endDateError;
  late Set<DateTime> _skipped;
  final Set<DateTime> _skipBusy = {};

  late Set<DateTime> _skippedInitially;
  late String _initialSignature;

  /// Whether the count field holds a user value rather than the default.
  late bool _countEdited;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _amount = TextEditingController(text: existing?.amount.toString() ?? '');
    _interval = TextEditingController(
      text: (existing?.interval ?? 1).toString(),
    );
    _count = TextEditingController(
      text: (existing?.occurrenceCount ?? 12).toString(),
    );
    _countEdited = existing?.occurrenceCount != null;
    _direction = existing?.direction ?? TransactionDirection.debit;
    _recurrenceMode = widget.onceOnly
        ? RecurrenceMode.once
        : (existing?.recurrenceMode ?? RecurrenceMode.every);
    _unit = existing?.unit ?? RecurrenceUnit.months;
    _endMode = existing?.endMode ?? EndMode.never;
    if (existing == null && _recurrenceMode == RecurrenceMode.once) {
      _endMode = EndMode.never;
    }
    final start = existing?.startDate ?? widget.initialDate ?? DateTime.now();
    _startDate = DateTime(start.year, start.month, start.day);
    _endDate = existing?.endDate;
    _enabled = existing?.enabled ?? true;
    _skipped = {for (final d in widget.skippedDates) _day(d)};
    _skippedInitially = {..._skipped};
    _initialSignature = _signature();
    // Take focus even when swapped in place of another widget, so Esc and
    // Ctrl+Enter reach this editor's shortcuts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isNew) {
        _nameFocus.requestFocus();
      } else if (!_scope.hasFocus) {
        _scope.requestFocus();
      }
    });
  }

  final _scope = FocusScopeNode(debugLabel: 'TransactionEditor');
  final _nameFocus = FocusNode(debugLabel: 'editor-name');

  /// Everything the form would save, to detect unsaved edits.
  String _signature() {
    final d = _draft();
    return [
      d.name,
      d.direction,
      _amount.text.trim(),
      d.startDate,
      d.recurrenceMode,
      d.interval,
      d.unit,
      d.endMode,
      d.endDate,
      d.occurrenceCount,
      d.enabled,
    ].join('|');
  }

  bool get _dirty => _signature() != _initialSignature;

  EditorOutcome? _outcome(EditorAction? action, [Transaction? t]) {
    final added = _skipped.difference(_skippedInitially);
    final removed = _skippedInitially.difference(_skipped);
    final existing = widget.existing;
    if (action == null) {
      if (existing == null || (added.isEmpty && removed.isEmpty)) return null;
      action = EditorAction.skipsChanged;
    }
    return EditorOutcome(
      action: action,
      transaction: t ?? existing!,
      previous: existing,
      skipped: added,
      restored: removed,
      skippedBefore: _skippedInitially,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _interval.dispose();
    _count.dispose();
    _scope.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  int get _intervalValue => int.tryParse(_interval.text.trim()) ?? 1;

  Transaction _draft({Decimal? amount, int? count, DateTime? endDate}) {
    final parsedAmount =
        amount ?? parseMoneyInput(_amount.text) ?? Decimal.zero;
    final repeating = _recurrenceMode == RecurrenceMode.every;
    final endMode = repeating ? _endMode : EndMode.never;
    return Transaction(
      id: widget.existing?.id ?? 'preview',
      accountId: widget.accountId,
      name: _name.text.trim(),
      direction: _direction,
      amount: parsedAmount,
      startDate: _startDate,
      recurrenceMode: _recurrenceMode,
      interval: repeating ? _intervalValue : null,
      unit: repeating ? _unit : null,
      endMode: endMode,
      endDate: endMode == EndMode.untilDate ? (endDate ?? _endDate) : null,
      occurrenceCount: endMode == EndMode.count
          ? (count ?? int.tryParse(_count.text.trim()) ?? 1)
          : null,
      enabled: _enabled,
    );
  }

  int? _finiteCount(Transaction draft) {
    if (draft.recurrenceMode == RecurrenceMode.once) return 1;
    if (draft.endMode == EndMode.count) return draft.occurrenceCount;
    if (draft.endMode == EndMode.untilDate && draft.endDate != null) {
      final dates = estimateOccurrenceDates(draft, maxCount: 5000);
      return dates.isEmpty ? null : dates.length;
    }
    return null;
  }

  void _finish(EditorOutcome? outcome, {bool closePanel = false}) {
    if (closePanel && widget.onClosePanel != null) {
      widget.onClosePanel!(outcome);
    } else if (widget.onDone != null) {
      widget.onDone!(outcome);
    } else {
      Navigator.of(context).pop(outcome);
    }
  }

  /// Cancel / Esc / close: confirms before discarding unsaved edits.
  Future<void> _close({bool closePanel = false}) async {
    if (_saving) return;
    if (_dirty) {
      final discard = await showConfirmDialog(
        context,
        title: 'Discard changes?',
        message: _isNew
            ? 'This transaction has not been created yet.'
            : 'Your edits to this series have not been saved.',
        confirmLabel: 'Discard',
      );
      if (!discard || !mounted) return;
    }
    _finish(_outcome(null), closePanel: closePanel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = _draft();
    final title = _isNew
        ? 'New transaction'
        : (widget.existing!.name.isEmpty
              ? 'Untitled series'
              : widget.existing!.name);

    return PopScope(
      // Barrier clicks / system back go through the discard check too.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close(closePanel: widget.onClosePanel != null);
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
        },
        child: FocusScope(
          node: _scope,
          autofocus: true,
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(theme, title),
                const Divider(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                    children: [
                      if (widget.focusDate != null && !_isNew) ...[
                        _focusBanner(theme),
                        const SizedBox(height: 12),
                      ],
                      _detailsSection(theme),
                      const SizedBox(height: 12),
                      _scheduleSection(theme),
                      const SizedBox(height: 12),
                      _previewSection(theme, draft),
                      const SizedBox(height: 12),
                      _optionsSection(theme),
                    ],
                  ),
                ),
                const Divider(),
                _footer(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, String title) {
    return Padding(
      padding: EdgeInsets.fromLTRB(widget.onDone != null ? 4 : 16, 12, 8, 12),
      child: Row(
        children: [
          if (widget.onDone != null) ...[
            IconButton(
              key: const ValueKey('editor-back'),
              tooltip: 'Back to list (Esc)',
              onPressed: _close,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 4),
          ],
          DirectionBadge(
            credit: _direction == TransactionDirection.credit,
            muted: !_enabled,
            size: 36,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isNew ? 'NEW' : 'TRANSACTION SERIES',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1,
                    color: AppTheme.textFaint,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('editor-close'),
            tooltip: widget.onClosePanel != null
                ? 'Close panel'
                : 'Close (Esc)',
            onPressed: () => _close(closePanel: true),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _focusBanner(ThemeData theme) {
    final date = _day(widget.focusDate!);
    final skipped = _skipped.contains(date);
    final busy = _skipBusy.contains(date);
    return Container(
      key: const ValueKey('focus-banner'),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: AppTheme.panel(
        color: AppTheme.accentSoft.withValues(alpha: 0.6),
        edge: AppTheme.accent.withValues(alpha: 0.4),
      ),
      child: Row(
        children: [
          const Icon(Icons.event_rounded, size: 18, color: AppTheme.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Occurrence on ${formatOccurrenceDate(date)}',
                  style: theme.textTheme.labelLarge,
                ),
                Text(
                  skipped
                      ? 'Skipped: it does not affect the balance'
                      : 'Edits below change the whole series',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          TextButton.icon(
            key: const ValueKey('skip-occurrence'),
            onPressed: busy ? null : () => _toggleSkip(date),
            icon: Icon(
              skipped ? Icons.replay_rounded : Icons.block_rounded,
              size: 18,
            ),
            label: Text(skipped ? 'Unskip' : 'Skip this one'),
          ),
        ],
      ),
    );
  }

  Widget _detailsSection(ThemeData theme) {
    final symbol = widget.currency.isEmpty
        ? ''
        : MoneyText.symbolFor(widget.currency).trim();
    return SectionCard(
      title: 'Details',
      icon: Icons.edit_note_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            key: const ValueKey('editor-name'),
            controller: _name,
            autofocus: _isNew,
            focusNode: _nameFocus,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Rent, Salary, Groceries…',
            ),
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _save(),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          SegmentedButton<TransactionDirection>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: TransactionDirection.credit,
                label: Text('Money in'),
                icon: Icon(Icons.south_west_rounded, size: 18),
              ),
              ButtonSegment(
                value: TransactionDirection.debit,
                label: Text('Money out'),
                icon: Icon(Icons.north_east_rounded, size: 18),
              ),
            ],
            selected: {_direction},
            onSelectionChanged: (value) =>
                setState(() => _direction = value.first),
            style: ButtonStyle(
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (!states.contains(WidgetState.selected)) {
                  return AppTheme.textMuted;
                }
                return _direction == TransactionDirection.credit
                    ? AppTheme.creditColor
                    : AppTheme.debitColor;
              }),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (!states.contains(WidgetState.selected)) {
                  return AppTheme.surface;
                }
                return _direction == TransactionDirection.credit
                    ? AppTheme.creditSoft
                    : AppTheme.debitSoft;
              }),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('editor-amount'),
            controller: _amount,
            decoration: InputDecoration(
              labelText: _recurrenceMode == RecurrenceMode.every
                  ? 'Amount each time'
                  : 'Amount',
              prefixText: symbol.isEmpty ? null : '$symbol ',
              hintText: '0.00',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _save(),
            onChanged: (_) => setState(() {}),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Enter an amount';
              }
              final amount = parseMoneyInput(value);
              if (amount == null) {
                return 'Enter a number, e.g. 1250 or 1,250.50';
              }
              if (amount == Decimal.zero) return 'Enter an amount above zero';
              if (amount < Decimal.zero) {
                return 'Use Money out instead of a negative amount';
              }
              return null;
            },
          ),
        ],
      ),
    );
  }

  Widget _dateField({
    required Key key,
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime> onPicked,
    DateTime? first,
    String? error,
  }) {
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? first ?? _startDate,
          firstDate: first ?? DateTime(1970),
          lastDate: DateTime(2100),
        );
        if (picked != null) onPicked(_day(picked));
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          errorText: error,
          suffixIcon: const Icon(Icons.calendar_month_rounded, size: 18),
        ),
        child: Text(
          value == null ? 'Pick a date' : formatOccurrenceDate(value),
          style: TextStyle(
            color: value == null ? AppTheme.textFaint : AppTheme.text,
          ),
        ),
      ),
    );
  }

  Widget _scheduleSection(ThemeData theme) {
    final repeating = _recurrenceMode == RecurrenceMode.every;
    return SectionCard(
      title: 'Schedule',
      icon: Icons.event_repeat_rounded,
      trailing: Text(
        describeRecurrence(_draft()),
        style: theme.textTheme.labelMedium?.copyWith(color: AppTheme.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _dateField(
            key: const ValueKey('editor-start'),
            label: repeating ? 'Starts (first occurrence)' : 'Date',
            value: _startDate,
            onPicked: (d) => setState(() => _startDate = d),
          ),
          const SizedBox(height: 12),
          SegmentedButton<RecurrenceMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: RecurrenceMode.once,
                label: Text('One-off'),
                icon: Icon(Icons.looks_one_outlined, size: 18),
              ),
              ButtonSegment(
                value: RecurrenceMode.every,
                label: Text('Repeats'),
                icon: Icon(Icons.repeat_rounded, size: 18),
              ),
            ],
            selected: {_recurrenceMode},
            onSelectionChanged: (value) => setState(() {
              _recurrenceMode = value.first;
              if (_recurrenceMode == RecurrenceMode.once) {
                _endMode = EndMode.never;
                _endDateError = null;
              }
            }),
          ),
          if (repeating) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Text('Every', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 8),
                _stepButton(
                  Icons.remove_rounded,
                  'Fewer',
                  _intervalValue <= 1
                      ? null
                      : () => setState(
                          () => _interval.text = '${_intervalValue - 1}',
                        ),
                ),
                SizedBox(
                  width: 56,
                  child: TextFormField(
                    key: const ValueKey('editor-interval'),
                    controller: _interval,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      if (_recurrenceMode != RecurrenceMode.every) return null;
                      final n = int.tryParse(value ?? '');
                      return n == null || n < 1 ? '≥ 1' : null;
                    },
                  ),
                ),
                _stepButton(
                  Icons.add_rounded,
                  'More',
                  () =>
                      setState(() => _interval.text = '${_intervalValue + 1}'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<RecurrenceUnit>(
                    key: const ValueKey('editor-unit'),
                    initialValue: _unit,
                    isDense: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    dropdownColor: AppTheme.overlay,
                    items: [
                      for (final unit in RecurrenceUnit.values)
                        DropdownMenuItem(
                          value: unit,
                          child: Text(_unitPlural(unit, _intervalValue)),
                        ),
                    ],
                    onChanged: (u) => setState(() => _unit = u ?? _unit),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text('Ends', style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            SegmentedButton<EndMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: EndMode.never, label: Text('Never')),
                ButtonSegment(value: EndMode.untilDate, label: Text('On date')),
                ButtonSegment(value: EndMode.count, label: Text('After…')),
              ],
              selected: {_endMode},
              onSelectionChanged: (value) => setState(() {
                _endMode = value.first;
                _endDateError = null;
                if (_endMode != EndMode.untilDate) _endDate = null;
              }),
            ),
            if (_endMode == EndMode.untilDate) ...[
              const SizedBox(height: 12),
              _dateField(
                key: const ValueKey('editor-end'),
                label: 'Last possible date',
                value: _endDate,
                first: _startDate,
                error: _endDateError,
                onPicked: (d) => setState(() {
                  _endDate = d;
                  _endDateError = null;
                }),
              ),
            ],
            if (_endMode == EndMode.count) ...[
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('editor-count'),
                controller: _count,
                decoration: const InputDecoration(
                  labelText: 'Number of occurrences',
                  helperText: 'Includes the first one',
                  suffixText: 'times',
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() => _countEdited = true),
                onFieldSubmitted: (_) => _save(),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: (value) {
                  if (_endMode != EndMode.count) return null;
                  final n = int.tryParse(value ?? '');
                  return n == null || n < 1 ? 'At least 1' : null;
                },
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _stepButton(IconData icon, String tooltip, VoidCallback? onPressed) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 18),
    );
  }

  Widget _previewSection(ThemeData theme, Transaction draft) {
    final all = estimateOccurrenceDates(draft, maxCount: 400);
    final focus = widget.focusDate == null ? null : _day(widget.focusDate!);
    final today = _day(DateTime.now());
    var from = 0;
    if (focus != null && all.contains(focus)) {
      from = (all.indexOf(focus) - 2).clamp(0, all.length);
    } else {
      final upcoming = all.indexWhere((d) => !d.isBefore(today));
      if (upcoming > 0) from = upcoming;
    }
    final shown = all.skip(from).take(8).toList();
    final amount = parseMoneyInput(_amount.text);
    final count = _finiteCount(draft);
    final symbolAmount = amount == null
        ? null
        : formatSignedAmount(
            (_direction == TransactionDirection.credit ? 1 : -1) *
                amount.toDouble(),
            widget.currency.isEmpty ? 'AUD' : widget.currency,
          );
    String? total;
    if (amount != null && count != null && count > 1) {
      final sum =
          (_direction == TransactionDirection.credit ? 1 : -1) *
          amount.toDouble() *
          count;
      total =
          '${formatSignedAmount(sum, widget.currency.isEmpty ? 'AUD' : widget.currency)} over $count occurrences';
    }
    return SectionCard(
      title: 'Occurrences',
      icon: Icons.timeline_rounded,
      trailing: symbolAmount == null
          ? null
          : Text(
              '$symbolAmount each',
              style: theme.textTheme.labelMedium?.copyWith(
                color: _direction == TransactionDirection.credit
                    ? AppTheme.creditColor
                    : AppTheme.debitColor,
                fontWeight: FontWeight.w700,
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (shown.isEmpty)
            Text('No occurrences', style: theme.textTheme.bodySmall)
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final d in shown) _occurrenceChip(theme, d, focus),
              ],
            ),
          const SizedBox(height: 10),
          Text(
            [
              ?total,
              if (draft.recurrenceMode == RecurrenceMode.every &&
                  draft.endMode == EndMode.never)
                'Repeats with no end',
              if (!_isNew) 'Click a date to skip or restore it',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _occurrenceChip(ThemeData theme, DateTime date, DateTime? focus) {
    final skipped = _skipped.contains(date);
    final isFocus = date == focus;
    final busy = _skipBusy.contains(date);
    final canToggle = !_isNew && _sameScheduleAsSaved();
    final label = Text(
      formatOccurrenceDate(date),
      style: theme.textTheme.labelMedium?.copyWith(
        color: skipped
            ? AppTheme.textFaint
            : (isFocus ? AppTheme.accent : AppTheme.text),
        decoration: skipped ? TextDecoration.lineThrough : null,
        fontWeight: isFocus ? FontWeight.w700 : FontWeight.w500,
      ),
    );
    return Tooltip(
      message: !canToggle
          ? (_isNew
                ? 'Save first to skip dates'
                : 'Save schedule changes first')
          : (skipped ? 'Restore this occurrence' : 'Skip this occurrence'),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: canToggle && !busy ? () => _toggleSkip(date) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isFocus ? AppTheme.accentSoft : AppTheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isFocus ? AppTheme.accent : AppTheme.border,
              width: isFocus ? 1.5 : 1,
            ),
          ),
          child: label,
        ),
      ),
    );
  }

  /// Skips are stored per date; only offer them while the dates shown match
  /// the saved schedule.
  bool _sameScheduleAsSaved() {
    final e = widget.existing;
    if (e == null) return false;
    final d = _draft();
    return _day(e.startDate) == _day(d.startDate) &&
        e.recurrenceMode == d.recurrenceMode &&
        e.interval == d.interval &&
        e.unit == d.unit &&
        e.endMode == d.endMode &&
        e.endDate == d.endDate &&
        e.occurrenceCount == d.occurrenceCount;
  }

  Widget _optionsSection(ThemeData theme) {
    return SectionCard(
      title: 'Options',
      icon: Icons.tune_rounded,
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include in balance'),
            subtitle: Text(
              _enabled
                  ? 'Counts towards the timeline'
                  : 'Disabled: kept but ignored',
              style: theme.textTheme.bodySmall,
            ),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _saving ? null : _openPlanner,
              icon: const Icon(Icons.calculate_outlined, size: 18),
              label: const Text('Solve from a target total…'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 16, 12),
      child: LayoutBuilder(
        builder: (context, c) {
          // Narrow panels: icon-only delete, no shortcut hint.
          final roomy = c.maxWidth >= 430;
          return Row(
            children: [
              if (!_isNew)
                roomy
                    ? TextButton.icon(
                        key: const ValueKey('editor-delete'),
                        onPressed: _saving ? null : _delete,
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.debitColor,
                        ),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                        label: const Text('Delete'),
                      )
                    : IconButton(
                        key: const ValueKey('editor-delete'),
                        tooltip: 'Delete series',
                        color: AppTheme.debitColor,
                        onPressed: _saving ? null : _delete,
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
              const Spacer(),
              if (roomy) ...[
                Tooltip(
                  message: 'Ctrl+Enter (⌘+Enter on Mac) saves',
                  child: Text('Ctrl+Enter', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 10),
              ],
              TextButton(onPressed: _close, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('editor-save'),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(_saving ? 'Saving…' : (_isNew ? 'Create' : 'Save')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _toggleSkip(DateTime date) async {
    final existing = widget.existing;
    if (existing == null) return;
    final skip = !_skipped.contains(date);
    setState(() => _skipBusy.add(date));
    try {
      await ref
          .read(transactionsProvider(widget.accountId).notifier)
          .setSkip(existing.id, date, skipped: skip);
      setState(() {
        skip ? _skipped.add(date) : _skipped.remove(date);
      });
    } catch (error) {
      _toast(error);
    } finally {
      if (mounted) setState(() => _skipBusy.remove(date));
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing!;
    final ok = await showConfirmDialog(
      context,
      title: 'Delete this series?',
      message:
          '“${existing.name.isEmpty ? 'Untitled' : existing.name}” and all of '
          'its occurrences will be removed from the timeline.',
      confirmLabel: 'Delete',
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(transactionsProvider(widget.accountId).notifier)
          .delete(existing.id);
      if (mounted) _finish(_outcome(EditorAction.deleted, existing));
    } catch (error) {
      _toast(error);
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(friendlyError(error))));
  }

  Future<void> _openPlanner() async {
    final repeating = _recurrenceMode == RecurrenceMode.every;
    final amount = parseMoneyInput(_amount.text);
    final result = await showSolveSheet(
      context,
      accountId: widget.accountId,
      saveOnCommit: false,
      initial: SolveRequest(
        name: _name.text.trim(),
        direction: _direction,
        unit: repeating ? _unit : RecurrenceUnit.weeks,
        interval: repeating ? _intervalValue : 1,
        startDate: _startDate,
        amount: amount != null && amount > Decimal.zero ? amount : null,
        endDate: repeating && _endMode == EndMode.untilDate ? _endDate : null,
        occurrenceCount: repeating && _endMode == EndMode.count && _countEdited
            ? int.tryParse(_count.text.trim())
            : null,
      ),
    );
    final transaction = result?.transaction;
    if (transaction == null || !mounted) return;
    setState(() {
      _name.text = transaction.name;
      _direction = transaction.direction;
      _amount.text = transaction.amount.toString();
      _startDate = _day(transaction.startDate);
      _recurrenceMode = transaction.recurrenceMode;
      _endDateError = null;
      if (transaction.recurrenceMode == RecurrenceMode.once) {
        _endMode = EndMode.never;
        _endDate = null;
        return;
      }
      _interval.text = '${transaction.interval ?? 1}';
      _unit = transaction.unit ?? _unit;
      _endMode = transaction.endMode;
      _endDate = transaction.endDate;
      if (transaction.occurrenceCount != null) {
        _count.text = '${transaction.occurrenceCount}';
        _countEdited = true;
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _endDateError = null);
    if (!_formKey.currentState!.validate()) return;
    if (_recurrenceMode == RecurrenceMode.every &&
        _endMode == EndMode.untilDate &&
        _endDate == null) {
      setState(() => _endDateError = 'Pick an end date');
      return;
    }
    if (_endDate != null && _endDate!.isBefore(_startDate)) {
      setState(() => _endDateError = 'Must be on or after the start date');
      return;
    }

    final draft = _draft(amount: parseMoneyInput(_amount.text)!).copyWith(
      id: widget.existing?.id ?? const Uuid().v4(),
      accountId: widget.accountId,
      name: _name.text.trim(),
      direction: _direction,
      startDate: _startDate,
      enabled: _enabled,
    );

    setState(() => _saving = true);
    try {
      final notifier = ref.read(
        transactionsProvider(widget.accountId).notifier,
      );
      final Transaction saved;
      if (widget.existing == null) {
        saved = await notifier.create(draft);
      } else {
        await notifier.updateTransaction(draft);
        saved = draft;
      }
      if (mounted) {
        _finish(
          _outcome(
            widget.existing == null ? EditorAction.created : EditorAction.saved,
            saved,
          ),
        );
      }
    } catch (error) {
      _toast(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

String _unitPlural(RecurrenceUnit unit, [int count = 2]) {
  final one = count == 1;
  return switch (unit) {
    RecurrenceUnit.days => one ? 'day' : 'days',
    RecurrenceUnit.weeks => one ? 'week' : 'weeks',
    RecurrenceUnit.months => one ? 'month' : 'months',
    RecurrenceUnit.years => one ? 'year' : 'years',
  };
}
