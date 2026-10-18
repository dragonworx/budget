import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/app_theme.dart';
import '../transactions/solve_sheet.dart';

/// Non-blocking planning panel docked beside (desktop) or under (phone)
/// the chart, so the chart and its live preview line stay visible.
class PlanPanel extends StatelessWidget {
  const PlanPanel({
    super.key,
    required this.accountId,
    required this.onClose,
    required this.onPreview,
    required this.onDone,
    this.compact = false,
  });

  final String accountId;
  final VoidCallback onClose;
  final ValueChanged<Transaction?> onPreview;
  final ValueChanged<SolveResult> onDone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const ValueKey('plan-panel'),
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.calculate_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Plan a payment',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: const ValueKey('plan-close'),
                  tooltip: 'Close planner',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SolveSheet(
              key: ValueKey('plan-payment-$accountId'),
              accountId: accountId,
              initial: defaultPlanRequest(),
              creditOnly: true,
              onPreview: onPreview,
              onDone: onDone,
            ),
          ),
        ],
      ),
    );
  }
}
