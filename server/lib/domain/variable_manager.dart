// The variable write path (spec 010): create, patch (value, rename),
// delete and the dry-run preview, with topological re-evaluation of
// dependent variables and fan-out to the fields that use them.
import 'dart:convert';

import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';

import '../repo/audit_repo.dart';
import '../repo/variable_ref_repo.dart';
import '../repo/variable_repo.dart';
import 'formulas.dart';
import 'variable_service.dart';

/// A parsed variable body (POST all required but name/expr; PATCH any).
class VariableInput {
  String? name, expr, unit, description;
  int? displayDecimals;
  bool setDescription = false, setDisplayDecimals = false;

  static const units = {'money', 'percent', 'number'};

  static VariableInput parse(Map<String, dynamic> body,
      {required bool create}) {
    final i = VariableInput();
    final n = body['name'];
    if (n != null) {
      if (n is! String) throw const FormatException('name must be a string');
      i.name = n.trim().startsWith(r'$') ? n.trim().substring(1) : n.trim();
    }
    final e = body['expr'] ?? body['value'];
    if (e != null) {
      if (e is num) {
        i.expr = e.toString();
      } else if (e is String) {
        i.expr = e;
      } else {
        throw const FormatException('expr must be a string');
      }
    }
    final u = body['unit'];
    if (u != null) {
      if (u is! String || !units.contains(u)) {
        throw const FormatException('unit must be money, percent or number');
      }
      i.unit = u;
    }
    if (body.containsKey('description')) {
      final d = body['description'];
      if (d != null && (d is! String || d.length > 200)) {
        throw const FormatException(
            'description must be a string of at most 200 characters');
      }
      i.setDescription = true;
      final t = (d as String?)?.trim();
      i.description = t == null || t.isEmpty ? null : t;
    }
    if (body.containsKey('displayDecimals')) {
      final d = body['displayDecimals'];
      if (d != null && (d is! int || d < 0 || d > 6)) {
        throw const FormatException('displayDecimals must be 0 to 6');
      }
      i.setDisplayDecimals = true;
      i.displayDecimals = d as int?;
    }
    if (create && (i.name == null || i.expr == null)) {
      throw const FormatException('name and expr are required');
    }
    return i;
  }
}

class _V {
  _V(this.id, this.name, this.unit, this.expr, this.value, this.problem);
  final String? id;
  String name, unit, expr;
  Decimal value;
  Map<String, dynamic>? problem;
  String get lower => name.toLowerCase();
  VariableValue get vv => VariableValue(
      name,
      value,
      switch (unit) {
        'money' => VariableUnit.money,
        'percent' => VariableUnit.percent,
        _ => VariableUnit.number,
      });
}

class _Lookup extends VariableLookup {
  _Lookup(this.m);
  final Map<String, VariableValue> m;
  @override
  VariableValue? lookup(String lowerName) => m[lowerName];
  @override
  Iterable<VariableValue> get values => m.values;
}

class VariableManager {
  VariableManager(this._db,
      {required this.ownerId, required this.actorId, this.audit = true});
  final Session _db;
  final String ownerId;
  final String actorId;

  /// False for the preview (rolled back anyway; no NOTIFYs queued).
  final bool audit;
  late final service = VariableService(_db);

  Future<void> _lock() => _db.execute(
        Sql.named("SELECT pg_advisory_xact_lock("
            "hashtextextended('variables:' || @o, 0))"),
        parameters: {'o': ownerId},
      );

  Future<List<_V>> _load() async {
    final rows = await _db.execute(
      Sql.named('SELECT id::text, name, unit, expr, value::text, problem '
          'FROM variables WHERE owner_id = @o::uuid'),
      parameters: {'o': ownerId},
    );
    return [
      for (final r in rows)
        _V(
            r[0] as String,
            r[1] as String,
            r[2] as String,
            r[3] as String,
            Decimal.parse(r[4] as String),
            r[5] == null
                ? null
                : Map<String, dynamic>.from((r[5] is String
                    ? jsonDecode(r[5] as String)
                    : r[5]) as Map)),
    ];
  }

  void _checkName(String name, List<_V> all, _V? self) {
    final lower = name.toLowerCase();
    for (final v in all) {
      if (!identical(v, self) && v.lower == lower) {
        throw VariableException(
            409,
            'A variable named "\$${v.name}" already exists',
            {'code': 'variable_name_taken'});
      }
    }
    final problem = variableNameProblem(name, const []);
    if (problem != null) {
      throw VariableException(400, problem, {'code': 'bad_name'});
    }
  }

  /// Validates the graph and re-evaluates [all] (with [target]'s new
  /// state) in dependency order. Returns the variables whose value or
  /// problem changed (target first). Throws for a target that doesn't
  /// resolve, a cycle or a too deep chain.
  List<_V> _evaluate(List<_V> all, _V target,
      {required Decimal? oldTargetValue, List<FieldChange>? collect}) {
    final deps = {for (final v in all) v.lower: namesIn(v.expr)};
    final cycle = findCycle(deps);
    if (cycle != null) {
      throw VariableException(400, 'Circular reference: ${formatCycle(cycle)}',
          {'code': 'cycle', 'field': 'expr', 'path': formatCycle(cycle)});
    }
    final deep = tooDeepVariable(deps);
    if (deep != null) {
      throw VariableException(
          400,
          'Too many variables in a chain (at most $maxVariableChain): '
          '\$$deep',
          {'code': 'too_deep', 'field': 'expr', 'variable': deep});
    }
    final byLower = {for (final v in all) v.lower: v};
    final lookup = _Lookup({for (final v in all) v.lower: v.vv});
    final dirty = <String>{};
    final changed = <_V>[];
    final spec = fieldSpecs['variable.value']!;
    for (final name in topoOrder(deps)) {
      final v = byLower[name]!;
      if (identical(v, target)) {
        final guard = guardFormulaText(v.expr);
        if (guard != null) throw FormulaFieldException('expr', guard);
        final r = resolveField(v.expr, spec, lookup);
        if (!r.ok) throw FormulaFieldException('expr', r.error!);
        if (r.value == null) {
          throw FormulaFieldException('expr',
              FormulaError(FormulaErrorCode.empty, 'Enter a value', 0, 0));
        }
        v.expr = r.isFormula ? r.canonicalText! : v.expr.trim();
        if (oldTargetValue == null || r.value != oldTargetValue) {
          dirty.add(name);
        }
        v.value = r.value!;
        v.problem = null;
        changed.add(v);
        collect?.add(FieldChange(
            entity: 'variable',
            entityId: v.id ?? '',
            field: FormulaField.value,
            expr: v.expr,
            oldValue: oldTargetValue?.toString(),
            newValue: v.value.toString()));
      } else if (deps[name]!.any(dirty.contains)) {
        final res = resolveStoredText(v.expr, spec, lookup);
        final old = v.value;
        final oldProblem = jsonEncode(v.problem);
        if (res.error != null) {
          v.problem = errorJson(res.error!);
        } else {
          v.value = res.value!;
          v.problem = null;
          if (v.value != old) dirty.add(name);
        }
        if (v.value != old || jsonEncode(v.problem) != oldProblem) {
          changed.add(v);
          collect?.add(FieldChange(
              entity: 'variable',
              entityId: v.id!,
              field: FormulaField.value,
              expr: v.expr,
              oldValue: old.toString(),
              newValue: v.value.toString(),
              error: v.problem));
        }
      } else {
        continue;
      }
      lookup.m[name] = v.vv;
    }
    service.setLookup(ownerId, lookup);
    return changed;
  }

  Future<Variable> create(VariableInput input) async {
    await _lock();
    final all = await _load();
    if (all.length >= maxVariablesPerOwner) {
      throw VariableException(400, 'At most $maxVariablesPerOwner variables',
          {'code': 'too_many_variables'});
    }
    final v = _V(null, input.name!, input.unit ?? 'number', input.expr!,
        Decimal.zero, null);
    _checkName(v.name, all, null);
    _evaluate([...all, v], v, oldTargetValue: null);
    final r = await _db.execute(
      Sql.named('''
        INSERT INTO variables (owner_id, name, unit, expr, value, description,
                               display_decimals, created_by, updated_by)
        VALUES (@o::uuid, @n, @u, @e, @val::numeric, @d, @dd, @a::uuid,
                @a::uuid)
        RETURNING id::text
      '''),
      parameters: {
        'o': ownerId,
        'n': v.name,
        'u': v.unit,
        'e': v.expr,
        'val': v.value.toString(),
        'd': input.description,
        'dd': input.displayDecimals,
        'a': actorId,
      },
    );
    final id = r.first[0] as String;
    await VariableRefIndex(_db).reindexVariable(id);
    return (await VariableRepo(_db).get(id))!;
  }

  /// PATCH: any of name, expr, unit, description, displayDecimals.
  Future<Variable> update(String id, VariableInput input,
      {List<FieldChange>? collect}) async {
    await _lock();
    final all = await _load();
    final target = all.where((v) => v.id == id).firstOrNull;
    if (target == null) {
      throw VariableException(404, 'variable not found');
    }
    final oldName = target.name, oldExpr = target.expr;
    final oldValue = target.value;
    if (input.name != null && input.name != target.name) {
      _checkName(input.name!, all, target);
      target.name = input.name!;
      // Dependents name it by its new name from now on (the DB texts are
      // rewritten by _rename).
      for (final v in all) {
        if (!identical(v, target)) {
          v.expr = renameVariable(v.expr, oldName, target.name);
        }
      }
    }
    if (input.unit != null) target.unit = input.unit!;
    if (input.expr != null) target.expr = input.expr!;
    final changed = input.expr != null || target.problem != null
        ? _evaluate(all, target, oldTargetValue: oldValue, collect: collect)
        : const <_V>[];

    await _db.execute(
      Sql.named('''
        UPDATE variables SET name = @n, unit = @u, expr = @e,
          value = @val::numeric,
          problem = @p::jsonb,
          description = CASE WHEN @sd THEN @d ELSE description END,
          display_decimals =
            CASE WHEN @sdd THEN @dd::smallint ELSE display_decimals END
        WHERE id = @id::uuid
      '''),
      parameters: {
        'id': id,
        'n': target.name,
        'u': target.unit,
        'e': target.expr,
        'val': target.value.toString(),
        'p': target.problem == null ? null : jsonEncode(target.problem),
        'sd': input.setDescription,
        'd': input.description,
        'sdd': input.setDisplayDecimals,
        'dd': input.displayDecimals,
      },
    );
    final dependents = [
      for (final v in changed)
        if (!identical(v, target)) v
    ];
    if (dependents.isNotEmpty) {
      await _db.execute(
        Sql.named('''
          UPDATE variables x SET value = v.val::numeric,
                 problem = NULLIF(v.p, '')::jsonb
          FROM unnest(@ids::text[], @vals::text[], @ps::text[])
               AS v(id, val, p)
          WHERE x.id = v.id::uuid
        '''),
        parameters: {
          'ids': [for (final v in dependents) v.id!],
          'vals': [for (final v in dependents) v.value.toString()],
          'ps': [
            for (final v in dependents)
              v.problem == null ? '' : jsonEncode(v.problem)
          ],
        },
      );
    }
    if (target.expr != oldExpr) {
      await VariableRefIndex(_db).reindexVariable(id);
    }
    if (target.name != oldName) {
      final streams = await _rename(id, oldName, target.name);
      await _record('variable.renamed', streams,
          {'variableId': id, 'from': oldName, 'to': target.name});
    }
    // Fan-out: the fields using a variable whose value changed.
    final valueChanged = [
      for (final v in changed)
        if (!identical(v, target) || v.value != oldValue) v.id!
    ];
    if (valueChanged.isNotEmpty) {
      final res = await _fanOut(valueChanged, collect);
      await _record('variable.values_changed', res.streams,
          {'variableIds': valueChanged, 'fields': res.fields});
    }
    return (await VariableRepo(_db).get(id))!;
  }

  Future<RefreshResult> _fanOut(
      List<String> variableIds, List<FieldChange>? collect) async {
    final refs = await _db.execute(
      Sql.named('''
        SELECT DISTINCT stream_id::text, event_id::text FROM variable_refs
        WHERE variable_id = ANY(@ids::text[]::uuid[]) AND stream_id IS NOT NULL
      '''),
      parameters: {'ids': variableIds},
    );
    final events = <String>{}, streams = <String>{};
    for (final r in refs) {
      if (r[1] != null) {
        events.add(r[1] as String);
      } else {
        streams.add(r[0] as String);
      }
    }
    final out = RefreshResult();
    out.add(await service.refreshEvents(events, collect: collect));
    out.add(await service.refreshStreams(streams, collect: collect));
    return out;
  }

  Future<void> _record(
      String action, Set<String> streams, Map<String, Object?> detail) async {
    if (!audit) return;
    final repo = AuditRepo(_db);
    for (final s in streams.toList()..sort()) {
      await repo.record(
          userId: actorId,
          action: action,
          streamId: s,
          entityId: detail['variableId'] as String?,
          detail: detail);
    }
  }

  /// Rewrites `$old` → `$new` in every text referencing variable [id]
  /// (by its refs) and in the owner's scenario exprs. Returns the streams
  /// whose rows changed.
  Future<Set<String>> _rename(String id, String oldName, String newName) async {
    String re(String t) => renameVariable(t, oldName, newName);
    final streams = <String>{};
    final refs = await _db.execute(
      Sql.named('''
        SELECT DISTINCT stream_id::text, event_id::text,
               from_variable_id::text
        FROM variable_refs WHERE variable_id = @id::uuid
      '''),
      parameters: {'id': id},
    );
    final eventIds = <String>{}, streamIds = <String>{}, varIds = <String>{};
    for (final r in refs) {
      if (r[2] != null) {
        varIds.add(r[2] as String);
      } else if (r[1] != null) {
        eventIds.add(r[1] as String);
      } else {
        streamIds.add(r[0] as String);
      }
    }

    if (eventIds.isNotEmpty) {
      final rows = await _db.execute(
        Sql.named('''
          SELECT id::text, stream_id::text, amount_expr, interval_expr,
                 count_expr,
                 CASE WHEN loan::text LIKE '%Expr%' THEN loan END
          FROM events
          WHERE id = ANY(@ids::text[]::uuid[])
             OR transfer_id IN (SELECT transfer_id FROM events
                                WHERE id = ANY(@ids::text[]::uuid[])
                                  AND transfer_id IS NOT NULL)
        '''),
        parameters: {'ids': eventIds.toList()},
      );
      final ids = <String>[], a = <String>[], iv = <String>[], c = <String>[];
      final l = <String>[];
      final pairIds = <String>[];
      for (final r in rows) {
        pairIds.add(r[0] as String);
        String? t(int i) => r[i] as String?;
        final na = t(2) == null ? null : re(t(2)!);
        final ni = t(3) == null ? null : re(t(3)!);
        final nc = t(4) == null ? null : re(t(4)!);
        final loan = r[5] == null
            ? null
            : Map<String, dynamic>.from(
                (r[5] is String ? jsonDecode(r[5] as String) : r[5]) as Map);
        final nl = loan == null ? null : _renameLoan(loan, re);
        if (na != t(2) || ni != t(3) || nc != t(4) || nl != null) {
          ids.add(r[0] as String);
          a.add(na ?? '');
          iv.add(ni ?? '');
          c.add(nc ?? '');
          l.add(nl == null ? '' : jsonEncode(nl));
          streams.add(r[1] as String);
        }
      }
      if (ids.isNotEmpty) {
        await _db.execute(
          Sql.named('''
            UPDATE events e SET amount_expr = NULLIF(v.a, ''),
              interval_expr = NULLIF(v.i, ''), count_expr = NULLIF(v.c, ''),
              loan = COALESCE(NULLIF(v.l, '')::jsonb, e.loan)
            FROM unnest(@ids::text[], @a::text[], @i::text[], @c::text[],
                        @l::text[]) AS v(id, a, i, c, l)
            WHERE e.id = v.id::uuid
          '''),
          parameters: {'ids': ids, 'a': a, 'i': iv, 'c': c, 'l': l},
        );
      }
      final ovs = await _db.execute(
        Sql.named('''
          SELECT o.event_id::text, o.date::text, o.amount_expr,
                 e.stream_id::text
          FROM occurrence_overrides o JOIN events e ON e.id = o.event_id
          WHERE o.event_id = ANY(@ids::text[]::uuid[])
            AND o.amount_expr IS NOT NULL
        '''),
        parameters: {'ids': pairIds},
      );
      final oi = <String>[], od = <String>[], ot = <String>[];
      for (final o in ovs) {
        final n = re(o[2] as String);
        if (n == o[2]) continue;
        oi.add(o[0] as String);
        od.add(o[1] as String);
        ot.add(n);
        streams.add(o[3] as String);
      }
      if (oi.isNotEmpty) {
        await _db.execute(
          Sql.named('''
            UPDATE occurrence_overrides o SET amount_expr = v.t
            FROM unnest(@ids::text[], @d::text[], @t::text[]) AS v(id, d, t)
            WHERE o.event_id = v.id::uuid AND o.date = v.d::date
          '''),
          parameters: {'ids': oi, 'd': od, 't': ot},
        );
        final only = oi.toSet().difference(ids.toSet()).toList();
        if (only.isNotEmpty) {
          await _db.execute(
            Sql.named('UPDATE events SET version = version + 1 '
                'WHERE id = ANY(@ids::text[]::uuid[])'),
            parameters: {'ids': only},
          );
        }
      }
    }

    if (streamIds.isNotEmpty) {
      final rows = await _db.execute(
        Sql.named('SELECT id::text, seed_balance_expr, loss_threshold_expr '
            'FROM streams WHERE id = ANY(@ids::text[]::uuid[])'),
        parameters: {'ids': streamIds.toList()},
      );
      for (final r in rows) {
        final s = r[1] as String?, t = r[2] as String?;
        final ns = s == null ? null : re(s), nt = t == null ? null : re(t);
        if (ns == s && nt == t) continue;
        await _db.execute(
          Sql.named('UPDATE streams SET seed_balance_expr = @s, '
              'loss_threshold_expr = @t WHERE id = @id::uuid'),
          parameters: {'id': r[0], 's': ns, 't': nt},
        );
        streams.add(r[0] as String);
      }
    }

    for (final v in varIds) {
      final r = await _db.execute(
        Sql.named('SELECT expr FROM variables WHERE id = @id::uuid'),
        parameters: {'id': v},
      );
      if (r.isEmpty) continue;
      final n = re(r.first[0] as String);
      if (n == r.first[0]) continue;
      await _db.execute(
        Sql.named('UPDATE variables SET expr = @e WHERE id = @id::uuid'),
        parameters: {'id': v, 'e': n},
      );
    }

    // Scenario goal exprs (no index; one owner's scenarios are few).
    final scenarios = await _db.execute(
      Sql.named('''
        SELECT sc.id::text, sc.stream_id::text, sc.request
        FROM scenarios sc JOIN streams s ON s.id = sc.stream_id
        WHERE s.owner_id = @o::uuid AND sc.request ? 'exprs'
      '''),
      parameters: {'o': ownerId},
    );
    for (final r in scenarios) {
      final req = Map<String, dynamic>.from(
          (r[2] is String ? jsonDecode(r[2] as String) : r[2]) as Map);
      final exprs = req['exprs'];
      if (exprs is! Map) continue;
      var any = false;
      final next = <String, Object?>{};
      for (final e in exprs.entries) {
        final v = e.value;
        if (v is String) {
          final n = re(v);
          any |= n != v;
          next[e.key.toString()] = n;
        } else {
          next[e.key.toString()] = v;
        }
      }
      if (!any) continue;
      req['exprs'] = next;
      await _db.execute(
        Sql.named('UPDATE scenarios SET request = @r::jsonb '
            'WHERE id = @id::uuid'),
        parameters: {'id': r[0], 'r': jsonEncode(req)},
      );
      streams.add(r[1] as String);
    }
    return streams;
  }

  /// The loan JSON with its expr keys renamed, or null when unchanged.
  static Map<String, dynamic>? _renameLoan(
      Map<String, dynamic> loan, String Function(String) re) {
    var any = false;
    final next = Map<String, dynamic>.from(loan);
    for (final k in const [
      'termYearsExpr',
      'termMonthsExpr',
      'chargeDayExpr'
    ]) {
      final v = next[k];
      if (v is String) {
        final n = re(v);
        any |= n != v;
        next[k] = n;
      }
    }
    final periods = next['ratePeriods'];
    if (periods is List) {
      next['ratePeriods'] = [
        for (final p in periods)
          if (p is Map && p['ratePctExpr'] is String)
            () {
              final n = re(p['ratePctExpr'] as String);
              any |= n != p['ratePctExpr'];
              return {...p, 'ratePctExpr': n};
            }()
          else
            p
      ];
    }
    return any ? next : null;
  }

  Future<void> delete(String id) async {
    await _lock();
    final v = await VariableRepo(_db).get(id);
    if (v == null || v.ownerId != ownerId) {
      throw VariableException(404, 'variable not found');
    }
    final r = await _db.execute(
      Sql.named('''
        SELECT count(*)::int, count(DISTINCT stream_id)::int
        FROM variable_refs WHERE variable_id = @id::uuid
      '''),
      parameters: {'id': id},
    );
    final fields = r.first[0] as int, streams = r.first[1] as int;
    if (fields > 0) {
      throw VariableException(
          409,
          '\$${v.name} is used by $fields '
          '${fields == 1 ? 'field' : 'fields'}',
          {'code': 'variable_in_use', 'fields': fields, 'streams': streams});
    }
    await _db.execute(
      Sql.named('DELETE FROM variables WHERE id = @id::uuid'),
      parameters: {'id': id},
    );
  }

  /// A PATCH dry run: what [input] would change, rolled back.
  Future<Map<String, Object?>> preview(String id, VariableInput input) async {
    final changes = <FieldChange>[];
    await _db.execute('SAVEPOINT variable_preview');
    try {
      await VariableManager(_db,
              ownerId: ownerId, actorId: actorId, audit: false)
          .update(id, input, collect: changes);
    } finally {
      await _db.execute('ROLLBACK TO SAVEPOINT variable_preview');
    }
    return {
      'changes': [for (final c in changes) c.toJson()],
      'invalid': changes.where((c) => c.error != null).length,
    };
  }
}
