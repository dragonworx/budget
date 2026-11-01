import 'dart:convert';

import 'package:postgres/postgres.dart';

import '../domain/formulas.dart';

/// Maintains variable_refs, the dependency index from variables to the
/// fields whose formulas name them (spec 010). Only the debit row of a
/// transfer pair is indexed (D10); its peer carries the same texts.
class VariableRefIndex {
  VariableRefIndex(this._db);
  final Session _db;

  /// Rebuilds the refs of events [ids], their transfer peers and their
  /// overrides. Call after every write that may change texts, direction,
  /// transfer link or overrides (and after syncPeer, whose override copy
  /// cascades the peer's refs away).
  Future<void> reindexEvents(Iterable<String> ids) async {
    final idList = ids.toSet().toList();
    if (idList.isEmpty) return;
    final rows = await _db.execute(
      Sql.named('''
        SELECT e.id::text, e.stream_id::text, s.owner_id::text, e.direction,
               e.transfer_id IS NOT NULL, e.amount_expr, e.interval_expr,
               e.count_expr,
               CASE WHEN e.loan IS NOT NULL AND e.loan::text LIKE '%Expr%'
                    THEN e.loan END
        FROM events e JOIN streams s ON s.id = e.stream_id
        WHERE e.id = ANY(@ids::text[]::uuid[])
           OR e.transfer_id IN (SELECT transfer_id FROM events
                                WHERE id = ANY(@ids::text[]::uuid[])
                                  AND transfer_id IS NOT NULL)
      '''),
      parameters: {'ids': idList},
    );
    final allIds = [for (final r in rows) r[0] as String];
    if (allIds.isEmpty) return;
    await _db.execute(
      Sql.named('DELETE FROM variable_refs '
          'WHERE event_id = ANY(@ids::text[]::uuid[])'),
      parameters: {'ids': allIds},
    );
    // Indexed rows: plain events and the debit side of transfers.
    final indexed = [
      for (final r in rows)
        if (!(r[4] as bool) || r[3] == 'debit') r,
    ];
    if (indexed.isEmpty) return;
    final overrides = await _db.execute(
      Sql.named('''
        SELECT event_id::text, date::text, amount_expr
        FROM occurrence_overrides
        WHERE event_id = ANY(@ids::text[]::uuid[]) AND amount_expr IS NOT NULL
      '''),
      parameters: {
        'ids': [for (final r in indexed) r[0] as String]
      },
    );
    final byEvent = <String, List<ResultRow>>{};
    for (final o in overrides) {
      (byEvent[o[0] as String] ??= []).add(o);
    }
    final refs = <_Ref>[];
    for (final r in indexed) {
      final id = r[0] as String, stream = r[1] as String;
      final owner = r[2] as String;
      final loan = r[8] == null ? null : _jsonMap(r[8]);
      final texts = eventFieldTexts(
          amountExpr: r[5] as String?,
          intervalExpr: r[6] as String?,
          countExpr: r[7] as String?,
          loan: loan);
      for (final e in texts.entries) {
        for (final n in namesIn(e.value)) {
          refs.add(_Ref(owner, n, stream, id, null, e.key));
        }
      }
      for (final o in byEvent[id] ?? const <ResultRow>[]) {
        for (final n in namesIn(o[2] as String)) {
          refs.add(
              _Ref(owner, n, stream, id, o[1] as String, FormulaField.amount));
        }
      }
    }
    await _insert(refs);
  }

  /// Rebuilds the stream-level refs (seed balance, loss threshold) of
  /// streams [ids].
  Future<void> reindexStreams(Iterable<String> ids) async {
    final idList = ids.toSet().toList();
    if (idList.isEmpty) return;
    await _db.execute(
      Sql.named('DELETE FROM variable_refs WHERE event_id IS NULL '
          'AND stream_id = ANY(@ids::text[]::uuid[])'),
      parameters: {'ids': idList},
    );
    final rows = await _db.execute(
      Sql.named('''
        SELECT id::text, owner_id::text, seed_balance_expr, loss_threshold_expr
        FROM streams WHERE id = ANY(@ids::text[]::uuid[])
          AND (seed_balance_expr IS NOT NULL
               OR loss_threshold_expr IS NOT NULL)
      '''),
      parameters: {'ids': idList},
    );
    final refs = <_Ref>[];
    for (final r in rows) {
      for (final (i, field) in [
        (2, FormulaField.seedBalance),
        (3, FormulaField.lossThreshold)
      ]) {
        final t = r[i] as String?;
        if (t == null) continue;
        for (final n in namesIn(t)) {
          refs.add(_Ref(r[1] as String, n, r[0] as String, null, null, field));
        }
      }
    }
    await _insert(refs);
  }

  /// Rebuilds the refs variable [id]'s own expr makes.
  Future<void> reindexVariable(String id) async {
    await _db.execute(
      Sql.named('DELETE FROM variable_refs '
          'WHERE from_variable_id = @id::uuid'),
      parameters: {'id': id},
    );
    final rows = await _db.execute(
      Sql.named('SELECT owner_id::text, expr FROM variables '
          'WHERE id = @id::uuid'),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return;
    final owner = rows.first[0] as String;
    final names = namesIn(rows.first[1] as String);
    if (names.isEmpty) return;
    await _db.execute(
      Sql.named('''
        INSERT INTO variable_refs (variable_id, from_variable_id, field)
        SELECT v.id, @id::uuid, 'value' FROM variables v
        WHERE v.owner_id = @o::uuid AND lower(v.name) = ANY(@n::text[])
        ON CONFLICT DO NOTHING
      '''),
      parameters: {'id': id, 'o': owner, 'n': names.toList()},
    );
  }

  /// Inserts [refs] whose names exist among their owner's variables
  /// (unknown names are flagged on the row, not indexed, D9).
  Future<void> _insert(List<_Ref> refs) async {
    if (refs.isEmpty) return;
    await _db.execute(
      Sql.named('''
        INSERT INTO variable_refs (variable_id, stream_id, event_id,
                                   override_date, field)
        SELECT v.id, r.stream_id::uuid, NULLIF(r.event_id, '')::uuid,
               NULLIF(r.odate, '')::date, r.field
        FROM unnest(@owners::text[], @names::text[], @streams::text[],
                    @events::text[], @dates::text[], @fields::text[])
             AS r(owner_id, name, stream_id, event_id, odate, field)
        JOIN variables v ON v.owner_id = r.owner_id::uuid
                        AND lower(v.name) = r.name
        ON CONFLICT DO NOTHING
      '''),
      parameters: {
        'owners': [for (final r in refs) r.owner],
        'names': [for (final r in refs) r.name],
        'streams': [for (final r in refs) r.stream],
        'events': [for (final r in refs) r.event ?? ''],
        'dates': [for (final r in refs) r.date ?? ''],
        'fields': [for (final r in refs) r.field],
      },
    );
  }

  static Map<String, dynamic> _jsonMap(Object? v) =>
      Map<String, dynamic>.from((v is String ? jsonDecode(v) : v) as Map);
}

class _Ref {
  _Ref(this.owner, this.name, this.stream, this.event, this.date, this.field);
  final String owner, name, stream;
  final String? event, date;
  final String field;
}
