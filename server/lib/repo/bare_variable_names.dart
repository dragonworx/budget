// Data migration 029: formulas reference variables by their bare name
// (`rent * 12`), no longer `$rent`. Rewrites every stored formula text and
// renames the variables whose names the new grammar can't reference (a
// leading `_`, or a reserved word). Idempotent: a text without `$name`
// and a valid name are left alone.
import 'dart:convert';

import 'package:budget_formula/budget_formula.dart';
import 'package:postgres/postgres.dart' hide Pool;

final RegExp _legacyRef = RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)');
final RegExp _glue = RegExp(r'[A-Za-z0-9_.)]');

/// [text] with each old-syntax `$name` written as the bare name (or its
/// new name from [renames], keyed lower-case). A space keeps the name
/// apart from a name, number or `)` right before it (`$a$b` → `a b`,
/// `2$x` → `2 x`). `$5` (currency) and a lone `$` are kept.
String legacyToBare(String text, [Map<String, String> renames = const {}]) {
  final b = StringBuffer();
  var i = 0;
  for (final m in _legacyRef.allMatches(text)) {
    b.write(text.substring(i, m.start));
    final name = m[1]!;
    final out = renames[name.toLowerCase()] ?? name;
    final s = b.toString();
    if (s.isNotEmpty && _glue.hasMatch(s[s.length - 1])) b.write(' ');
    b.write(out);
    i = m.end;
  }
  if (i == 0) return text;
  b.write(text.substring(i));
  return b.toString();
}

/// Whether [name] can be referenced by the bare-name grammar.
bool isBareName(String name) =>
    variableNamePattern.hasMatch(name) && !isReservedName(name);

/// A valid name for [old] not in [takenLower] (lower-case names already
/// used by the owner): `_tmp` → `v_tmp`, `round` → `round_var`, then
/// `_2`, `_3`… on a clash, cut to 40 characters.
String bareNameFor(String old, Set<String> takenLower) {
  var base = old.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (!RegExp(r'^[A-Za-z]').hasMatch(base)) base = 'v$base';
  if (isReservedName(base)) base = '${base}_var';
  String cut(String s, int n) => s.length > n ? s.substring(0, n) : s;
  base = cut(base, maxVariableNameLength);
  var name = base;
  for (var k = 2; takenLower.contains(name.toLowerCase()); k++) {
    final suffix = '_$k';
    name = cut(base, maxVariableNameLength - suffix.length) + suffix;
  }
  return name;
}

/// One rename the migration made (reported in the log).
class BareRename {
  final String ownerId, variableId, from, to;
  const BareRename(this.ownerId, this.variableId, this.from, this.to);
  @override
  String toString() => '$from → $to (variable $variableId)';
}

/// Counts of what changed, for the log and tests.
class BareMigrationReport {
  final renames = <BareRename>[];
  final rows = <String, int>{};
  void count(String table) => rows[table] = (rows[table] ?? 0) + 1;
  @override
  String toString() => 'renamed ${renames.length} $renames, rewrote $rows';
}

Object? _json(Object? v) => v is String ? jsonDecode(v) : v;

/// Rewrites strings in a JSON value: [keys] (null = every string).
Object? _deep(Object? v, String Function(String) re, {Set<String>? keys}) {
  if (v is Map) {
    return {
      for (final e in v.entries)
        e.key: (e.value is String &&
                (keys == null || keys.contains(e.key.toString())))
            ? re(e.value as String)
            : _deep(e.value, re, keys: keys),
    };
  }
  if (v is List) return [for (final x in v) _deep(x, re, keys: keys)];
  return v;
}

const _loanKeys = {
  'ratePctExpr',
  'termYearsExpr',
  'termMonthsExpr',
  'chargeDayExpr',
  'principalExpr',
};

/// The migration. Returns false (not recorded) when 028 hasn't run yet.
Future<bool> migrateBareVariableNames(Session s,
    {BareMigrationReport? report}) async {
  final r = report ?? BareMigrationReport();
  final has = await s.execute(
      "SELECT 1 FROM schema_migrations WHERE id = '028_variables.sql'");
  if (has.isEmpty) return false;

  // 1. Names the bare grammar can't reference.
  final vars = await s.execute('SELECT id::text, owner_id::text, name '
      'FROM variables ORDER BY owner_id, lower(name), id');
  final taken = <String, Set<String>>{};
  for (final v in vars) {
    taken
        .putIfAbsent(v[1] as String, () => {})
        .add((v[2] as String).toLowerCase());
  }
  final renames = <String, Map<String, String>>{}; // owner → lower → new
  await s.execute(
      'ALTER TABLE variables DROP CONSTRAINT IF EXISTS variables_name_check');
  for (final v in vars) {
    final id = v[0] as String, owner = v[1] as String, name = v[2] as String;
    if (isBareName(name)) continue;
    final t = taken[owner]!;
    final next = bareNameFor(name, t);
    t.add(next.toLowerCase());
    renames.putIfAbsent(owner, () => {})[name.toLowerCase()] = next;
    await s.execute(
        Sql.named('UPDATE variables SET name = @n WHERE id = @id::uuid'),
        parameters: {'id': id, 'n': next});
    r.renames.add(BareRename(owner, id, name, next));
  }
  await s.execute('ALTER TABLE variables ADD CONSTRAINT variables_name_check '
      r"CHECK (name ~ '^[A-Za-z][A-Za-z0-9_]{0,39}$')");

  String Function(String) reFor(String? owner) =>
      (t) => legacyToBare(t, renames[owner] ?? const {});
  String? txt(Object? v, String Function(String) re) =>
      v == null ? null : re(v as String);
  String? js(Object? v, String Function(String) re, {Set<String>? keys}) =>
      v == null ? null : jsonEncode(_deep(_json(v), re, keys: keys));
  String? same(Object? v) => v == null ? null : jsonEncode(_json(v));

  // 2. Variables' own formulas and problems.
  for (final v in await s.execute(
      'SELECT id::text, owner_id::text, expr, problem::text FROM variables '
      r"WHERE expr LIKE '%$%' OR problem::text LIKE '%$%'")) {
    final re = reFor(v[1] as String);
    final e = re(v[2] as String), p = js(v[3], re);
    if (e == v[2] && p == same(v[3])) continue;
    await s.execute(
        Sql.named('UPDATE variables SET expr = @e, problem = @p::jsonb '
            'WHERE id = @id::uuid'),
        parameters: {'id': v[0], 'e': e, 'p': p});
    r.count('variables');
  }

  // 3. Events: amount / interval / count, their errors, the loan's texts.
  for (final v in await s.execute(r'''
      SELECT e.id::text, s.owner_id::text, e.amount_expr, e.interval_expr,
             e.count_expr, e.expr_errors::text, e.loan::text
      FROM events e JOIN streams s ON s.id = e.stream_id
      WHERE e.amount_expr LIKE '%$%' OR e.interval_expr LIKE '%$%'
         OR e.count_expr LIKE '%$%' OR e.expr_errors::text LIKE '%$%'
         OR e.loan::text LIKE '%Expr%$%' ''')) {
    final re = reFor(v[1] as String);
    final loan = v[6] == null ? null : _json(v[6]);
    final a = txt(v[2], re), i = txt(v[3], re), c = txt(v[4], re);
    final x = js(v[5], re);
    final l =
        loan == null ? null : jsonEncode(_deep(loan, re, keys: _loanKeys));
    if (a == v[2] &&
        i == v[3] &&
        c == v[4] &&
        x == same(v[5]) &&
        l == same(v[6])) {
      continue;
    }
    await s.execute(
        Sql.named('UPDATE events SET amount_expr = @a, interval_expr = @i, '
            'count_expr = @c, expr_errors = @x::jsonb, loan = @l::jsonb '
            'WHERE id = @id::uuid'),
        parameters: {'id': v[0], 'a': a, 'i': i, 'c': c, 'x': x, 'l': l});
    r.count('events');
  }

  // 4. Occurrence overrides.
  for (final v in await s.execute(r'''
      SELECT o.event_id::text, o.date::text, s.owner_id::text, o.amount_expr,
             o.expr_error::text
      FROM occurrence_overrides o JOIN events e ON e.id = o.event_id
      JOIN streams s ON s.id = e.stream_id
      WHERE o.amount_expr LIKE '%$%' OR o.expr_error::text LIKE '%$%' ''')) {
    final re = reFor(v[2] as String);
    final a = txt(v[3], re), x = js(v[4], re);
    if (a == v[3] && x == same(v[4])) continue;
    await s.execute(
        Sql.named('UPDATE occurrence_overrides SET amount_expr = @a, '
            'expr_error = @x::jsonb '
            'WHERE event_id = @id::uuid AND date = @d::date'),
        parameters: {'id': v[0], 'd': v[1], 'a': a, 'x': x});
    r.count('occurrence_overrides');
  }

  // 5. Streams: seed and loss threshold.
  for (final v in await s.execute(r'''
      SELECT id::text, owner_id::text, seed_balance_expr, loss_threshold_expr,
             expr_errors::text
      FROM streams
      WHERE seed_balance_expr LIKE '%$%' OR loss_threshold_expr LIKE '%$%'
         OR expr_errors::text LIKE '%$%' ''')) {
    final re = reFor(v[1] as String);
    final a = txt(v[2], re), t = txt(v[3], re), x = js(v[4], re);
    if (a == v[2] && t == v[3] && x == same(v[4])) continue;
    await s.execute(
        Sql.named('UPDATE streams SET seed_balance_expr = @a, '
            'loss_threshold_expr = @t, expr_errors = @x::jsonb '
            'WHERE id = @id::uuid'),
        parameters: {'id': v[0], 'a': a, 't': t, 'x': x});
    r.count('streams');
  }

  // 6. Saved scenarios' goal formulas (request.exprs).
  for (final v in await s.execute(r'''
      SELECT sc.id::text, s.owner_id::text, sc.request::text
      FROM scenarios sc JOIN streams s ON s.id = sc.stream_id
      WHERE sc.request ? 'exprs' AND (sc.request->'exprs')::text LIKE '%$%'
      ''')) {
    final re = reFor(v[1] as String);
    final req = Map<String, dynamic>.from(_json(v[2]) as Map);
    final next = _deep(req['exprs'], re);
    if (jsonEncode(next) == jsonEncode(req['exprs'])) continue;
    req['exprs'] = next;
    await s.execute(
        Sql.named('UPDATE scenarios SET request = @r::jsonb '
            'WHERE id = @id::uuid'),
        parameters: {'id': v[0], 'r': jsonEncode(req)});
    r.count('scenarios');
  }
  // ignore: avoid_print
  print('029_bare_variable_names: $r');
  return true;
}
