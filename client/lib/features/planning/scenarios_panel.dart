import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/money_text.dart';
import 'goal_models.dart';

Color scenarioColor(int i) =>
    AppTheme.scenarioColors[i % AppTheme.scenarioColors.length];

/// Human summary of [scenarioDelta]: e.g. "+$420 by 1 Mar 27 · alert +3 wks".
String scenarioDeltaText(
  GoalResult r,
  DateTime? baselineAlert,
) {
  final d = scenarioDelta(r, baselineAlert);
  final parts = <String>[];
  final end = r.values?.endDate;
  if (d.balance != null) {
    final b = d.balance!;
    final money = formatMoneyAmount(b.abs());
    final by = end == null ? '' : ' by ${DateFormat('d MMM yy').format(end)}';
    parts.add(
      b.abs() < 0.005 ? 'no change$by' : '${b > 0 ? '+' : '−'}$money$by',
    );
  }
  if (d.alertShiftDays != null) {
    parts.add('alert ${shiftText(d.alertShiftDays!)}');
  } else if (d.alertCleared) {
    parts.add('no alert');
  } else if (d.alertNew) {
    parts.add('new alert ${DateFormat('d MMM yy').format(r.alertDate!)}');
  }
  return parts.join(' · ');
}

/// Saved what-ifs for a pool: include/exclude each on the chart (as a
/// coloured ghost line), compare it with the pool as it is, load it back
/// into the goal planner, or delete it. Never edits real transactions.
class ScenariosPanel extends ConsumerWidget {
  const ScenariosPanel({
    super.key,
    required this.pool,
    required this.onLoad,
  });

  final Pool pool;
  final ValueChanged<Scenario> onLoad;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final results = ref.watch(scenarioResultsProvider(pool.id));
    final insights = ref.watch(insightsProvider(pool.id)).valueOrNull;
    final repo = ref.read(poolRepositoryProvider);
    Future<void> run(Future<void> Function() f) async {
      try {
        await f();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Scenario: $e')));
        }
      }
      ref.invalidate(scenariosProvider(pool.id));
    }

    final list = results.valueOrNull;
    return ListView(
      key: const ValueKey('scenarios-panel'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      children: [
        Text(
          'Saved what-ifs. Included ones are drawn on the chart in their '
          'colour and compared with the pool as it is now. Save one '
          'from "Plan a goal".',
          style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textMuted),
        ),
        const SizedBox(height: 10),
        if (results.isLoading && list == null)
          const LinearProgressIndicator(minHeight: 2),
        if (list != null && list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No scenarios yet.',
              key: const ValueKey('scenarios-empty'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppTheme.textMuted,
              ),
            ),
          ),
        for (final (s, r) in list ?? const <(Scenario, GoalResult?)>[])
          Card(
            key: ValueKey('scenario-${s.id}'),
            margin: const EdgeInsets.only(bottom: 8),
            color: AppTheme.raised,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 2, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 18,
                        height: 3,
                        color: s.included
                            ? scenarioColor(s.colorIndex)
                            : AppTheme.textFaint,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      Switch(
                        key: ValueKey('scenario-include-${s.id}'),
                        value: s.included,
                        onChanged: !pool.role.canEdit
                            ? null
                            : (on) => run(
                          () => repo.updateScenario(
                            pool.id,
                            s.id,
                            included: on,
                          ),
                        ),
                      ),
                      IconButton(
                        key: ValueKey('scenario-load-${s.id}'),
                        tooltip: 'Open in Plan a goal',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => onLoad(s),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                      if (pool.role.canEdit)
                      IconButton(
                        key: ValueKey('scenario-delete-${s.id}'),
                        tooltip: 'Delete scenario',
                        visualDensity: VisualDensity.compact,
                        onPressed: () =>
                            run(() => repo.deleteScenario(pool.id, s.id)),
                        icon: const Icon(Icons.delete_outline, size: 18),
                      ),
                    ],
                  ),
                  Text(
                    !s.included
                        ? 'Excluded — not on the chart'
                        : r == null
                        ? (results.isLoading ? 'Solving…' : 'Can’t solve now')
                        : scenarioDeltaText(r, insights?.alertDate),
                    key: ValueKey('scenario-delta-${s.id}'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: s.included ? AppTheme.text : AppTheme.textFaint,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
