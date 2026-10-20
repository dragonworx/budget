import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../widgets/conflict_dialog.dart';
import '../../state/realtime_providers.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/account_picker.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/money_text.dart';
import '../../widgets/ui.dart';
import '../timeline/occurrence_dates.dart';
import '../timeline/occurrence_info.dart';
import 'solve_sheet.dart';

enum EditorAction {
  created,
  saved,
  deleted,
  skipsChanged,

  /// Save once-off: one occurrence ([EditorOutcome.date]) overridden.
  overridden,

  /// One occurrence's override cleared (back to the series value).
  overrideCleared,

  /// Every override of the series cleared.
  overridesCleared,

  /// From now on: the series was split at [EditorOutcome.date].
  split,
}

/// The editor's save choices on a repeating series' occurrence.
enum SaveOption { series, onceOff, fromNowOn }

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
    this.date,
    this.original,
  });

  final EditorAction action;

  /// The occurrence an override / split applies to.
  final DateTime? date;

  /// Split: the original series as shortened (it now ends the day before
  /// [date]); [transaction] is the new series (or, on the first occurrence,
  /// the updated whole series).
  final Transaction? original;

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
  DateTime? initialEndDate,
  bool onceOnly = false,
  DateTime? focusDate,
  Set<DateTime> skippedDates = const {},
  bool readOnly = false,
}) {
  return showSidePanel<EditorOutcome>(
    context,
    label: existing == null ? 'New transaction' : 'Edit transaction',
    builder: (context) => TransactionEditor(
      accountId: accountId,
      existing: existing,
      initialDate: initialDate,
      initialEndDate: initialEndDate,
      onceOnly: onceOnly,
      focusDate: focusDate,
      skippedDates: skippedDates,
      readOnly: readOnly,
    ),
  );
}

class TransactionEditor extends ConsumerStatefulWidget {
  const TransactionEditor({
    super.key,
    required this.accountId,
    this.existing,
    this.initialDate,
    this.initialEndDate,
    this.onceOnly = false,
    this.focusDate,
    this.skippedDates = const {},
    this.onDone,
    this.onClosePanel,
    this.readOnly = false,
  });

  /// Viewer access: fields are shown but can't be changed or saved.
  final bool readOnly;

  /// Called instead of popping the route when embedded in another panel.
  final ValueChanged<EditorOutcome?>? onDone;

  /// When embedded: closes the whole host panel (the X button).
  final ValueChanged<EditorOutcome?>? onClosePanel;

  final String accountId;
  final Transaction? existing;
  final DateTime? initialDate;

  /// New repeating transaction only: pre-fill Ends "On date" with this day
  /// (inclusive, like the field itself), e.g. a selected period's end.
  final DateTime? initialEndDate;
  final bool onceOnly;
  final DateTime? focusDate;
  final Set<DateTime> skippedDates;
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

  /// Transfer mode: the series moves money between this account and
  /// [_transfer]'s account (the far side mirrors it with the opposite sign).
  late bool _transferMode;
  TransferLink? _transfer;
  String? _transferError;
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
    final id = widget.existing?.id;
    _openedEvent = id == null ? null : ref.read(remoteChangesProvider)[id]?.id;
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
    _transfer = existing?.transfer;
    _transferMode = _transfer != null;
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
    final presetEnd = widget.initialEndDate;
    if (existing == null &&
        presetEnd != null &&
        _recurrenceMode == RecurrenceMode.every) {
      _endMode = EndMode.untilDate;
      _endDate = DateTime(presetEnd.year, presetEnd.month, presetEnd.day);
    }
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
      d.transfer?.peerAccountId,
    ].join('|');
  }

  bool get _dirty => _signature() != _initialSignature;

  EditorOutcome? _outcome(
    EditorAction? action, [
    Transaction? t,
    DateTime? date,
    Transaction? original,
  ]) {
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
      date: date,
      original: original,
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
      transfer: _transferMode ? _transfer : null,
    );
  }

  _Kind get _kind => _transferMode
      ? _Kind.transfer
      : (_direction == TransactionDirection.credit
            ? _Kind.credit
            : _Kind.debit);

  bool get _receiving => _direction == TransactionDirection.credit;

  String? _projectName(String projectId) {
    final projects = ref.read(accountDirectoryProvider).value;
    for (final (project, _) in projects ?? const <(Project, List<Account>)>[]) {
      if (project.id == projectId) return project.name;
    }
    return null;
  }

  Widget _transferField(ThemeData theme) {
    final link = _transfer;
    final label = _receiving ? 'From account' : 'To account';
    final project = link?.peerProjectName;
    final inProject = project == null ? '' : ' ($project)';
    return AccountPicker(
      keyPrefix: 'transfer',
      title: label,
      excludeAccountId: widget.accountId,
      currentAccountId: link?.peerAccountId,
      onSelected: (a) => setState(() {
        _transferError = null;
        _transfer = TransferLink(
          id: link?.id,
          peerTransactionId: link?.peerTransactionId,
          peerAccountId: a.id,
          peerAccountName: a.name,
          peerProjectId: a.projectId,
          peerProjectName: _projectName(a.projectId),
        );
      }),
      builder: (context, open) => InkWell(
        key: const ValueKey('editor-transfer-account'),
        onTap: _saving ? null : open,
        borderRadius: BorderRadius.circular(10),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            errorText: _transferError,
            prefixIcon: const Icon(Icons.swap_horiz_rounded),
            suffixIcon: const Icon(Icons.arrow_drop_down_rounded),
            helperText: link == null
                ? null
                : (_receiving
                      ? 'Mirrors as money out of ${link.accountLabel}$inProject'
                      : 'Arrives as money in to ${link.accountLabel}$inProject'),
          ),
          child: Text(
            link == null
                ? 'Choose project › account'
                : '${_receiving ? 'From' : 'To'}: ${link.accountLabel}',
            style: link == null
                ? theme.textTheme.bodyLarge?.copyWith(color: AppTheme.textFaint)
                : theme.textTheme.bodyLarge,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
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
                      ?_remoteBanner(theme),
                      if (widget.focusDate != null && !_isNew) ...[
                        _focusBanner(theme),
                        const SizedBox(height: 12),
                      ],
                      if (widget.readOnly) ...[
                        const _ViewOnlyNote(),
                        const SizedBox(height: 12),
                      ],
                      _ro(_detailsSection(theme)),
                      const SizedBox(height: 12),
                      _ro(_scheduleSection(theme)),
                      const SizedBox(height: 12),
                      _previewSection(theme, draft),
                      const SizedBox(height: 12),
                      _ro(_optionsSection(theme)),
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

  /// Remote change event already known when the editor opened.
  int? _openedEvent;

  /// "Updated by X" when someone else changed this series while it's open
  /// (the form keeps your edits; saving then asks Reload / Overwrite).
  Widget? _remoteBanner(ThemeData theme) {
    final id = widget.existing?.id;
    if (id == null) return null;
    final ev = ref.watch(remoteChangesProvider)[id];
    if (ev == null || ev.id == _openedEvent) return null;
    final deleted = ev.action.endsWith('.deleted');
    final pid = ref.watch(accountProvider(widget.accountId)).valueOrNull?.projectId;
    final who = actorName(ref, pid, ev.actorId) ?? 'someone else';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: const ValueKey('editor-remote-banner'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.warning.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.sync_rounded, size: 16, color: AppTheme.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                deleted
                    ? 'Deleted by $who. Close to discard.'
                    : 'Updated by $who. Your edits are kept; saving will ask before overwriting.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.text),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ro(Widget child) => widget.readOnly
      ? IgnorePointer(child: ExcludeFocus(child: child))
      : child;

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

  String _signed(Decimal signed) =>
      formatSignedAmount(signed.toDouble());

  Widget _focusBanner(ThemeData theme) {
    final date = _day(widget.focusDate!);
    final skipped = _skipped.contains(date);
    final busy = _skipBusy.contains(date);
    final existing = widget.existing!;
    final override = existing.overrideOn(date);
    final String detail;
    if (skipped) {
      detail = 'Skipped: it does not affect the balance';
    } else if (override != null) {
      detail = 'Once-off ${_signed(override.signed)} on this date · '
          'series ${_signed(existing.signedAmount)}';
    } else if (_offerSaveOptions) {
      detail = 'Save changes the whole series. The arrow next to Save '
          'offers this date only, or from now on';
    } else {
      detail = 'Edits below change the whole series';
    }
    return Container(
      key: const ValueKey('focus-banner'),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      decoration: AppTheme.panel(
        color: AppTheme.accentSoft.withValues(alpha: 0.6),
        edge: AppTheme.accent.withValues(alpha: 0.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                override != null ? Icons.edit_calendar_rounded : Icons.event_rounded,
                size: 18,
                color: AppTheme.accent,
              ),
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
                      detail,
                      key: const ValueKey('focus-banner-detail'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!widget.readOnly)
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                if (override != null)
                  TextButton.icon(
                    key: const ValueKey('editor-clear-override'),
                    onPressed: _saving ? null : () => _clearOverride(date),
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: Text(
                      'Reset to series ${_signed(existing.signedAmount)}',
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
        ],
      ),
    );
  }

  Widget _detailsSection(ThemeData theme) {
    const symbol = moneySymbol;
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
          SegmentedButton<_Kind>(
            key: const ValueKey('editor-kind'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: _Kind.credit,
                label: Text('Money in'),
                icon: Icon(Icons.south_west_rounded, size: 18),
              ),
              ButtonSegment(
                value: _Kind.debit,
                label: Text('Money out'),
                icon: Icon(Icons.north_east_rounded, size: 18),
              ),
              ButtonSegment(
                value: _Kind.transfer,
                label: Text('Transfer', key: ValueKey('editor-kind-transfer')),
                icon: Icon(Icons.swap_horiz_rounded, size: 18),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (value) => setState(() {
              switch (value.first) {
                case _Kind.credit:
                  _transferMode = false;
                  _direction = TransactionDirection.credit;
                case _Kind.debit:
                  _transferMode = false;
                  _direction = TransactionDirection.debit;
                case _Kind.transfer:
                  _transferMode = true;
                  // A new transfer sends money out of this account; an
                  // existing receiving side keeps its direction.
                  if (widget.existing?.transfer == null) {
                    _direction = TransactionDirection.debit;
                  }
              }
              _transferError = null;
            }),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 6),
              ),
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (!states.contains(WidgetState.selected)) {
                  return AppTheme.textMuted;
                }
                return switch (_kind) {
                  _Kind.credit => AppTheme.creditColor,
                  _Kind.debit => AppTheme.debitColor,
                  _Kind.transfer => AppTheme.transferColor,
                };
              }),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (!states.contains(WidgetState.selected)) {
                  return AppTheme.surface;
                }
                return switch (_kind) {
                  _Kind.credit => AppTheme.creditSoft,
                  _Kind.debit => AppTheme.debitSoft,
                  _Kind.transfer => AppTheme.transferSoft,
                };
              }),
            ),
          ),
          if (_transferMode) ...[
            const SizedBox(height: 12),
            _transferField(theme),
          ],
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

  /// Once / Repeats: whether the series recurs at all.
  Widget _repeatsToggle() {
    return SegmentedButton<bool>(
      key: const ValueKey('editor-repeats'),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: false,
          label: Text('Once', key: ValueKey('editor-repeats-once')),
          icon: Icon(Icons.event_rounded, size: 18),
        ),
        ButtonSegment(
          value: true,
          label: Text('Repeats', key: ValueKey('editor-repeats-every')),
          icon: Icon(Icons.event_repeat_rounded, size: 18),
        ),
      ],
      selected: {_recurrenceMode == RecurrenceMode.every},
      onSelectionChanged: (v) => setState(() {
        if (v.first) {
          _recurrenceMode = RecurrenceMode.every;
        } else {
          _recurrenceMode = RecurrenceMode.once;
          _endMode = EndMode.never;
          _endDateError = null;
        }
      }),
    );
  }

  void _setInterval(int n) =>
      setState(() => _interval.text = '${n.clamp(1, maxRecurrenceInterval)}');

  /// Every [− N +] [unit ▾]: N from 1 to [maxRecurrenceInterval], typed or
  /// stepped; the unit reads singular for 1 ("Every 1 week").
  Widget _intervalRow(ThemeData theme) {
    final n = _intervalValue;
    return Row(
      children: [
        Text('Every', style: theme.textTheme.bodyMedium),
        const SizedBox(width: 4),
        _stepButton(
          Icons.remove_rounded,
          'Fewer',
          n <= 1 ? null : () => _setInterval(n - 1),
          key: const ValueKey('editor-interval-minus'),
        ),
        SizedBox(
          width: 48,
          child: TextFormField(
            key: const ValueKey('editor-interval'),
            controller: _interval,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(2),
            ],
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (_) => setState(() {}),
            validator: (value) {
              if (_recurrenceMode != RecurrenceMode.every) return null;
              final v = int.tryParse(value ?? '');
              return v == null || v < 1 || v > maxRecurrenceInterval
                  ? '1–$maxRecurrenceInterval'
                  : null;
            },
          ),
        ),
        _stepButton(
          Icons.add_rounded,
          'More',
          n >= maxRecurrenceInterval ? null : () => _setInterval(n + 1),
          key: const ValueKey('editor-interval-plus'),
        ),
        const SizedBox(width: 4),
        Expanded(
          // Re-keyed by unit so a unit set elsewhere (e.g. applying a
          // suggestion) shows.
          child: KeyedSubtree(
            key: ValueKey('editor-unit-is-${_unit.name}'),
            child: DropdownButtonFormField<RecurrenceUnit>(
            key: const ValueKey('editor-unit'),
            initialValue: _unit,
            isExpanded: true,
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            dropdownColor: AppTheme.overlay,
            items: [
              for (final unit in RecurrenceUnit.values)
                DropdownMenuItem(
                  value: unit,
                  child: Text(
                    _unitPlural(unit, n),
                    key: ValueKey('editor-unit-${unit.name}'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (u) => setState(() => _unit = u ?? _unit),
          ),
          ),
        ),
      ],
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
          _repeatsToggle(),
          if (repeating) ...[
            const SizedBox(height: 14),
            _intervalRow(theme),
          ],
          if (repeating) ...[
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

  /// A touch-sized (44px) − / + button.
  Widget _stepButton(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    Key? key,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: EdgeInsets.zero,
      icon: Icon(icon, size: 20),
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
          );
    String? total;
    if (amount != null && count != null && count > 1) {
      final sum =
          (_direction == TransactionDirection.credit ? 1 : -1) *
          amount.toDouble() *
          count;
      total =
          '${formatSignedAmount(sum)} over $count occurrences';
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
              if (!_isNew && widget.existing!.overrides.isNotEmpty)
                '${widget.existing!.overrides.length} once-off',
              if (!_isNew) 'Tap a date to skip or restore it',
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
    final override = canToggle ? widget.existing!.overrideOn(date) : null;
    final text = Text(
      formatOccurrenceDate(date),
      style: theme.textTheme.labelMedium?.copyWith(
        color: skipped
            ? AppTheme.textFaint
            : (isFocus ? AppTheme.accent : AppTheme.text),
        decoration: skipped ? TextDecoration.lineThrough : null,
        fontWeight: isFocus ? FontWeight.w700 : FontWeight.w500,
      ),
    );
    final label = override == null
        ? text
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              text,
              const SizedBox(width: 4),
              Text(
                _signed(override.signed),
                key: ValueKey('chip-override-${formatDate(date)}'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: override.direction == TransactionDirection.credit
                      ? AppTheme.creditColor
                      : AppTheme.debitColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          );
    return Tooltip(
      message: override != null
          ? 'Once-off ${_signed(override.signed)}'
          : !canToggle
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
          if (!_isNew && widget.existing!.overrides.isNotEmpty)
            _overridesRow(theme),
          const SizedBox(height: 4),
          if (!_transferMode)
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

  Widget _overridesRow(ThemeData theme) {
    final n = widget.existing!.overrides.length;
    return Padding(
      key: const ValueKey('editor-overrides'),
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          const Icon(
            Icons.edit_calendar_rounded,
            size: 18,
            color: AppTheme.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$n once-off override${n == 1 ? '' : 's'} on single dates',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (!widget.readOnly)
            TextButton(
              key: const ValueKey('editor-clear-overrides'),
              onPressed: _saving ? null : _clearAllOverrides,
              child: const Text('Clear all'),
            ),
        ],
      ),
    );
  }

  /// Save offers "once-off" / "from now on" only when the editor was opened
  /// on one occurrence of a saved repeating series.
  bool get _offerSaveOptions =>
      !_isNew &&
      !widget.readOnly &&
      widget.focusDate != null &&
      widget.existing!.recurrenceMode == RecurrenceMode.every;

  bool get _focusIsFirst =>
      _day(widget.focusDate!) == _day(widget.existing!.startDate);

  /// Edits other than amount / direction (once-off can't apply those).
  bool get _onlyAmountChanged {
    final e = widget.existing!;
    final d = _draft();
    return d.name == e.name &&
        d.enabled == e.enabled &&
        _sameScheduleAsSaved() &&
        _transferMode == e.isTransfer &&
        d.transfer?.peerAccountId == e.transfer?.peerAccountId;
  }

  /// Why "Save once-off" is unavailable (null: available).
  String? get _onceOffBlock {
    if (!_onlyAmountChanged) {
      return 'Only the amount can change for one date';
    }
    final amount = parseMoneyInput(_amount.text);
    if (amount == null) return null; // the form validator explains
    final date = _day(widget.focusDate!);
    final e = widget.existing!;
    final current = e.overrideOn(date)?.signed ?? e.signedAmount;
    final next = _direction == TransactionDirection.credit ? amount : -amount;
    if (next == current) return 'Change the amount first';
    return null;
  }

  /// Why "From now on" is unavailable (null: available).
  String? get _forwardBlock {
    final e = widget.existing!;
    final d = _draft();
    final keepsFrame = _day(d.startDate) == _day(e.startDate) &&
        d.recurrenceMode == RecurrenceMode.every &&
        d.endMode == e.endMode &&
        d.endDate == e.endDate &&
        d.occurrenceCount == e.occurrenceCount &&
        _transferMode == e.isTransfer &&
        d.transfer?.peerAccountId == e.transfer?.peerAccountId;
    if (!keepsFrame) return 'Start, end and transfer changes need Save';
    if (!_dirty) return 'Change something first';
    return null;
  }

  Widget _saveButton() {
    final label = Text(_saving ? 'Saving…' : (_isNew ? 'Create' : 'Save'));
    if (!_offerSaveOptions) {
      return FilledButton.icon(
        key: const ValueKey('editor-save'),
        onPressed: _saving ? null : _save,
        icon: const Icon(Icons.check_rounded, size: 18),
        label: label,
      );
    }
    final date = formatOccurrenceDate(_day(widget.focusDate!));
    final onceBlock = _onceOffBlock;
    final forwardBlock = _forwardBlock;
    Widget item({
      required String key,
      required IconData icon,
      required String title,
      required String hint,
      required VoidCallback? onPressed,
    }) {
      return MenuItemButton(
        key: ValueKey(key),
        leadingIcon: Icon(icon, size: 20),
        onPressed: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title),
                Text(
                  hint,
                  style: Theme.of(context).textTheme.bodySmall,
                  softWrap: true,
                ),
              ],
            ),
          ),
        ),
      );
    }

    const radius = Radius.circular(20);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          key: const ValueKey('editor-save'),
          style: FilledButton.styleFrom(
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.horizontal(left: radius),
            ),
          ),
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.check_rounded, size: 18),
          label: label,
        ),
        const SizedBox(width: 2),
        MenuAnchor(
          alignmentOffset: const Offset(-180, 4),
          menuChildren: [
            item(
              key: 'save-option-series',
              icon: Icons.check_rounded,
              title: 'Save',
              hint: 'The whole series',
              onPressed: () => _saveAs(SaveOption.series),
            ),
            item(
              key: 'save-option-once',
              icon: Icons.event_available_rounded,
              title: 'Save once-off',
              hint: onceBlock ?? 'Only $date (amount)',
              onPressed:
                  onceBlock == null ? () => _saveAs(SaveOption.onceOff) : null,
            ),
            item(
              key: 'save-option-forward',
              icon: Icons.east_rounded,
              title: 'From now on',
              hint: forwardBlock ??
                  (_focusIsFirst
                      ? 'First occurrence: same as Save'
                      : '$date onwards; earlier dates keep the old values'),
              onPressed: forwardBlock == null
                  ? () => _saveAs(SaveOption.fromNowOn)
                  : null,
            ),
          ],
          builder: (context, controller, _) => Tooltip(
            message: 'More save options',
            excludeFromSemantics: true,
            child: Semantics(
              label: 'More save options',
              button: true,
              expanded: controller.isOpen,
              child: FilledButton(
              key: const ValueKey('editor-save-menu'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(40, 40),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.horizontal(right: radius),
                ),
              ),
              onPressed: _saving
                  ? null
                  : () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                child: const Icon(Icons.arrow_drop_down_rounded, size: 22),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _saveAs(SaveOption option) => switch (option) {
    SaveOption.series => _save(),
    SaveOption.onceOff => _saveOnceOff(),
    SaveOption.fromNowOn => _saveFromNowOn(),
  };

  Future<void> _saveOnceOff() async {
    if (_saving || widget.readOnly || !_offerSaveOptions) return;
    if (!_formKey.currentState!.validate()) return;
    if (_onceOffBlock != null) return;
    final existing = widget.existing!;
    final date = _day(widget.focusDate!);
    final amount = parseMoneyInput(_amount.text)!;
    final notifier = ref.read(transactionsProvider(widget.accountId).notifier);
    setState(() => _saving = true);
    try {
      // Back to the natural value: that is clearing the override.
      final natural = amount == existing.amount &&
          _direction == existing.direction;
      Transaction saved = existing;
      final r = await saveWithConflictCheck(
        context,
        save: (force) async {
          if (natural) {
            await notifier.clearOverrides(existing.id, date: date);
          } else {
            saved = await notifier.setOverride(
              existing.id,
              date,
              direction: _direction,
              amount: amount,
              version: force ? null : existing.version,
            );
          }
        },
        reload: () => ref.invalidate(transactionsProvider(widget.accountId)),
      );
      if (r == SaveResult.cancelled) return;
      if (r == SaveResult.reloaded) {
        if (mounted) _finish(null);
        return;
      }
      if (mounted) {
        _finish(
          _outcome(
            natural ? EditorAction.overrideCleared : EditorAction.overridden,
            saved,
            date,
          ),
        );
      }
    } catch (error) {
      _toast(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveFromNowOn() async {
    if (_saving || widget.readOnly || !_offerSaveOptions) return;
    if (_forwardBlock != null) return;
    // The first occurrence onwards is the whole series.
    if (_focusIsFirst) return _save();
    final draft = _validatedDraft();
    if (draft == null) return;
    final date = _day(widget.focusDate!);
    final notifier = ref.read(transactionsProvider(widget.accountId).notifier);
    setState(() => _saving = true);
    try {
      ({Transaction original, Transaction? created})? result;
      final r = await saveWithConflictCheck(
        context,
        save: (force) async =>
            result = await notifier.split(draft, date, force: force),
        reload: () => ref.invalidate(transactionsProvider(widget.accountId)),
      );
      if (r == SaveResult.cancelled) return;
      if (r == SaveResult.reloaded) {
        if (mounted) _finish(null);
        return;
      }
      if (mounted) {
        _finish(
          _outcome(
            EditorAction.split,
            result!.created ?? result!.original,
            date,
            result!.original,
          ),
        );
      }
    } catch (error) {
      _toast(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearOverride(DateTime date) async {
    final existing = widget.existing!;
    if (_dirty) {
      final ok = await showConfirmDialog(
        context,
        title: 'Reset this date?',
        message:
            'Your other edits are not saved and will be discarded. '
            '${formatOccurrenceDate(date)} goes back to the series value '
            '${_signed(existing.signedAmount)}.',
        confirmLabel: 'Reset',
      );
      if (!ok || !mounted) return;
    }
    await _runClear(EditorAction.overrideCleared, date: date);
  }

  Future<void> _clearAllOverrides() async {
    final existing = widget.existing!;
    final n = existing.overrides.length;
    final ok = await showConfirmDialog(
      context,
      title: 'Clear $n once-off override${n == 1 ? '' : 's'}?',
      message:
          'Every date goes back to the series value '
          '${_signed(existing.signedAmount)}.'
          '${_dirty ? ' Your other edits are not saved and will be discarded.' : ''}',
      confirmLabel: 'Clear all',
    );
    if (!ok || !mounted) return;
    await _runClear(EditorAction.overridesCleared);
  }

  Future<void> _runClear(EditorAction action, {DateTime? date}) async {
    final existing = widget.existing!;
    setState(() => _saving = true);
    try {
      await ref
          .read(transactionsProvider(widget.accountId).notifier)
          .clearOverrides(existing.id, date: date);
      if (mounted) _finish(_outcome(action, existing, date));
    } catch (error) {
      _toast(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _footer(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 16, 12),
      child: LayoutBuilder(
        builder: (context, c) {
          // Narrow panels: icon-only delete, no shortcut hint.
          // (the save-options arrow needs a little more room).
          final roomy = c.maxWidth >= (_offerSaveOptions ? 490 : 430);
          return Row(
            children: [
              if (!_isNew && !widget.readOnly)
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
              if (roomy && !widget.readOnly) ...[
                Tooltip(
                  message: 'Ctrl+Enter (⌘+Enter on Mac) saves',
                  child: Text('Ctrl+Enter', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 10),
              ],
              TextButton(
                onPressed: _close,
                child: Text(widget.readOnly ? 'Close' : 'Cancel'),
              ),
              if (!widget.readOnly) ...[
              const SizedBox(width: 8),
              _saveButton(),
              ],
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

  /// Validates the form; returns what to save (null: invalid, errors shown).
  Transaction? _validatedDraft() {
    setState(() => _endDateError = null);
    if (!_formKey.currentState!.validate()) return null;
    if (_recurrenceMode == RecurrenceMode.every &&
        _endMode == EndMode.untilDate &&
        _endDate == null) {
      setState(() => _endDateError = 'Pick an end date');
      return null;
    }
    if (_endDate != null && _endDate!.isBefore(_startDate)) {
      setState(() => _endDateError = 'Must be on or after the start date');
      return null;
    }
    if (_transferMode && _transfer == null) {
      setState(() => _transferError = 'Pick the other account');
      return null;
    }

    return _draft(amount: parseMoneyInput(_amount.text)!).copyWith(
      id: widget.existing?.id ?? const Uuid().v4(),
      accountId: widget.accountId,
      name: _name.text.trim(),
      direction: _direction,
      startDate: _startDate,
      enabled: _enabled,
      version: widget.existing?.version,
    );
  }

  Future<void> _save() async {
    if (_saving || widget.readOnly) return;
    final draft = _validatedDraft();
    if (draft == null) return;

    setState(() => _saving = true);
    try {
      final notifier = ref.read(
        transactionsProvider(widget.accountId).notifier,
      );
      final Transaction saved;
      if (widget.existing == null) {
        saved = await notifier.create(draft);
      } else {
        final r = await saveWithConflictCheck(
          context,
          save: (force) => notifier.updateTransaction(draft, force: force),
          reload: () => ref.invalidate(transactionsProvider(widget.accountId)),
        );
        if (r == SaveResult.cancelled) return;
        if (r == SaveResult.reloaded) {
          if (mounted) _finish(null);
          return;
        }
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

/// Largest "every N" the editor offers.
const int maxRecurrenceInterval = 99;

String _unitPlural(RecurrenceUnit unit, [int count = 2]) {
  final one = count == 1;
  return switch (unit) {
    RecurrenceUnit.days => one ? 'day' : 'days',
    RecurrenceUnit.weeks => one ? 'week' : 'weeks',
    RecurrenceUnit.months => one ? 'month' : 'months',
    RecurrenceUnit.years => one ? 'year' : 'years',
  };
}

enum _Kind { credit, debit, transfer }

class _ViewOnlyNote extends StatelessWidget {
  const _ViewOnlyNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('editor-view-only'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.overlay,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        children: [
          Icon(Icons.visibility_outlined, size: 18, color: AppTheme.textMuted),
          SizedBox(width: 10),
          Expanded(child: Text('View only: you have viewer access to this account.')),
        ],
      ),
    );
  }
}
