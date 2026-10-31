import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../data/api_client.dart' show friendlyError;
import 'loan_summary_panel.dart';

/// Timeline ⋮ More → "Loan summary" (spec 003 §12): the stream's loan
/// summary with its warning actions (editors only), in a dialog.
Future<void> showLoanSummary(BuildContext context, BudgetStream stream) =>
    showDialog<void>(
      context: context,
      builder: (context) => LoanSummaryDialog(stream: stream),
    );

class LoanSummaryDialog extends ConsumerWidget {
  const LoanSummaryDialog({super.key, required this.stream});

  final BudgetStream stream;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(loanSummaryProvider(stream.id));
    final narrow = MediaQuery.sizeOf(context).width < 400;
    return Dialog(
      key: const ValueKey('loan-summary-dialog'),
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrow ? 12 : 40,
        vertical: 24,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Loan summary',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('loan-summary-close'),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: async.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => Text(friendlyError(e)),
                  data: (s) => s == null
                      ? const Text('This stream has no loan.')
                      : LoanSummaryPanel(
                          streamId: stream.id,
                          summary: s,
                          actions: stream.role.canEdit,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
