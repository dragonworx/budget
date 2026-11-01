// Variables manager goldens (spec 012): desktop (the 640 dialog), 320,
// the empty state and the attention banner with a broken row.
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'manager_support.dart';

void main() {
  final dialog = find.byType(Dialog);

  for (final (tag, width, height) in [
    ('desktop', 900.0, 720.0),
    ('320', 320.0, 640.0),
  ]) {
    testWidgets('table $tag', (tester) async {
      await pumpManager(tester, width: width, height: height);
      await expectLater(
        dialog,
        matchesGoldenFile('../goldens/variables_manager_$tag.png'),
      );
    });
  }

  testWidgets('empty', (tester) async {
    await pumpManager(tester, vars: const [], width: 900, height: 600);
    await expectLater(
      dialog,
      matchesGoldenFile('../goldens/variables_manager_empty.png'),
    );
  });

  testWidgets('attention', (tester) async {
    final h = await pumpManager(
      tester,
      width: 900,
      height: 720,
      vars: [
        ...baseVars(),
        vr(
          'v5',
          'broken',
          r'$gone * 2',
          value: '10',
          problem: {'code': 'unknown_variable', 'message': r'No $gone'},
        ),
      ],
    );
    h.vars.attentionJson = {
      'items': [
        {
          'entity': 'variable',
          'entityId': 'v5',
          'variableName': 'broken',
          'field': 'value',
          'expr': r'$gone * 2',
          'error': {'code': 'unknown_variable', 'message': r'No $gone'},
        },
      ],
      'count': 1,
    };
    ProviderScope.containerOf(tester.element(k('variables-manager')))
        .invalidate(variableAttentionProvider);
    await tester.pumpAndSettle();
    await expectLater(
      dialog,
      matchesGoldenFile('../goldens/variables_manager_attention.png'),
    );
  });
}
