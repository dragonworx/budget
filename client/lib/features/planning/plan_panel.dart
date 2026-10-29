import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/app_theme.dart';
import '../events/solve_sheet.dart';
import 'goal_models.dart';
import 'goal_panel.dart';
import 'scenarios_panel.dart';

/// The Plan view's modes: [goal] is "Reach a balance", [payment] is
/// "Spread a total"; [scenarios] lists saved balance plans.
enum PlanTab { goal, payment, scenarios }

/// Header labels for the two modes.
const planModeBalanceLabel = 'Reach a balance';
const planModeTotalLabel = 'Spread a total';

/// Non-blocking planning panel docked beside (desktop) or under (phone)
/// the chart, so the chart and its live preview line stay visible.
///
/// One Plan view with two modes sharing the schedule (start, end, amount
/// each time, frequency, count): "Reach a balance" adds the target and
/// start balance, end-date vs stay-above, one-off and interest; "Spread a
/// total" adds the total and rounding. Switching carries the typed schedule
/// across; each mode keeps its own server call.
class PlanPanel extends StatefulWidget {
  const PlanPanel({
    super.key,
    required this.stream,
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

  final BudgetStream stream;
  final PlanTab tab;
  final ValueChanged<PlanTab> onTab;
  final VoidCallback onClose;
  final ValueChanged<BudgetEvent?> onPreview;
  final ValueChanged<SolveResult> onDone;
  final void Function(GoalRequest, GoalResult?) onGoalResult;
  final GlobalKey<GoalPanelState>? goalKey;
  final GoalRequest? goalInitial;
  final bool compact;

  @override
  State<PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends State<PlanPanel> {
  GlobalKey<SolveSheetState> _totalKey = GlobalKey();
  final GlobalKey<GoalPanelState> _ownGoalKey = GlobalKey();

  GlobalKey<GoalPanelState> get _goalKey => widget.goalKey ?? _ownGoalKey;

  @override
  void didUpdateWidget(PlanPanel old) {
    super.didUpdateWidget(old);
    // Another stream: a fresh "Spread a total".
    if (old.stream.id != widget.stream.id) _totalKey = GlobalKey();
  }

  /// Switching straight between the modes carries the typed schedule over.
  void _switchTo(PlanTab to) {
    final from = widget.tab;
    if (from != to && from != PlanTab.scenarios && to != PlanTab.scenarios) {
      final goal = _goalKey.currentState;
      final total = _totalKey.currentState;
      if (goal != null && total != null) {
        if (to == PlanTab.payment) {
          total.schedule = goal.schedule;
        } else {
          goal.schedule = total.schedule;
        }
      }
    }
    widget.onTab(to);
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final fullScreen = widget.fullScreen;
    final onExpand = widget.onExpand;
    final stream = widget.stream;
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
                        label: Text(
                          planModeBalanceLabel,
                          key: ValueKey('plan-mode-balance'),
                        ),
                      ),
                      ButtonSegment(
                        value: PlanTab.payment,
                        label: Text(
                          planModeTotalLabel,
                          key: ValueKey('plan-mode-total'),
                        ),
                      ),
                    ],
                    emptySelectionAllowed: true,
                    selected: {if (tab != PlanTab.scenarios) tab},
                    onSelectionChanged: (s) {
                      if (s.isNotEmpty) _switchTo(s.first);
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
                    onPressed: () => widget.onTab(
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
                    onPressed: widget.onClose,
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
                  key: _goalKey,
                  stream: stream,
                  initial: widget.goalInitial,
                  onResult: widget.onGoalResult,
                  onSaveScenario: widget.onSaveScenario,
                ),
                SolveSheet(
                  key: _totalKey,
                  streamId: stream.id,
                  initial: defaultPlanRequest(),
                  creditOnly: true,
                  readOnly: !stream.role.canEdit,
                  onPreview: widget.onPreview,
                  onDone: widget.onDone,
                ),
                ScenariosPanel(
                  stream: stream,
                  onLoad: (s) => widget.onLoadScenario?.call(s),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
