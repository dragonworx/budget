import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/app_theme.dart';
import '../transactions/solve_sheet.dart';
import 'goal_models.dart';
import 'goal_panel.dart';

enum PlanTab { goal, payment }

/// Non-blocking planning panel docked beside (desktop) or under (phone)
/// the chart, so the chart and its live preview line stay visible.
/// "Plan a goal" solves balance goals; "Plan a payment" is the transaction
/// calculator.
class PlanPanel extends StatelessWidget {
  const PlanPanel({
    super.key,
    required this.account,
    required this.tab,
    required this.onTab,
    required this.onClose,
    required this.onPreview,
    required this.onDone,
    required this.onGoalResult,
    this.goalKey,
    this.goalInitial,
    this.compact = false,
  });

  final Account account;
  final PlanTab tab;
  final ValueChanged<PlanTab> onTab;
  final VoidCallback onClose;
  final ValueChanged<Transaction?> onPreview;
  final ValueChanged<SolveResult> onDone;
  final void Function(GoalRequest, GoalResult?) onGoalResult;
  final GlobalKey<GoalPanelState>? goalKey;
  final GoalRequest? goalInitial;
  final bool compact;

  @override
  Widget build(BuildContext context) {
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
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<PlanTab>(
                    key: const ValueKey('plan-tabs'),
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: PlanTab.goal,
                        label: Text('Plan a goal'),
                        icon: Icon(Icons.flag_rounded, size: 16),
                      ),
                      ButtonSegment(
                        value: PlanTab.payment,
                        label: Text('Plan a payment'),
                        icon: Icon(Icons.calculate_outlined, size: 16),
                      ),
                    ],
                    selected: {tab},
                    onSelectionChanged: (s) => onTab(s.first),
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
            child: IndexedStack(
              index: tab.index,
              children: [
                GoalPanel(
                  key: goalKey,
                  account: account,
                  initial: goalInitial,
                  onResult: onGoalResult,
                ),
                SolveSheet(
                  key: ValueKey('plan-payment-${account.id}'),
                  accountId: account.id,
                  initial: defaultPlanRequest(),
                  creditOnly: true,
                  onPreview: onPreview,
                  onDone: onDone,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
