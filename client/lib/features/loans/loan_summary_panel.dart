import 'dart:async';
import 'dart:convert';

import 'package:budget_loan/budget_loan.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/money_text.dart' show parseMoneyInput;
import '../../widgets/stream_picker.dart';
import '../timeline/occurrence_info.dart' show ordinal;
import '../timeline/zoom_level.dart' show dateOnly;
import 'loan_models.dart';
import 'repayment_helpers.dart';

/// "Reducing balance · interest charged monthly on the 15th".
String summaryTypeLine(LoanSummary s) {
  if (s.isFlat) return 'Flat rate · interest fixed at the start';
  final when = s.chargeSchedule == ChargeSchedule.onRepaymentDates
      ? 'interest charged on each repayment date'
      : switch (s.chargeDay) {
          'monthEnd' => 'interest charged monthly on the last day',
          final int d => 'interest charged monthly on the ${ordinal(d)}',
          _ => 'interest charged monthly on the ${ordinal(s.startDate.day)}',
        };
  return 'Reducing balance · $when';
}

String _reason(String r) => switch (r) {
  'rateChange' => 'rate change',
  'interestOnlyEnd' => 'interest only ends',
  _ => 'start',
};

/// The loan summary (spec 003 §7): what is owed, the minimums, the
/// repayments set up, interest and payoff, all labelled estimates. With
/// [actions] (the timeline's, on a saved loan) its warnings offer fixes.
class LoanSummaryPanel extends ConsumerStatefulWidget {
  const LoanSummaryPanel({
    super.key,
    required this.streamId,
    required this.summary,
    this.actions = false,
    this.today,
  });

  final String streamId;
  final LoanSummary summary;
  final bool actions;

  /// "Today" for "Interest this month" (tests); default now.
  final DateTime? today;

  @override
  ConsumerState<LoanSummaryPanel> createState() => _LoanSummaryPanelState();
}

class _LoanSummaryPanelState extends ConsumerState<LoanSummaryPanel> {
  bool _busy = false;

  LoanSummary get s => widget.summary;

  List<BudgetEvent> get _events =>
      ref.read(eventsProvider(widget.streamId)).valueOrNull ?? const [];

  BudgetEvent? get _loan => _events.where((e) => e.id == s.eventId).firstOrNull;

  BudgetEvent? _event(String id) =>
      _events.where((e) => e.id == id).firstOrNull;

  String _streamName(String id) =>
      (ref.read(streamsProvider).valueOrNull ?? const <BudgetStream>[])
          .where((a) => a.id == id)
          .firstOrNull
          ?.name ??
      'another stream';

  Future<void> _run(Future<void> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(loanSummaryProvider(widget.streamId));
      ref.invalidate(balanceProvider);
      ref.invalidate(insightsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setUp() async {
    final first = s.firstRepaymentDate ?? s.startDate;
    final m = s.minimums.firstOrNull;
    final r = await showDialog<_SetupResult>(
      context: context,
      builder: (_) => _SetupRepaymentsDialog(
        loanStreamId: widget.streamId,
        amount: m?.amount ?? Decimal.zero,
        frequency: s.repaymentFrequency,
        first: first,
        count: s.flat?.instalments,
        finalAmount: s.flat?.finalRepayment,
      ),
    );
    if (r == null || !mounted) return;
    await _run(() async {
      final draft = repaymentTransferDraft(
        fromStreamId: r.fromStreamId,
        loanStreamId: widget.streamId,
        amount: r.amount,
        frequency: s.repaymentFrequency,
        first: first,
        count: s.flat?.instalments,
      );
      final notifier = ref.read(eventsProvider(r.fromStreamId).notifier);
      final created = await notifier.create(draft);
      final flat = s.flat;
      if (flat != null && flat.finalRepayment != r.amount) {
        await notifier.setOverride(
          created.id,
          nthRepayment(s.repaymentFrequency, first, flat.instalments),
          direction: EventDirection.debit,
          amount: flat.finalRepayment,
          version: created.version,
        );
      }
      ref.invalidate(eventsProvider(widget.streamId));
    }, 'Repayments set up from ${_streamName(r.fromStreamId)}');
  }

  Future<void> _useMinimum(LoanMinimum m) async {
    final t = s.transfers.firstOrNull;
    final e = t == null ? null : _event(t.eventId);
    if (e == null) return;
    final at = firstOccurrenceOnOrAfter(e, m.from);
    if (at == null) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Use the minimum?',
      message:
          'Repayments change to ${loanMoney(m.amount)} from '
          '${loanDate(at)}. Earlier repayments stay as they are.',
      confirmLabel: 'Change repayments',
      isDestructive: false,
    );
    if (!ok || !mounted) return;
    await _run(
      () => ref
          .read(eventsProvider(widget.streamId).notifier)
          .split(e.copyWith(amount: m.amount), at)
          .then((_) {}),
      'Repayments are ${loanMoney(m.amount)} from ${loanDate(at)}',
    );
  }

  Future<void> _endAtPayoff() async {
    final payoff = s.payoffDate;
    if (payoff == null) return;
    final running = [
      for (final t in s.transfers)
        if (_event(t.eventId) case final e?)
          if (firstOccurrenceOnOrAfter(
                e,
                payoff.add(const Duration(days: 1)),
              ) !=
              null)
            e,
    ];
    if (running.isEmpty) return;
    final ok = await showConfirmDialog(
      context,
      title: 'End repayments at payoff?',
      message:
          'The repayments end on ${loanDate(payoff)}, when the loan is paid '
          'off.',
      confirmLabel: 'End repayments',
      isDestructive: false,
    );
    if (!ok || !mounted) return;
    final notifier = ref.read(eventsProvider(widget.streamId).notifier);
    await _run(() async {
      for (final e in running) {
        await notifier.updateEvent(endedAt(e, payoff));
      }
    }, 'Repayments end on ${loanDate(payoff)}');
  }

  ({RepaymentFrequency frequency, DateTime first})? get _matchSchedule {
    final loan = _loan;
    final t = s.transfers.firstOrNull;
    final e = t == null ? null : _event(t.eventId);
    if (loan == null || e == null || loan.loan == null) return null;
    return scheduleFromTransfer(e, loan.startDate);
  }

  Future<void> _match() async {
    final loan = _loan;
    final m = _matchSchedule;
    if (loan == null || m == null) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Match the loan to your repayments?',
      message:
          "The loan's repayment schedule becomes "
          '${frequencyWord(m.frequency)} from ${loanDate(m.first)}.',
      confirmLabel: 'Match',
      isDestructive: false,
    );
    if (!ok || !mounted) return;
    await _run(
      () => ref
          .read(eventsProvider(widget.streamId).notifier)
          .updateEvent(
            loan.copyWith(
              loan: Map<String, dynamic>.from(loanWithSchedule(loan.loan!, m)),
            ),
          ),
      'Loan repayments now ${frequencyWord(m.frequency)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: AppTheme.textMuted,
    );
    final today = dateOnly(widget.today ?? DateTime.now());
    final next = s.nextChargeDate;
    final nextCharge = next == null
        ? null
        : s.charges.where((c) => c.date == next).firstOrNull;
    final rows = <Widget>[];
    void row(String label, String value, {Key? key, Color? color}) {
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            key: key,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: Text(label, style: muted)),
              const SizedBox(width: 8),
              Expanded(
                flex: 6,
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      );
    }

    row(
      'Owed ${s.owedAt == null || s.owedAt == today ? 'today' : loanDate(s.owedAt!)}',
      loanMoney(s.owed),
      key: const ValueKey('loan-summary-owed'),
    );
    if (s.isFlat && s.flat != null) {
      final f = s.flat!;
      row(
        'Repayment',
        '${loanMoney(f.repayment)} ${frequencyWord(s.repaymentFrequency)}'
            '${f.finalRepayment != f.repayment ? ' (final ${loanMoney(f.finalRepayment)})' : ''}',
        key: const ValueKey('loan-summary-minimum-0'),
      );
    } else {
      for (final (i, m) in s.minimums.indexed) {
        row(
          i == 0
              ? 'Minimum repayment'
              : 'From ${loanDate(m.from)} (${_reason(m.reason)})',
          '${loanMoney(m.amount)} ${frequencyWord(m.frequency)}',
          key: ValueKey('loan-summary-minimum-$i'),
        );
      }
    }
    for (final t in s.transfers) {
      row(
        'From ${_streamName(t.peerStreamId)}',
        '${loanMoney(t.amount)} ${describeTransferFrequency(t)}',
      );
    }
    if (next != null) {
      row(
        'Next interest charge',
        '${loanDate(next)}'
            '${nextCharge == null ? '' : ' · ${loanMoney(nextCharge.interest)}'}',
      );
    }
    row('Interest this month', loanMoney(s.interestInMonth(today)));
    row(
      'Total interest',
      loanMoney(s.totalInterest),
      key: const ValueKey('loan-summary-total-interest'),
    );
    final payoff = s.payoffDate;
    row(
      'Paid off',
      payoff == null
          ? 'Not paid off by ${loanDate(s.termEndDate)}'
          : loanDate(payoff),
      key: const ValueKey('loan-summary-payoff'),
      color: payoff == null ? AppTheme.warning : null,
    );
    final atEnd = s.owedAtTermEnd;
    if (atEnd != null && atEnd != Decimal.zero) {
      row(
        atEnd > Decimal.zero
            ? 'Still owed at term end'
            : 'Overpaid at term end',
        loanMoney(atEnd.abs()),
        key: const ValueKey('loan-summary-term-end'),
      );
    }
    final offset = s.offset;
    if (offset != null) {
      row(
        'Offset account',
        offset.visible
            ? (offset.streamName ?? _streamName(offset.streamId ?? ''))
            : 'Linked offset account (not shared with you)',
        key: const ValueKey('loan-summary-offset'),
      );
      row(
        'Usable offset today',
        loanMoney(offset.usableToday),
        key: const ValueKey('loan-summary-offset-usable'),
      );
    }
    if (s.isFlat && s.flat != null) {
      row(
        'On a reducing balance',
        'About ${s.flat!.equivalentReducingRatePct.toStringAsFixed(2)}% p.a. '
            '(approx.)',
      );
    }

    return Column(
      key: const ValueKey('loan-summary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                summaryTypeLine(s),
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Container(
              key: const ValueKey('loan-summary-estimate'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.overlay,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('Estimate', style: muted),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...rows,
        if (offset != null) ...[
          const SizedBox(height: 6),
          Text(
            offsetBenefitText(offset, s.payoffDate),
            key: const ValueKey('loan-summary-offset-benefit'),
            style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.accent),
          ),
        ],
        ..._warnings(theme, muted),
        if (s.charges.isNotEmpty)
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey('loan-summary-charges'),
              tilePadding: EdgeInsets.zero,
              title: Text(
                'Interest charges (${s.charges.length})',
                style: theme.textTheme.bodyMedium,
              ),
              children: [
                for (final c in s.charges)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            loanDate(c.date) + (c.payout ? ' · payout' : ''),
                            style: muted,
                          ),
                        ),
                        Text(loanMoney(c.interest)),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 110,
                          child: Text(
                            loanMoney(c.closingBalance),
                            textAlign: TextAlign.right,
                            style: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Text(
          'Estimates from the loan terms; your lender\'s figures may differ.',
          style: muted,
        ),
      ],
    );
  }

  List<Widget> _warnings(ThemeData theme, TextStyle? muted) {
    final out = <Widget>[];
    void notice(String key, String text, List<Widget> buttons) {
      out.add(
        Container(
          key: ValueKey(key),
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          decoration: BoxDecoration(
            color: AppTheme.warning.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, style: theme.textTheme.bodySmall),
              if (buttons.isNotEmpty && widget.actions)
                Wrap(spacing: 4, children: buttons),
            ],
          ),
        ),
      );
    }

    final noTransfers = s.transfers.isEmpty;
    if (noTransfers) {
      notice('loan-warning-no-repayments', 'No repayments set up yet.', [
        TextButton(
          key: const ValueKey('loan-setup-repayments'),
          onPressed: _busy ? null : _setUp,
          child: const Text('Set up repayments'),
        ),
      ]);
    }
    if (s.has('belowMinimum')) {
      notice(
        'loan-warning-below-minimum',
        'Your repayments are below the '
            'minimum.',
        [
          for (final (i, m) in s.minimums.indexed)
            TextButton(
              key: ValueKey('loan-use-minimum-$i'),
              onPressed: _busy ? null : () => _useMinimum(m),
              child: Text(
                'Use ${loanMoney(m.amount)} from ${loanDate(m.from)}',
              ),
            ),
        ],
      );
    }
    if (s.has('repaymentsContinueAfterPayoff') && s.payoffDate != null) {
      notice(
        'loan-warning-after-payoff',
        'Repayments continue after the loan is paid off on '
            '${loanDate(s.payoffDate!)}.',
        [
          TextButton(
            key: const ValueKey('loan-end-at-payoff'),
            onPressed: _busy ? null : _endAtPayoff,
            child: const Text('End repayments at payoff'),
          ),
        ],
      );
    }
    if (s.has('notPaidByTermEnd')) {
      notice(
        'loan-warning-not-paid',
        'At these repayments the loan is not paid off by the end of its term '
            '(${loanDate(s.termEndDate)}).',
        const [],
      );
    }
    if (!noTransfers && s.has('repaymentScheduleMismatch')) {
      final m = widget.actions ? _matchSchedule : null;
      notice(
        'loan-warning-schedule',
        "Your repayments don't line up with this loan's repayment schedule "
            '(${frequencyWord(s.repaymentFrequency)} from '
            '${loanDate(s.firstRepaymentDate ?? s.startDate)}).',
        [
          if (m != null)
            TextButton(
              key: const ValueKey('loan-match-schedule'),
              onPressed: _busy ? null : _match,
              child: const Text('Match the loan to my repayments'),
            ),
        ],
      );
    }
    return out;
  }
}

typedef _SetupResult = ({String fromStreamId, Decimal amount});

/// "Set up repayments": which stream pays, and how much (prefilled with
/// the minimum); the schedule is the loan's.
class _SetupRepaymentsDialog extends ConsumerStatefulWidget {
  const _SetupRepaymentsDialog({
    required this.loanStreamId,
    required this.amount,
    required this.frequency,
    required this.first,
    this.count,
    this.finalAmount,
  });

  final String loanStreamId;
  final Decimal amount;
  final RepaymentFrequency frequency;
  final DateTime first;
  final int? count;
  final Decimal? finalAmount;

  @override
  ConsumerState<_SetupRepaymentsDialog> createState() =>
      _SetupRepaymentsDialogState();
}

class _SetupRepaymentsDialogState
    extends ConsumerState<_SetupRepaymentsDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.amount.toStringAsFixed(2),
  );
  BudgetStream? _from;

  @override
  void initState() {
    super.initState();
    final streams =
        ref.read(streamsProvider).valueOrNull ?? const <BudgetStream>[];
    bool ok(BudgetStream a) =>
        a.id != widget.loanStreamId && !a.hasLoan && a.role.canEdit;
    final last = ref.read(streamsProvider.notifier).lastStreamId;
    _from =
        streams.where((a) => a.id == last && ok(a)).firstOrNull ??
        streams.where(ok).firstOrNull;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = parseMoneyInput(_amount.text);
    final valid = _from != null && amount != null && amount > Decimal.zero;
    final when =
        '${frequencyLabel(widget.frequency)} from ${loanDate(widget.first)}'
        '${widget.count == null ? '' : ', ${widget.count} repayments'}'
        '${widget.finalAmount != null && widget.finalAmount != amount ? ' (the last ${loanMoney(widget.finalAmount!)})' : ''}';
    return AlertDialog(
      key: const ValueKey('loan-setup-dialog'),
      title: const Text('Set up repayments'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StreamPicker(
              keyPrefix: 'loan-setup-from',
              excludeStreamId: widget.loanStreamId,
              editableOnly: true,
              currentStreamId: _from?.id,
              title: 'Pay from',
              onSelected: (a) => setState(() => _from = a),
              builder: (context, open) => InkWell(
                key: const ValueKey('loan-setup-from'),
                onTap: open,
                borderRadius: BorderRadius.circular(10),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Pay from',
                    suffixIcon: Icon(Icons.arrow_drop_down_rounded),
                  ),
                  child: Text(_from?.name ?? 'Choose a stream'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('loan-setup-amount'),
              controller: _amount,
              decoration: const InputDecoration(
                labelText: 'Each repayment',
                prefixText: '\$ ',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Text(when, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('loan-setup-create'),
          onPressed: valid
              ? () =>
                    Navigator.of(context)
                        .pop((fromStreamId: _from!.id, amount: amount))
              : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// The editor's live summary (spec 003 §7): [draft] (null while the
/// form is invalid) previewed through `POST /project`, debounced 400 ms,
/// standing in for [replacesEventId] when editing a saved loan.
class LoanPreview extends ConsumerStatefulWidget {
  const LoanPreview({
    super.key,
    required this.streamId,
    required this.draft,
    this.replacesEventId,
    this.onServerError,
  });

  final String streamId;
  final BudgetEvent? draft;
  final String? replacesEventId;

  /// A 400 from the preview: the editor shows it on its field.
  final ValueChanged<String?>? onServerError;

  @override
  ConsumerState<LoanPreview> createState() => _LoanPreviewState();
}

class _LoanPreviewState extends ConsumerState<LoanPreview> {
  Timer? _debounce;
  LoanSummary? _summary;
  String? _error;
  bool _loading = false;
  String? _sent;
  int _seq = 0;

  static const debounce = Duration(milliseconds: 400);

  String? _key(BudgetEvent? d) =>
      d == null ? null : jsonEncode(d.toCreateJson());

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(LoanPreview old) {
    super.didUpdateWidget(old);
    if (_key(widget.draft) != _sent) _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    final d = widget.draft;
    _sent = _key(d);
    if (d == null) return;
    _debounce = Timer(debounce, () => _fetch(d));
  }

  Future<void> _fetch(BudgetEvent d) async {
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      final s = await ref
          .read(streamRepositoryProvider)
          .previewLoan(
            widget.streamId,
            d,
            replacesEventId: widget.replacesEventId,
          );
      if (!mounted || seq != _seq) return;
      setState(() {
        _summary = s;
        _error = null;
        _loading = false;
      });
      widget.onServerError?.call(null);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      final msg = e is ApiException && e.statusCode == 400
          ? e.message
          : friendlyError(e);
      setState(() {
        _error = msg;
        _loading = false;
      });
      if (e is ApiException && e.statusCode == 400) {
        widget.onServerError?.call(e.message);
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: AppTheme.textMuted,
    );
    final s = _summary;
    return Column(
      key: const ValueKey('loan-preview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (widget.draft == null && s == null)
          Text('Fill in the loan to see its summary.', style: muted)
        else if (_error != null && s == null)
          Text(_error!, style: muted)
        else if (s != null)
          Opacity(
            opacity: widget.draft == null ? 0.5 : 1,
            child: LoanSummaryPanel(streamId: widget.streamId, summary: s),
          ),
      ],
    );
  }
}
