// The variables reconciler (spec 010): re-derives the `variable_refs`
// index and re-resolves every formula, reporting drift. Nothing is
// changed: variables are checked against their stored dependencies
// directly; events, overrides and streams are re-resolved and re-indexed
// by the production code inside a transaction that is always rolled back,
// and the result compared with what is stored.
import 'package:budget_formula/budget_formula.dart';
import 'package:postgres/postgres.dart';

import '../repo/variable_ref_repo.dart';
import '../repo/variable_repo.dart';
import 'formulas.dart';
import 'variable_service.dart';

/// Drift lines (empty when everything agrees).
Future<List<String>> verifyVariables(Connection db) async {
  final drift = <String>[];

  // 1. Variables: each value from its expr over the stored values.
  final owners = [
    for (final r in await db
        .execute('SELECT DISTINCT owner_id::text FROM variables ORDER BY 1'))
      r[0] as String
  ];
  final spec = fieldSpecs['variable.value']!;
  for (final owner in owners) {
    final repo = VariableRepo(db);
    final lookup = await repo.lookup(owner);
    for (final v in await repo.list(owner)) {
      final r = resolveStoredText(v.expr, spec, lookup);
      if (r.error != null) {
        if (v.problem == null) {
          drift.add('variable ${v.id} \$${v.name}: "${v.expr}" fails '
              '(${r.error!.message}) but has no problem set');
        }
      } else if (v.problem != null) {
        drift.add('variable ${v.id} \$${v.name}: resolves but is flagged '
            '${v.problem}');
      } else if (r.value != v.value) {
        drift.add('variable ${v.id} \$${v.name}: stored ${v.value}, '
            '"${v.expr}" gives ${r.value}');
      }
    }
  }

  // 2. Rows and refs: recompute in a rolled-back transaction.
  await db.runTx((tx) async {
    final refsBefore = await _refs(tx);
    final rowsBefore = await _rows(tx);
    final eventIds = [
      for (final r in await tx.execute('''
        SELECT id::text FROM events
        WHERE amount_expr IS NOT NULL OR interval_expr IS NOT NULL
           OR count_expr IS NOT NULL OR expr_errors IS NOT NULL
           OR (loan IS NOT NULL AND loan::text LIKE '%Expr%')
        UNION SELECT event_id::text FROM occurrence_overrides
        WHERE amount_expr IS NOT NULL OR expr_error IS NOT NULL
        UNION SELECT event_id::text FROM variable_refs
        WHERE event_id IS NOT NULL
      ''')) r[0] as String
    ];
    final streamIds = [
      for (final r in await tx.execute('''
        SELECT id::text FROM streams
        WHERE seed_balance_expr IS NOT NULL
           OR loss_threshold_expr IS NOT NULL OR expr_errors IS NOT NULL
        UNION SELECT stream_id::text FROM variable_refs
        WHERE event_id IS NULL AND stream_id IS NOT NULL
      ''')) r[0] as String
    ];
    final service = VariableService(tx);
    await service.refreshEvents(eventIds);
    await service.refreshStreams(streamIds);
    final index = VariableRefIndex(tx);
    await index.reindexEvents(eventIds);
    await index.reindexStreams(streamIds);
    for (final r in await tx.execute('SELECT id::text FROM variables')) {
      await index.reindexVariable(r[0] as String);
    }
    final refsAfter = await _refs(tx);
    final rowsAfter = await _rows(tx);
    for (final k in {...rowsBefore.keys, ...rowsAfter.keys}) {
      if (rowsBefore[k] != rowsAfter[k]) {
        drift.add('$k: stored ${rowsBefore[k]}, re-resolved ${rowsAfter[k]}');
      }
    }
    for (final r in refsBefore.difference(refsAfter)) {
      drift.add('stale ref $r');
    }
    for (final r in refsAfter.difference(refsBefore)) {
      drift.add('missing ref $r');
    }
    await tx.rollback();
  });
  return drift;
}

Future<Set<String>> _refs(Session tx) async => {
      for (final r in await tx.execute('''
        SELECT concat_ws('|', variable_id, stream_id, event_id, override_date,
                         from_variable_id, field)
        FROM variable_refs''')) r[0] as String
    };

/// The resolved columns of every formula-bearing row, keyed by row.
Future<Map<String, String>> _rows(Session tx) async => {
      for (final r in await tx.execute('''
        SELECT 'event ' || id, concat_ws('|', amount, freq_interval,
                 occurrence_count, loan::text, expr_errors::text)
        FROM events
        WHERE amount_expr IS NOT NULL OR interval_expr IS NOT NULL
           OR count_expr IS NOT NULL OR expr_errors IS NOT NULL
           OR (loan IS NOT NULL AND loan::text LIKE '%Expr%')
        UNION ALL
        SELECT 'override ' || event_id || ' ' || date,
               concat_ws('|', amount, expr_error::text)
        FROM occurrence_overrides
        WHERE amount_expr IS NOT NULL OR expr_error IS NOT NULL
        UNION ALL
        SELECT 'stream ' || id, concat_ws('|', seed_balance, loss_threshold,
                 expr_errors::text)
        FROM streams
        WHERE seed_balance_expr IS NOT NULL
           OR loss_threshold_expr IS NOT NULL OR expr_errors IS NOT NULL
      ''')) r[0] as String: r[1] as String
    };
