import 'dart:convert';

import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';

/// Most variables one owner may have (D4).
const maxVariablesPerOwner = 500;

/// An owner's named value (spec 010, migration 028).
class Variable {
  Variable({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.unit,
    required this.expr,
    required this.value,
    this.description,
    this.displayDecimals,
    this.problem,
    this.version = 1,
    this.usageCount = 0,
  });

  final String id;
  final String ownerId;

  /// Canonical case, without `$`.
  final String name;

  /// money, percent or number.
  final String unit;

  /// The value as written (a number or a formula over other variables).
  final String expr;
  final Decimal value;
  final String? description;
  final int? displayDecimals;

  /// {code, message} when [expr] no longer resolves (the last value is
  /// kept, D8).
  final Map<String, dynamic>? problem;
  final int version;

  /// Fields and variables referencing this one.
  final int usageCount;

  VariableValue get lookupValue => VariableValue(
      name,
      value,
      switch (unit) {
        'money' => VariableUnit.money,
        'percent' => VariableUnit.percent,
        _ => VariableUnit.number,
      });

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'unit': unit,
        'expr': expr,
        'value': value.toString(),
        'description': description,
        'displayDecimals': displayDecimals,
        'problem': problem,
        'version': version,
        'usageCount': usageCount,
      };
}

class VariableRepo {
  VariableRepo(this._db);
  final Session _db;

  static const _cols = '''
    v.id::text, v.owner_id::text, v.name, v.unit, v.expr, v.value::text,
    v.description, v.display_decimals, v.problem, v.version,
    (SELECT count(*) FROM variable_refs r WHERE r.variable_id = v.id)::int''';

  /// [ownerId]'s variables in name order (natural, case-insensitive).
  Future<List<Variable>> list(String ownerId) async {
    final rows = await _db.execute(
      Sql.named('SELECT $_cols FROM variables v WHERE v.owner_id = @o::uuid'),
      parameters: {'o': ownerId},
    );
    return rows.map(_fromRow).toList()
      ..sort((a, b) => compareNames(a.name, b.name));
  }

  Future<Variable?> get(String id) async {
    final rows = await _db.execute(
      Sql.named('SELECT $_cols FROM variables v WHERE v.id = @id::uuid'),
      parameters: {'id': id},
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// The lookup formulas of [ownerId]'s rows resolve against.
  Future<MapVariableLookup> lookup(String ownerId) async => _lookup(
        await _db.execute(
          Sql.named('SELECT name, value::text, unit FROM variables '
              'WHERE owner_id = @o::uuid'),
          parameters: {'o': ownerId},
        ),
      );

  /// The variables of [preferStreamId]'s owner, else [streamId]'s (one
  /// round trip; D10's resolving owner for event writes).
  Future<MapVariableLookup> lookupForStream(String streamId,
          {String? preferStreamId}) async =>
      _lookup(
        await _db.execute(
          Sql.named('''
            SELECT name, value::text, unit FROM variables
            WHERE owner_id = COALESCE(
              (SELECT owner_id FROM streams WHERE id = @p::uuid),
              (SELECT owner_id FROM streams WHERE id = @s::uuid))
          '''),
          parameters: {'p': preferStreamId, 's': streamId},
        ),
      );

  MapVariableLookup _lookup(Result rows) {
    return MapVariableLookup([
      for (final r in rows)
        VariableValue(
            r[0] as String,
            Decimal.parse(r[1] as String),
            switch (r[2]) {
              'money' => VariableUnit.money,
              'percent' => VariableUnit.percent,
              _ => VariableUnit.number,
            }),
    ]);
  }

  Future<int> count(String ownerId) async => (await _db.execute(
        Sql.named(
            'SELECT count(*)::int FROM variables WHERE owner_id = @o::uuid'),
        parameters: {'o': ownerId},
      ))
          .first[0] as int;

  static Variable _fromRow(ResultRow r) => Variable(
        id: r[0] as String,
        ownerId: r[1] as String,
        name: r[2] as String,
        unit: r[3] as String,
        expr: r[4] as String,
        value: Decimal.parse(r[5] as String),
        description: r[6] as String?,
        displayDecimals: r[7] as int?,
        problem: r[8] == null
            ? null
            : Map<String, dynamic>.from(
                (r[8] is String ? jsonDecode(r[8] as String) : r[8]) as Map),
        version: r[9] as int,
        usageCount: r[10] as int,
      );
}
