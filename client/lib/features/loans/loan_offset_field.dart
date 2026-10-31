import 'package:decimal/decimal.dart';
import 'package:budget_loan/budget_loan.dart' show RateType;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/stream_picker.dart';
import 'loan_models.dart';

/// The helper under the offset picker (spec 004 §15).
String offsetHelperText(BudgetStream? offset) {
  if (offset == null) {
    return 'Optional. A stream whose balance reduces the interest charged.';
  }
  final zero = offset.lossThreshold < Decimal.zero
      ? Decimal.zero
      : offset.lossThreshold;
  return 'Only the balance above its alert threshold (${loanMoney(zero)}) '
      'reduces interest.';
}

/// Streams that can be this loan's offset account: my own (not shared),
/// not the loan's stream, and not holding a loan.
bool offsetCandidate(BudgetStream s, String loanStreamId) =>
    !s.shared && s.id != loanStreamId && !s.hasLoan;

/// "Offset account" on a reducing loan (spec 004). Only the stream owner
/// links or unlinks it; others see it read-only.
class LoanOffsetField extends ConsumerWidget {
  const LoanOffsetField({
    super.key,
    required this.draft,
    required this.loanStreamId,
    required this.canEdit,
    required this.onChanged,
  });

  final LoanDraft draft;
  final String loanStreamId;
  final bool canEdit;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final streams =
        ref.watch(streamsProvider).valueOrNull ?? const <BudgetStream>[];
    final id = draft.offsetStreamId;
    final offset = id == null
        ? null
        : streams.where((s) => s.id == id).firstOrNull;
    final hidden = draft.offsetHidden && id == null;
    final label = hidden
        ? 'Linked offset account (not shared with you)'
        : id == null
        ? 'None'
        : (offset?.name ?? 'Linked offset account');
    final noneApplies =
        draft.hasOffset &&
        draft.advanced &&
        !draft.periods.any((p) => p.offsetApplies);

    final helper = hidden
        ? null
        : canEdit || id != null
        ? offsetHelperText(offset)
        : 'Only the stream owner can link an offset account.';
    Widget field(VoidCallback? open) => Semantics(
      label: 'Offset account: $label',
      hint: helper,
      button: open != null,
      onTap: open,
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('loan-offset'),
        onTap: open,
        borderRadius: BorderRadius.circular(10),
        child: InputDecorator(
          isEmpty: false,
          decoration: InputDecoration(
            labelText: 'Offset account',
            enabled: open != null,
            prefixIcon: const Icon(Icons.savings_outlined),
            suffixIcon: open == null
                ? null
                : const Icon(Icons.arrow_drop_down_rounded),
            helperText: helper,
            helperMaxLines: 3,
          ),
          child: Text(
            label,
            key: const ValueKey('loan-offset-value'),
            style: id == null && !hidden
                ? theme.textTheme.bodyLarge?.copyWith(color: AppTheme.textFaint)
                : theme.textTheme.bodyLarge,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );

    void pick(String? next) {
      if (next == draft.offsetStreamId) return;
      final wasNone = !draft.hasOffset;
      draft.offsetStreamId = next;
      if (wasNone && next != null && draft.advanced) {
        if (!draft.periods.any((p) => p.offsetApplies)) {
          // The defaults: variable periods offset, fixed ones don't.
          for (final p in draft.periods) {
            p.offsetApplies = p.type == RateType.variable;
          }
        }
      }
      onChanged();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (canEdit)
          StreamPicker(
            keyPrefix: 'loan-offset',
            currentStreamId: id,
            excludeStreamId: loanStreamId,
            include: (s) => offsetCandidate(s, loanStreamId),
            onNone: () => pick(null),
            noneLabel: 'None',
            onSelected: (s) => pick(s.id),
            builder: (context, open) => field(open),
          )
        else
          field(null),
        if (noneApplies) ...[
          const SizedBox(height: 6),
          Text(
            'Offset applies is off for every rate period, so the offset '
            "doesn't reduce interest.",
            key: const ValueKey('loan-offset-none-applies'),
            style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning),
          ),
        ],
      ],
    );
  }
}
