import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/app_theme.dart';
import '../transactions/solve_sheet.dart';
import 'goal_models.dart';
import 'goal_panel.dart';
import 'scenarios_panel.dart';

enum PlanTab { goal, payment, scenarios }

/// Non-blocking planning panel docked beside (desktop) or under (phone)
/// the chart, so the chart and its live preview line stay visible.
/// "Plan a goal" solves balance goals; "Plan a payment" is the transaction
/// calculator.
class PlanPanel extends StatelessWidget {
  const PlanPanel({
    super.key,
    required this.pool,
    required this.tab,
    required this.onTab,
    required this.onClose,
    required this.onPreview,
    required this.onDone,
    required this.onGoalResult,
    this.goalKey,
    this.goalInitial,
    this.compact = false,
    this.onSaveScenario,
    this.onLoadScenario,
    this.fullScreen = false,
    this.onExpand,
  });

  /// Full-screen page: the page app bar carries close, so the panel drops
  /// its own close button and border.
  final bool fullScreen;

  /// Docked on phone portrait ("Show on chart"): back to full screen.
  final VoidCallback? onExpand;

  final ValueChanged<GoalRequest>? onSaveScenario;
  final ValueChanged<Scenario>? onLoadScenario;

  final Pool pool;
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
        borderRadius: BorderRadius.circular(fullScreen ? 0 : 16),
        side: fullScreen
            ? BorderSide.none
            : const BorderSide(color: AppTheme.border),
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
                      ),
                      ButtonSegment(
                        value: PlanTab.payment,
                        label: Text('Plan a payment'),
                      ),
                    ],
                    emptySelectionAllowed: true,
                    selected: {if (tab != PlanTab.scenarios) tab},
                    onSelectionChanged: (s) {
                      if (s.isNotEmpty) onTab(s.first);
                    },
                  ),
                ),
                // Docked on phone portrait the row is tight: scenarios are
                // reachable from full screen.
                if (onExpand == null)
                  IconButton(
                    key: const ValueKey('plan-tab-scenarios'),
                    tooltip: 'Saved scenarios',
                    isSelected: tab == PlanTab.scenarios,
                    onPressed: () => onTab(
                      tab == PlanTab.scenarios
                          ? PlanTab.goal
                          : PlanTab.scenarios,
                    ),
                    icon: const Icon(Icons.bookmarks_outlined),
                    selectedIcon: const Icon(
                      Icons.bookmarks_rounded,
                      color: AppTheme.accent,
                    ),
                  ),
                if (onExpand != null)
                  IconButton(
                    key: const ValueKey('plan-expand'),
                    tooltip: 'Full screen',
                    onPressed: onExpand,
                    icon: const Icon(Icons.open_in_full_rounded),
                  ),
                if (!fullScreen)
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
                  pool: pool,
                  initial: goalInitial,
                  onResult: onGoalResult,
                  onSaveScenario: onSaveScenario,
                ),
                SolveSheet(
                  key: ValueKey('plan-payment-${pool.id}'),
                  poolId: pool.id,
                  initial: defaultPlanRequest(),
                  creditOnly: true,
                  readOnly: !pool.role.canEdit,
                  onPreview: onPreview,
                  onDone: onDone,
                ),
                ScenariosPanel(
                  pool: pool,
                  onLoad: (s) => onLoadScenario?.call(s),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
