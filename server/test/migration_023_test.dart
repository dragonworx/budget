// Migration 023 (structured frequency) is lossless: builds a scratch
// database at the 022 schema, fills it with events of every legacy cadence
// (days / weeks / months / years, N = 1…, once, never / until / count
// ends, odd month-end starts, a transfer pair), records each event's
// occurrences with the pre-023 generator over 1990–2100, applies 023 and
// checks the structured rule yields exactly the same dates, the legacy
// columns and versions are untouched, the compatibility trigger and the
// CHECK constraints behave. DB-backed (TEST_DATABASE_URL, default local
// budget_test); skipped without Postgres.
import 'dart:io';

import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/engine/occurrence_gen.dart';
import 'package:budget_server/repo/event_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig023_test';
const _owner = '00000000-0000-0000-0000-0000000023a1';
const _stream = '00000000-0000-0000-0000-0000000023b1';
const _stream2 = '00000000-0000-0000-0000-0000000023b2';

/// The pre-023 generator, verbatim in behaviour: start + k·N days / weeks /
/// months / years (months and years from the start's own day, rolled to
/// the month end), stopping at the end date or after the count.
List<DateTime> legacyDates(Map<String, Object?> e, DateTime from, DateTime to) {
  final s = e['start'] as DateTime;
  final start = DateTime.utc(s.year, s.month, s.day);
  if (e['mode'] == 'once') {
    return start.isBefore(from) || start.isAfter(to) ? [] : [start];
  }
  final n = e['interval'] as int;
  final unit = e['unit'] as String;
  final until = e['end'] as DateTime?;
  final count = e['count'] as int?;
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

void main() {
  Connection? admin;
  Connection? db;
  late Directory oldMigrations;
  final base = Uri.parse(Platform.environment['TEST_DATABASE_URL'] ??
      'postgres://budget:budget@127.0.0.1:5432/budget_test');

  setUpAll(() async {
    try {
      admin = await openConnection(
          Config(databaseUrl: base.toString(), host: '', port: 0));
      await admin!.execute('DROP DATABASE IF EXISTS $_scratch');
      await admin!.execute('CREATE DATABASE $_scratch');
      db = await openConnection(Config(
          databaseUrl: base.replace(path: '/$_scratch').toString(),
          host: '',
          port: 0));
    } catch (e) {
      // ignore: avoid_print
      print('migration_023_test: no test DB ($e)');
      admin = null;
      db = null;
      return;
    }
    oldMigrations = Directory.systemTemp.createTempSync('mig022');
    for (final f in Directory('migrations').listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.compareTo('023') < 0) f.copySync('${oldMigrations.path}/$name');
    }
  });

  tearDownAll(() async {
    await db?.close();
    if (admin != null) {
      await admin!.execute('DROP DATABASE IF EXISTS $_scratch');
      await admin!.close();
      oldMigrations.deleteSync(recursive: true);
    }
  });

  test('023 backfills a structured rule with identical occurrences', () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrations(c, migrationsDir: oldMigrations.path);
    await c
        .execute("INSERT INTO users (id, email) VALUES ('$_owner', 'm@x.io')");
    for (final s in [_stream, _stream2]) {
      await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
          "owner_id) VALUES ('$s', 'S$s', 0, '2026-01-01', '$_owner')");
    }

    // Every legacy cadence × odd starts × each end kind.
    final rows = <Map<String, Object?>>[];
    final starts = [
      DateTime.utc(2024, 1, 31),
      DateTime.utc(2024, 2, 29),
      DateTime.utc(2025, 8, 30),
      DateTime.utc(2026, 10, 8),
      DateTime.utc(2026, 12, 31),
    ];
    for (final start in starts) {
      rows.add({'mode': 'once', 'start': start});
      for (final unit in ['days', 'weeks', 'months', 'years']) {
        for (final n in [1, 2, 3, 12]) {
          for (final end in ['never', 'until_date', 'count']) {
            rows.add({
              'mode': 'every',
              'interval': n,
              'unit': unit,
              'start': start,
              'endMode': end,
              'end': end == 'until_date' ? DateTime.utc(2031, 2, 28) : null,
              'count': end == 'count' ? 7 : null,
            });
          }
        }
      }
    }
    var i = 0;
    final ids = <String>[];
    for (final r in rows) {
      final id = '00000000-0000-0000-0000-${(++i).toString().padLeft(12, '0')}';
      ids.add(id);
      r['id'] = id;
      await c.execute(
        Sql.named('INSERT INTO events (id, stream_id, name, direction, amount, '
            'start_date, recurrence_mode, interval, unit, end_mode, end_date, '
            'occurrence_count) VALUES (@id::uuid, @s::uuid, @n, @d, 10, @st, '
            '@m, @iv, @u, @em, @ed, @c)'),
        parameters: {
          'id': id,
          's': _stream,
          'n': 'E$i',
          'd': i.isEven ? 'credit' : 'debit',
          'st': r['start'],
          'm': r['mode'],
          'iv': r['interval'],
          'u': r['unit'],
          'em': r['endMode'] ?? 'never',
          'ed': r['end'],
          'c': r['count'],
        },
      );
    }
    // A transfer pair (fortnightly) across the two streams.
    const tid = '00000000-0000-0000-0000-0000000023c1';
    for (final (id, s, d) in [
      ('00000000-0000-0000-0000-0000000023d1', _stream, 'debit'),
      ('00000000-0000-0000-0000-0000000023d2', _stream2, 'credit'),
    ]) {
      final r = {
        'id': id,
        'mode': 'every',
        'interval': 2,
        'unit': 'weeks',
        'start': DateTime.utc(2026, 10, 9),
      };
      rows.add(r);
      await c.execute(
        Sql.named("INSERT INTO events (id, stream_id, name, direction, amount, "
            "start_date, recurrence_mode, interval, unit, end_mode, "
            "transfer_id) VALUES (@id::uuid, @s::uuid, 'Save', @d, 50, "
            "'2026-10-09', 'every', 2, 'weeks', 'never', @t::uuid)"),
        parameters: {'id': id, 's': s, 'd': d, 't': tid},
      );
    }

    final from = DateTime.utc(1990, 1, 1), to = DateTime.utc(2100, 12, 31);
    final before = {
      for (final r in rows) r['id'] as String: legacyDates(r, from, to),
    };
    final legacyBefore = await c
        .execute('SELECT id::text, recurrence_mode, interval, unit, version '
            'FROM events ORDER BY id');

    await applyMigrations(c, migrationsDir: 'migrations');

    // Same legacy columns, same versions (the backfill is not an edit).
    final legacyAfter = await c
        .execute('SELECT id::text, recurrence_mode, interval, unit, version '
            'FROM events ORDER BY id');
    expect([for (final r in legacyAfter) r.toList()],
        [for (final r in legacyBefore) r.toList()]);

    final repo = EventRepo(c);
    final events = [
      ...await repo.listByStream(_stream),
      ...await repo.listByStream(_stream2),
    ];
    expect(events.length, rows.length);
    var dates = 0;
    for (final e in events) {
      final after = OccurrenceGenerator.datesForEvent(e, from, to);
      expect(after, before[e.id], reason: '${e.name} ${e.frequency.toJson()}');
      dates += after.length;
    }
    expect(dates, greaterThan(100000));

    // Rules as stored.
    Future<List<Object?>> freq(String id) async => (await c.execute(
            Sql.named('SELECT freq_rule, freq_interval, freq_days '
                'FROM events WHERE id = @id::uuid'),
            parameters: {'id': id}))
        .first
        .toList();
    final byKey = {
      for (final r in rows)
        '${r['mode']}|${r['interval']}|${r['unit']}': r['id'] as String,
    };
    expect(await freq(byKey['once|null|null']!), ['once', 1, <int>[]]);
    expect(await freq(byKey['every|1|days']!), ['daily', 1, <int>[]]);
    expect(await freq(byKey['every|3|days']!), ['daily', 3, <int>[]]);
    expect(await freq(byKey['every|1|weeks']!), ['weekly', 1, <int>[]]);
    expect(await freq(byKey['every|2|weeks']!), ['every_n_weeks', 2, <int>[]]);
    expect(await freq(byKey['every|1|months']!), ['monthly', 1, <int>[]]);
    expect(
        await freq(byKey['every|3|months']!), ['every_n_months', 3, <int>[]]);
    expect(
        await freq(byKey['every|2|years']!), ['every_n_months', 24, <int>[]]);
    // Both transfer rows carry the same rule.
    expect(await freq('00000000-0000-0000-0000-0000000023d1'),
        await freq('00000000-0000-0000-0000-0000000023d2'));
    expect(await freq('00000000-0000-0000-0000-0000000023d2'),
        ['every_n_weeks', 2, <int>[]]);

    // An older server writing only the legacy columns still gets a rule.
    const old = '00000000-0000-0000-0000-0000000023e1';
    await c.execute("INSERT INTO events (id, stream_id, name, direction, "
        "amount, start_date, recurrence_mode, interval, unit, end_mode) "
        "VALUES ('$old', '$_stream', 'Old', 'debit', 1, '2026-10-08', "
        "'every', 1, 'weeks', 'never')");
    expect(await freq(old), ['weekly', 1, <int>[]]);
    await c.execute("UPDATE events SET freq_days = '{1,2}' WHERE id = '$old'");
    // A legacy-only cadence change re-derives the rule; days of another
    // family go.
    await c.execute("UPDATE events SET interval = 1, unit = 'months' "
        "WHERE id = '$old'");
    expect(await freq(old), ['monthly', 1, <int>[]]);
    // A legacy edit that keeps the cadence keeps the days.
    await c.execute("UPDATE events SET freq_rule = 'weekly', freq_days = "
        "'{1,2}', unit = 'weeks' WHERE id = '$old'");
    await c.execute("UPDATE events SET name = 'Old 2' WHERE id = '$old'");
    expect(await freq(old), [
      'weekly',
      1,
      [1, 2]
    ]);
    // Same family, other N (legacy write): keeps the days.
    await c.execute("UPDATE events SET interval = 2 WHERE id = '$old'");
    expect(await freq(old), [
      'every_n_weeks',
      2,
      [1, 2]
    ]);

    // CHECK constraints.
    Future<void> rejects(String set) => expectLater(
        c.execute("UPDATE events SET $set WHERE id = '$old'"),
        throwsA(isA<ServerException>()));
    await rejects("freq_rule = 'hourly'");
    await rejects("freq_rule = 'weekly', freq_interval = 2");
    await rejects("freq_rule = 'every_n_weeks', freq_interval = 1");
    await rejects("freq_rule = 'weekly', freq_interval = 1, freq_days = '{8}'");
    await rejects("freq_rule = 'weekly', freq_interval = 1, freq_days = '{0}'");
    await rejects(
        "freq_rule = 'monthly', freq_interval = 1, freq_days = '{32}'");
    await rejects("freq_rule = 'daily', freq_interval = 1, freq_days = '{1}'");
    await rejects("freq_rule = 'once', freq_interval = 1, freq_days = '{1}'");
    await rejects("freq_rule = 'monthly', freq_interval = 1, "
        "freq_days = '{1,NULL}'");

    // The new server writes rule + days and keeps the legacy view in step.
    final made = await repo.create(
      streamId: _stream,
      name: 'Mon Tue',
      direction: Direction.debit,
      amount: Decimal.one,
      startDate: DateTime.utc(2026, 10, 8),
      recurrenceMode: RecurrenceMode.every,
      interval: 2,
      unit: RecurrenceUnit.years,
      endMode: EndMode.never,
    );
    expect(made.frequency, Frequency(FreqRule.everyNMonths, interval: 24));
    expect(made.unit, RecurrenceUnit.months);
    final weekly = await repo.create(
      streamId: _stream,
      name: 'W',
      direction: Direction.debit,
      amount: Decimal.one,
      startDate: DateTime.utc(2026, 10, 8),
      recurrenceMode: RecurrenceMode.every,
      interval: 1,
      unit: RecurrenceUnit.weeks,
      days: [2, 1, 2],
      endMode: EndMode.never,
    );
    expect(await freq(weekly.id), [
      'weekly',
      1,
      [1, 2]
    ]);
    final legacy =
        (await c.execute("SELECT recurrence_mode, interval, unit FROM events "
                "WHERE id = '${weekly.id}'"))
            .first
            .toList();
    expect(legacy, ['every', 1, 'weeks']);
    // An edit to another family without days drops them.
    final monthly = await repo.update(weekly.id, unit: RecurrenceUnit.months);
    expect(monthly!.frequency, Frequency(FreqRule.monthly));
  });
}
