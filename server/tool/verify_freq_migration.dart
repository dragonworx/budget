// Verifies migration 023 on a real database: records every event's
// occurrences from its legacy columns with the pre-023 generator over
// 1990–2100, applies pending migrations, then reads every event back
// through EventRepo (the structured rule) and compares the dates.
//
//   dart run tool/verify_freq_migration.dart postgres://user:pw@host/db
//
// Exit code 0 = identical for every event. Run it on a copy first.
import 'dart:io';

import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/engine/occurrence_gen.dart';
import 'package:budget_server/repo/event_repo.dart';

List<DateTime> legacyDates(List<Object?> r, DateTime from, DateTime to) {
  final s = r[1] as DateTime;
  final start = DateTime.utc(s.year, s.month, s.day);
  if (r[2] == 'once') {
    return start.isBefore(from) || start.isAfter(to) ? [] : [start];
  }
  final n = r[3] as int, unit = r[4] as String;
  final e = r[6] as DateTime?;
  final until = r[5] == 'until_date' && e != null
      ? DateTime.utc(e.year, e.month, e.day)
      : null;
  final count = r[5] == 'count' ? r[7] as int? : null;
  final out = <DateTime>[];
  for (var i = 0; i < 100000; i++) {
    if (count != null && i >= count) break;
    final k = n * i;
    final c = switch (unit) {
      'days' => DateTime.utc(start.year, start.month, start.day + k),
      'weeks' => DateTime.utc(start.year, start.month, start.day + 7 * k),
      'months' => addMonthsRolled(start, k),
      _ => addMonthsRolled(start, 12 * k),
    };
    if (until != null && c.isAfter(until)) break;
    if (c.isAfter(to)) break;
    if (!c.isBefore(from)) out.add(c);
  }
  return out;
}

Future<void> main(List<String> args) async {
  final conn =
      await openConnection(Config(databaseUrl: args.single, host: '', port: 0));
  final from = DateTime.utc(1990, 1, 1), to = DateTime.utc(2100, 12, 31);
  final rows = await conn
      .execute('SELECT id::text, start_date, recurrence_mode, interval, unit, '
          'end_mode, end_date, occurrence_count, stream_id::text, version '
          'FROM events ORDER BY id');
  final before = {
    for (final r in rows) r[0] as String: legacyDates(r.toList(), from, to),
  };
  final versions = {for (final r in rows) r[0] as String: r[9]};
  final streams = {for (final r in rows) r[8] as String};
  stdout.writeln('events: ${rows.length} in ${streams.length} streams');

  await applyMigrations(conn, migrationsDir: 'migrations');

  final repo = EventRepo(conn);
  var bad = 0, dates = 0, n = 0;
  final rules = <String, int>{};
  for (final s in streams) {
    for (final e in await repo.listByStream(s)) {
      n++;
      final after = OccurrenceGenerator.datesForEvent(e, from, to);
      dates += after.length;
      final key = '${e.frequency.rule.apiName}/${e.frequency.interval}';
      rules[key] = (rules[key] ?? 0) + 1;
      final exp = before[e.id]!;
      final same = after.length == exp.length &&
          [for (var i = 0; i < exp.length; i++) after[i] == exp[i]]
              .every((x) => x);
      if (!same) {
        bad++;
        stderr.writeln('MISMATCH ${e.id} ${e.name}: '
            '${exp.length} before vs ${after.length} after');
      }
      if (versions[e.id] != e.version) {
        bad++;
        stderr.writeln('VERSION CHANGED ${e.id}');
      }
    }
  }
  await conn.close();
  stdout.writeln('checked $n events, $dates occurrence dates '
      '(1990-01-01..2100-12-31); rules $rules; mismatches $bad');
  exitCode = bad == 0 && n == rows.length ? 0 : 1;
}
