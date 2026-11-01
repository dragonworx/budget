// 013 group D: the planner and goal fields with plain numbers, recorded
// on the code before the rollout (formulas off). Must stay identical.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'group_d_support.dart';

void main() {
  for (final w in const [700.0, 400.0]) {
    final n = w.toInt();
    testWidgets('plan blank ($w)', (tester) async {
      await pumpPlan(tester, width: w);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../goldens/rollout_d_plan_blank_$n.png'),
      );
    });

    testWidgets('plan amount + interval + count ($w)', (tester) async {
      await pumpPlan(tester, width: w);
      await typeIn(tester, 'plan-amount', '75');
      await typeIn(tester, 'plan-interval', '2');
      await typeIn(tester, planCount, '6');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../goldens/rollout_d_plan_filled_$n.png'),
      );
    });

    // 560, not 400: a typed total shows the rounding dropdown, whose
    // Ahem label overflows below ~520 (on the old code too).
    testWidgets('plan typed errors ($w)', (tester) async {
      await pumpPlan(tester, width: w == 400 ? 560 : w);
      await typeIn(tester, 'plan-total', '0');
      await typeIn(tester, 'plan-amount', '1.2.3');
      await typeIn(tester, 'plan-interval', '0');
      await typeIn(tester, planCount, '0');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../goldens/rollout_d_plan_errors_$n.png'),
      );
    });

    testWidgets('goal default ($w)', (tester) async {
      await pumpGoal(tester, width: w);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../goldens/rollout_d_goal_blank_$n.png'),
      );
    });

    testWidgets('goal typed values and errors ($w)', (tester) async {
      await pumpGoal(tester, width: w);
      await typeIn(tester, 'goal-field-startBalance', '-250.5');
      await typeIn(tester, 'goal-field-targetBalance', 'abc');
      await typeIn(tester, 'goal-field-oneOff', '-900');
      await typeIn(tester, 'goal-field-rate', '4.5');
      await typeIn(tester, 'goal-field-count', '-1');
      await typeIn(tester, 'goal-field-interval-interval', '3');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../goldens/rollout_d_goal_typed_$n.png'),
      );
    });
  }
}
