import 'dart:async';

import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../boot/page_stub.dart'
    if (dart.library.js_interop) '../../boot/page_web.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../widgets/conflict_dialog.dart';
import '../../state/realtime_providers.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/stream_picker.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/money_text.dart';
import '../../widgets/frequency_picker.dart';
import '../../widgets/ui.dart';
import '../timeline/occurrence_dates.dart';
import '../timeline/occurrence_info.dart';
import '../categories/categories_manager.dart';
import '../timeline/stack_lanes.dart';

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

  /// The dot popup's Trim: the series now ends on [EditorOutcome.date].
  trimmed,
}

/// The editor's save choices on a repeating series' occurrence.
enum SaveOption { series, onceOff, fromNowOn }

/// What happened in one editor session, so callers can report it
/// accurately (and offer undo).
class EditorOutcome {
  const EditorOutcome({
    required this.action,
    required this.event,
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
  /// [date]); [event] is the new series (or, on the first occurrence,
  /// the updated whole series).
  final BudgetEvent? original;

  /// Created / saved / deleted series (for skips: the series).
  final BudgetEvent event;

  /// The series as it was before a save (for undo).
  final BudgetEvent? previous;

  /// Occurrences newly skipped / restored in this session.
  final Set<DateTime> skipped;
  final Set<DateTime> restored;

  /// Skipped occurrences when the editor opened (to restore after undoing
  /// a delete).
  final Set<DateTime> skippedBefore;
}

/// Opens the event series editor as a side panel.
///
/// [focusDate] is the occurrence the user clicked on the timeline: it is
/// highlighted in the preview and offers skip / unskip. [skippedDates] are
/// that series' currently skipped occurrences. Returns the saved (or
/// deleted) event when anything changed, else null.
Future<EditorOutcome?> showEventEditor(
  BuildContext context, {
  required String streamId,
  BudgetEvent? existing,
  DateTime? initialDate,
  DateTime? initialEndDate,
  bool onceOnly = false,
  DateTime? focusDate,
  Set<DateTime> skippedDates = const {},
  bool readOnly = false,
}) {
  // Still inside the tap: lets iOS / Android web raise the keyboard for
  // the Amount field that focuses once the panel is built.
  if (!readOnly && existing == null) primeSoftKeyboard();
  return showSidePanel<EditorOutcome>(
    context,
    label: existing == null ? 'New event' : 'Edit event',
    builder: (context) => EventEditor(
      streamId: streamId,
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

class EventEditor extends ConsumerStatefulWidget {
  const EventEditor({
    super.key,
    required this.streamId,
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

  final String streamId;
  final BudgetEvent? existing;
  final DateTime? initialDate;

  /// New repeating event only: pre-fill Ends "On date" with this day
  /// (inclusive, like the field itself), e.g. a selected period's end.
  final DateTime? initialEndDate;
  final bool onceOnly;
  final DateTime? focusDate;
  final Set<DateTime> skippedDates;
  @override
  ConsumerState<EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends ConsumerState<EventEditor> {
  /// A loan (spec 002): its fields show read-only, with no Save, until
  /// loan editing ships.
  bool get _isLoan => widget.existing?.isLoan ?? false;

  /// Viewer access, or a loan: fields disabled and no Save.
  bool get _readOnly => widget.readOnly || _isLoan;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _interval;
  late final TextEditingController _count;
  late EventDirection _direction;

  /// Transfer mode: the series moves money between this stream and
  /// [_transfer]'s stream (the far side mirrors it with the opposite sign).
  late bool _transferMode;
  TransferLink? _transfer;
  String? _transferError;

  /// The structured rule picked (Once … Every N months); the N families
  /// read N from [_interval]. Day chips per family, so switching between
  /// week and month rules keeps each one's picks.
  late FreqRule _rule;
  Set<int> _weekDays = {};
  Set<int> _monthDays = {};

  /// A saved "every N days" (N > 1) keeps its N editable under Daily.
  late bool _dailyN;

  RecurrenceMode get _recurrenceMode =>
      _rule == FreqRule.once ? RecurrenceMode.once : RecurrenceMode.every;
  late EndMode _endMode;
  late DateTime _startDate;
  DateTime? _endDate;
  late bool _enabled;

  /// The category picked (null: the default, see [_category]). The
  /// category gives the event its name and the header / graph line colour.
  String? _categoryId;
  String? _categoryError;
  bool _saving = false;
  String? _endDateError;
  late Set<DateTime> _skipped;
  final Set<DateTime> _skipBusy = {};

  late Set<DateTime> _skippedInitially;
  late String _initialSignature;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final id = widget.existing?.id;
    _openedEvent = id == null ? null : ref.read(remoteChangesProvider)[id]?.id;
    final existing = widget.existing;
    _categoryId = existing?.categoryId;
    _amount = TextEditingController(text: existing?.amount.toString() ?? '');
    final savedFreq = existing?.frequency;
    _interval = TextEditingController(
      text:
          '${savedFreq != null && savedFreq.interval > 1 ? savedFreq.interval : 2}',
    );
    _count = TextEditingController(
      text: (existing?.occurrenceCount ?? 12).toString(),
    );
    _direction = existing?.direction ?? EventDirection.debit;
    _transfer = existing?.transfer;
    _transferMode = _transfer != null;
    // New events start as a one-off from every entry point (saved
    // ones keep theirs). Switching to Repeats starts at every 1 week.
    _rule = widget.onceOnly || existing == null
        ? FreqRule.once
        : existing.frequency.rule;
    _dailyN = _rule == FreqRule.daily && (savedFreq?.interval ?? 1) > 1;
    if (savedFreq != null && savedFreq.rule.weekFamily) {
      _weekDays = {...savedFreq.days};
    } else if (savedFreq != null && savedFreq.rule.monthFamily) {
      _monthDays = {...savedFreq.days};
    }
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
      if (!_readOnly && widget.existing == null) {
        _focusAmount();
      } else if (!_scope.hasFocus) {
        _scope.requestFocus();
      }
    });
    // Amount again once the panel / sheet has animated in, unless the user
    // has already moved focus inside the editor. Something closing in the
    // same frame (the New ▾ menu restoring its focus) or the opening route
    // can otherwise take it away.
    // (New events only: editing doesn't pop the keyboard over the form.)
    if (!_readOnly && widget.existing == null) {
      _refocus = Timer(nameRefocusDelay, () {
        if (!mounted || _amountFocus.hasFocus) return;
        final primary = FocusManager.instance.primaryFocus;
        final inEditor =
            primary != null &&
            primary != _scope &&
            primary.ancestors.contains(_scope);
        if (!inEditor) _focusAmount();
      });
    }
  }

  Timer? _refocus;

  /// The event's category: the one picked (or the saved one), else the
  /// last one used in this stream, else the first. Null only while the
  /// list loads or when the stream has none.
  Category? get _category {
    final list =
        ref.read(categoriesProvider(widget.streamId)).valueOrNull ??
        const <Category>[];
    Category? by(String? id) =>
        id == null ? null : list.where((c) => c.id == id).firstOrNull;
    if (_categoryId != null) {
      final picked = by(_categoryId);
      if (picked != null || list.isEmpty) return picked;
    }
    // An existing event keeps its own (by name when its id isn't known).
    final existing = widget.existing;
    if (existing != null) {
      final key = normalizeCategoryName(existing.name).toLowerCase();
      final named = list.where((c) => c.name.toLowerCase() == key).firstOrNull;
      if (named != null) return named;
    }
    return by(ref.read(lastCategoryProvider(widget.streamId))) ??
        list.firstOrNull;
  }

  /// The header's colour: the category's.
  Color get _color =>
      colorFromHex(_category?.color) ??
      colorFromHex(widget.existing?.color) ??
      laneColor(0);

  Future<void> _manageCategories() async {
    final created = await showCategoriesManager(
      context,
      streamId: widget.streamId,
      canEdit: !_readOnly,
    );
    if (!mounted) return;
    setState(() {
      if (created != null) _categoryId = created;
      _categoryError = null;
    });
  }

  final _scope = FocusScopeNode(debugLabel: 'EventEditor');

  /// Amount comes first (focused on open), then the type, the category
  /// and the schedule.
  final _amountFocus = FocusNode(debugLabel: 'editor-amount');

  void _focusAmount() {
    if (_readOnly) return;
    _amountFocus.requestFocus();
  }

  /// Everything the form would save, to detect unsaved edits.
  String _signature() {
    final d = _draft();
    return [
      _categoryId,
      d.direction,
      _amount.text.trim(),
      d.startDate,
      d.recurrenceMode,
      d.frequency,
      d.endMode,
      d.endDate,
      d.occurrenceCount,
      d.enabled,
      d.transfer?.peerStreamId,
    ].join('|');
  }

  bool get _dirty => _signature() != _initialSignature;

  EditorOutcome? _outcome(
    EditorAction? action, [
    BudgetEvent? t,
    DateTime? date,
    BudgetEvent? original,
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
      event: t ?? existing!,
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
    _amount.dispose();
    _interval.dispose();
    _count.dispose();
    _scope.dispose();
    _refocus?.cancel();
    _amountFocus.dispose();
    super.dispose();
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  int get _intervalValue =>
      (int.tryParse(_interval.text.trim()) ?? 2).clamp(1, maxRuleInterval);

  /// The rule as picked (N families read [_interval]; days per family).
  Frequency get _frequency {
    final n = _intervalValue;
    return switch (_rule) {
      FreqRule.once => Frequency.once,
      FreqRule.daily => Frequency(FreqRule.daily, interval: _dailyN ? n : 1),
      FreqRule.weekly => Frequency(FreqRule.weekly, days: _weekDays.toList()),
      FreqRule.everyNWeeks => Frequency(
        FreqRule.everyNWeeks,
        interval: n,
        days: _weekDays.toList(),
      ),
      FreqRule.monthly => Frequency(
        FreqRule.monthly,
        days: _monthDays.toList(),
      ),
      FreqRule.everyNMonths => Frequency(
        FreqRule.everyNMonths,
        interval: n,
        days: _monthDays.toList(),
      ),
    };
  }

  BudgetEvent _draft({Decimal? amount, int? count, DateTime? endDate}) {
    final parsedAmount =
        amount ?? parseMoneyInput(_amount.text) ?? Decimal.zero;
    final repeating = _recurrenceMode == RecurrenceMode.every;
    final endMode = repeating ? _endMode : EndMode.never;
    final f = _frequency;
    return BudgetEvent(
      id: widget.existing?.id ?? 'preview',
      streamId: widget.streamId,
      name: _category?.name ?? widget.existing?.name ?? '',
      categoryId: _category?.id ?? widget.existing?.categoryId,
      direction: _direction,
      amount: parsedAmount,
      startDate: _startDate,
      recurrenceMode: _recurrenceMode,
      interval: f.legacyInterval,
      unit: f.repeats ? RecurrenceUnit.fromJson(f.legacyUnit!) : null,
      days: f.days,
      endMode: endMode,
      endDate: endMode == EndMode.untilDate ? (endDate ?? _endDate) : null,
      occurrenceCount: endMode == EndMode.count
          ? (count ?? int.tryParse(_count.text.trim()) ?? 1)
          : null,
      enabled: _enabled,
      transfer: _transferMode ? _transfer : null,
      color: _category?.color ?? widget.existing?.color,
    );
  }

  _Kind get _kind => _transferMode
      ? _Kind.transfer
      : (_direction == EventDirection.credit ? _Kind.credit : _Kind.debit);

  bool get _receiving => _direction == EventDirection.credit;

  Widget _transferField(ThemeData theme) {
    final link = _transfer;
    final label = _receiving ? 'From stream' : 'To stream';
    return StreamPicker(
      keyPrefix: 'transfer',
      title: label,
      excludeStreamId: widget.streamId,
      // Both sides of a transfer change: only streams I can edit.
      editableOnly: true,
      currentStreamId: link?.peerStreamId,
      onSelected: (a) => setState(() {
        _transferError = null;
        _transfer = TransferLink(
          id: link?.id,
          peerEventId: link?.peerEventId,
          peerStreamId: a.id,
          peerStreamName: a.name,
        );
      }),
      builder: (context, open) => InkWell(
        key: const ValueKey('editor-transfer-stream'),
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
                      ? 'Mirrors as money out of ${link.streamLabel}'
                      : 'Arrives as money in to ${link.streamLabel}'),
          ),
          child: Text(
            link == null
                ? 'Choose stream'
                : '${_receiving ? 'From' : 'To'}: ${link.streamLabel}',
            style: link == null
                ? theme.textTheme.bodyLarge?.copyWith(color: AppTheme.textFaint)
                : theme.textTheme.bodyLarge,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
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
            ? 'This event has not been created yet.'
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
    // Rebuild when the categories change (names, colours, the default).
    ref.watch(categoriesProvider(widget.streamId));
    final name = _category?.name ?? widget.existing?.name ?? '';
    final title = _isNew
        ? 'New event'
        : (name.isEmpty ? 'Untitled series' : name);

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
                      ] else if (_isLoan) ...[
                        const _LoanReadOnlyNote(),
                        const SizedBox(height: 12),
                      ],
                      _ro(_detailsSection(theme)),
                      const SizedBox(height: 12),
                      _ro(_scheduleSection(theme)),
                      // Just Details and Schedule, new or edited: Include in
                      // balance is the list row's switch, skips / once-offs
                      // are kept as they are (saving never resets them).
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
    final who = actorName(ref, widget.streamId, ev.actorId) ?? 'someone else';
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
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ro(Widget child) =>
      _readOnly ? IgnorePointer(child: ExcludeFocus(child: child)) : child;

  Widget _header(ThemeData theme, String title) {
    // The event's graph line colour, edge to edge; text and buttons in the
    // lane's near-white (with a soft shadow, as on the chart), the money
    // in / out badge on the lane's dark pill so its green / red reads.
    const fg = laneTextColor;
    const shadow = [Shadow(color: Color(0x66000000), blurRadius: 3)];
    return AnimatedContainer(
      key: const ValueKey('editor-header'),
      duration: const Duration(milliseconds: 160),
      color: _color,
      padding: EdgeInsets.fromLTRB(widget.onDone != null ? 4 : 16, 12, 8, 12),
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: IconButton.styleFrom(foregroundColor: fg),
        ),
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
            DecoratedBox(
              decoration: BoxDecoration(
                color: laneAmountPillColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: DirectionBadge(
                credit: _direction == EventDirection.credit,
                muted: !_enabled,
                size: 36,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isNew ? 'NEW' : 'EVENT SERIES',
                    style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1,
                      color: fg,
                      fontWeight: FontWeight.w800,
                      shadows: shadow,
                    ),
                  ),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: fg,
                      shadows: shadow,
                    ),
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
      ),
    );
  }

  String _signed(Decimal signed) => formatSignedAmount(signed.toDouble());

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
      detail =
          'Once-off ${_signed(override.signed)} on this date · '
          'series ${_signed(existing.signedAmount)}';
    } else if (_offerSaveOptions) {
      detail =
          'Save changes the whole series. The arrow next to Save '
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
                override != null
                    ? Icons.edit_calendar_rounded
                    : Icons.event_rounded,
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
          if (!_readOnly)
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
            key: const ValueKey('editor-amount'),
            controller: _amount,
            focusNode: _amountFocus,
            autofocus: !_readOnly && widget.existing == null,
            decoration: InputDecoration(
              labelText: _recurrenceMode == RecurrenceMode.every
                  ? 'Amount each time'
                  : 'Amount',
              prefixText: symbol.isEmpty ? null : '$symbol ',
              hintText: '0.00',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            // Type and category always have a value: Enter / the
            // keyboard's Done saves.
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
          const SizedBox(height: 12),
          // Narrow (docked list, small phones): labels only, one line.
          LayoutBuilder(
            builder: (context, c) {
              // Icons only when every label still fits beside one.
              final icons = c.maxWidth >= 420;
              Widget label(String text, {Key? key}) => FittedBox(
                // Never clipped: a label shrinks a little rather than cut.
                fit: BoxFit.scaleDown,
                child: Text(text, key: key, maxLines: 1, softWrap: false),
              );
              return SegmentedButton<_Kind>(
                key: const ValueKey('editor-kind'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: _Kind.credit,
                    label: label('Money in'),
                    icon: icons
                        ? const Icon(Icons.south_west_rounded, size: 18)
                        : null,
                  ),
                  ButtonSegment(
                    value: _Kind.debit,
                    label: label('Money out'),
                    icon: icons
                        ? const Icon(Icons.north_east_rounded, size: 18)
                        : null,
                  ),
                  ButtonSegment(
                    value: _Kind.transfer,
                    label: label(
                      'Transfer',
                      key: const ValueKey('editor-kind-transfer'),
                    ),
                    icon: icons
                        ? const Icon(Icons.swap_horiz_rounded, size: 18)
                        : null,
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (value) => setState(() {
                  switch (value.first) {
                    case _Kind.credit:
                      _transferMode = false;
                      _direction = EventDirection.credit;
                    case _Kind.debit:
                      _transferMode = false;
                      _direction = EventDirection.debit;
                    case _Kind.transfer:
                      _transferMode = true;
                      // A new transfer sends money out of this stream; an
                      // existing receiving side keeps its direction.
                      if (widget.existing?.transfer == null) {
                        _direction = EventDirection.debit;
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
              );
            },
          ),
          if (_transferMode) ...[
            const SizedBox(height: 12),
            _transferField(theme),
          ],
          const SizedBox(height: 14),
          CategoryPicker(
            streamId: widget.streamId,
            selectedId: _category?.id,
            enabled: !_readOnly,
            errorText: _categoryError,
            onManage: _manageCategories,
            onSelected: (c) => setState(() {
              _categoryId = c.id;
              _categoryError = null;
            }),
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

  /// Picks a rule: Once … Every N months (inline chips, no dialog).
  void _pickRule(FreqRule r) => setState(() {
    final wasOnce = _rule == FreqRule.once;
    _rule = r;
    if (r == FreqRule.once) {
      _endMode = EndMode.never;
      _endDateError = null;
      return;
    }
    final n = int.tryParse(_interval.text.trim()) ?? 0;
    if ((r == FreqRule.everyNWeeks || r == FreqRule.everyNMonths) && n < 2) {
      _interval.text = '2';
    }
    // A new one from a selected period: repeating ends on its last day.
    final presetEnd = widget.initialEndDate;
    if (wasOnce && _isNew && presetEnd != null && _endMode == EndMode.never) {
      _endMode = EndMode.untilDate;
      _endDate = DateTime(presetEnd.year, presetEnd.month, presetEnd.day);
    }
  });

  /// The frequency picker, the day chips (fading in only for the week and
  /// month families) and the live phrase.
  Widget _frequencyBlock(ThemeData theme) {
    final week = _rule.weekFamily, month = _rule.monthFamily;
    final family = week ? 'week' : (month ? 'month' : 'none');
    final phrase = describeFrequency(_frequency, toRuleDate(_startDate));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Frequency', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        FrequencyPicker(
          rule: _rule,
          interval: _interval,
          showDailyInterval: _dailyN,
          enabled: !_readOnly,
          onRuleChanged: _pickRule,
          onIntervalChanged: () => setState(() {}),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SizeTransition(
                sizeFactor: a,
                alignment: Alignment.topCenter,
                child: child,
              ),
            ),
            child: family == 'none'
                ? const SizedBox(
                    key: ValueKey('no-days'),
                    width: double.infinity,
                  )
                : Padding(
                    key: ValueKey('days-$family'),
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          week
                              ? 'On these days (none: the start date\'s weekday)'
                              : 'On these days of the month (none: the '
                                    'start date\'s day)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppTheme.textMuted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        DayChips(
                          monthDays: month,
                          selected: week ? _weekDays : _monthDays,
                          enabled: !_readOnly,
                          onChanged: (v) => setState(() {
                            if (week) {
                              _weekDays = v;
                            } else {
                              _monthDays = v;
                            }
                          }),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          phrase,
          key: const ValueKey('editor-freq-phrase'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppTheme.accent,
            fontWeight: FontWeight.w600,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _dateField(
            key: const ValueKey('editor-start'),
            label: repeating ? 'Starts (first occurrence)' : 'Date',
            value: _startDate,
            onPicked: (d) => setState(() => _startDate = d),
          ),
          const SizedBox(height: 14),
          _frequencyBlock(theme),
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

  /// Skips are stored per date; only offer them while the dates shown match
  /// the saved schedule.
  bool _sameScheduleAsSaved() {
    final e = widget.existing;
    if (e == null) return false;
    final d = _draft();
    return _day(e.startDate) == _day(d.startDate) &&
        e.frequency == d.frequency &&
        e.endMode == d.endMode &&
        e.endDate == d.endDate &&
        e.occurrenceCount == d.occurrenceCount;
  }

  /// Save offers "once-off" / "from now on" only when the editor was opened
  /// on one occurrence of a saved repeating series.
  bool get _offerSaveOptions =>
      !_isNew &&
      !_readOnly &&
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
        d.transfer?.peerStreamId == e.transfer?.peerStreamId;
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
    final next = _direction == EventDirection.credit ? amount : -amount;
    if (next == current) return 'Change the amount first';
    return null;
  }

  /// Why "From now on" is unavailable (null: available).
  String? get _forwardBlock {
    final e = widget.existing!;
    final d = _draft();
    final keepsFrame =
        _day(d.startDate) == _day(e.startDate) &&
        d.recurrenceMode == RecurrenceMode.every &&
        d.endMode == e.endMode &&
        d.endDate == e.endDate &&
        d.occurrenceCount == e.occurrenceCount &&
        _transferMode == e.isTransfer &&
        d.transfer?.peerStreamId == e.transfer?.peerStreamId;
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
              onPressed: onceBlock == null
                  ? () => _saveAs(SaveOption.onceOff)
                  : null,
            ),
            item(
              key: 'save-option-forward',
              icon: Icons.east_rounded,
              title: 'From now on',
              hint:
                  forwardBlock ??
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
    if (_saving || _readOnly || !_offerSaveOptions) return;
    if (!_formKey.currentState!.validate()) return;
    if (_onceOffBlock != null) return;
    final existing = widget.existing!;
    final date = _day(widget.focusDate!);
    final amount = parseMoneyInput(_amount.text)!;
    final notifier = ref.read(eventsProvider(widget.streamId).notifier);
    setState(() => _saving = true);
    try {
      // Back to the natural value: that is clearing the override.
      final natural =
          amount == existing.amount && _direction == existing.direction;
      BudgetEvent saved = existing;
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
        reload: () => ref.invalidate(eventsProvider(widget.streamId)),
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
    if (_saving || _readOnly || !_offerSaveOptions) return;
    if (_forwardBlock != null) return;
    // The first occurrence onwards is the whole series.
    if (_focusIsFirst) return _save();
    final draft = _validatedDraft();
    if (draft == null) return;
    final date = _day(widget.focusDate!);
    final notifier = ref.read(eventsProvider(widget.streamId).notifier);
    setState(() => _saving = true);
    try {
      ({BudgetEvent original, BudgetEvent? created})? result;
      final r = await saveWithConflictCheck(
        context,
        save: (force) async =>
            result = await notifier.split(draft, date, force: force),
        reload: () => ref.invalidate(eventsProvider(widget.streamId)),
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

  Future<void> _runClear(EditorAction action, {DateTime? date}) async {
    final existing = widget.existing!;
    setState(() => _saving = true);
    try {
      await ref
          .read(eventsProvider(widget.streamId).notifier)
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
          final narrow = c.maxWidth < 320;
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
              if (roomy && !_readOnly) ...[
                Tooltip(
                  message: 'Ctrl+Enter (⌘+Enter on Mac) saves',
                  child: Text('Ctrl+Enter', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 10),
              ],
              TextButton(
                onPressed: _close,
                // 320px phones: tighter, so Delete + Cancel + Save ▾ fit.
                style: narrow
                    ? TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      )
                    : null,
                child: Text(_readOnly ? 'Close' : 'Cancel'),
              ),
              if (!_readOnly) ...[
                SizedBox(width: narrow ? 4 : 8),
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
          .read(eventsProvider(widget.streamId).notifier)
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
          .read(eventsProvider(widget.streamId).notifier)
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

  /// Validates the form; returns what to save (null: invalid, errors shown).
  BudgetEvent? _validatedDraft() {
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
      setState(() => _transferError = 'Pick the other stream');
      return null;
    }
    final category = _category;
    if (category == null) {
      setState(() => _categoryError = 'Create a category first (Manage)');
      return null;
    }

    return _draft(amount: parseMoneyInput(_amount.text)!).copyWith(
      id: widget.existing?.id ?? const Uuid().v4(),
      streamId: widget.streamId,
      name: category.name,
      categoryId: category.id,
      color: category.color,
      direction: _direction,
      startDate: _startDate,
      enabled: _enabled,
      version: widget.existing?.version,
    );
  }

  Future<void> _save() async {
    if (_saving || _readOnly) return;
    final draft = _validatedDraft();
    if (draft == null) return;

    setState(() => _saving = true);
    try {
      final notifier = ref.read(eventsProvider(widget.streamId).notifier);
      final BudgetEvent saved;
      if (widget.existing == null) {
        saved = await notifier.create(draft);
      } else {
        final r = await saveWithConflictCheck(
          context,
          save: (force) => notifier.updateEvent(draft, force: force),
          reload: () => ref.invalidate(eventsProvider(widget.streamId)),
        );
        if (r == SaveResult.cancelled) return;
        if (r == SaveResult.reloaded) {
          if (mounted) _finish(null);
          return;
        }
        saved = draft;
      }
      if (saved.categoryId != null) {
        ref.read(lastCategoryProvider(widget.streamId).notifier).state =
            saved.categoryId;
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
          Expanded(
            child: Text('View only: you have viewer access to this stream.'),
          ),
        ],
      ),
    );
  }
}

class _LoanReadOnlyNote extends StatelessWidget {
  const _LoanReadOnlyNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('editor-loan-read-only'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.overlay,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        children: [
          Icon(
            Icons.account_balance_outlined,
            size: 18,
            color: AppTheme.textMuted,
          ),
          SizedBox(width: 10),
          Expanded(child: Text('Loan editing is coming in the next update')),
        ],
      ),
    );
  }
}

/// When a new event's editor re-checks that Amount has focus (after
/// the panel's entrance animation).
const Duration nameRefocusDelay = Duration(milliseconds: 400);
