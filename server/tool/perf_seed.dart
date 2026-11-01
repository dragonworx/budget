// Synthetic perf streams for the timeline perf harness (spec 005 R2).
//
//   DATABASE_URL=postgres://budget:budget@127.0.0.1:5432/budget_perf \
//     dart run tool/perf_seed.dart --seed-date=2026-11-01 \
//       [--sizes=5k,50k,200k,1M] [--owner=perf@example.com] [--seed=1]
//
// Refuses to run unless the database name ends in `_perf` or is
// `budget_test`: never point it at the dev or QA database. Deterministic:
// the same arguments always write the same streams (re-running replaces
// the owner's PERF streams). Creates, 35 years (+2) from the seed date:
//   * PERF 5k / 50k / 200k / 1M: daily, weekly, fortnightly and monthly
//     events in credit/debit pairs (so the balance oscillates), ~2% of
//     occurrences skipped, the alert threshold at the median close (crossed
//     many times);
//   * PERF Loan with PERF Offset as its offset stream (monthly repayments
//     transferred in from the offset stream);
//   * PERF Combined A / B / C: a set of three streams for the combined
//     view, with a monthly transfer from A to B.
// client/test/support/synthetic_series.dart builds the same shapes in
// memory (same generator, same pairs and skips).
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/events.dart';
import 'package:budget_server/api/streams.dart';
import 'package:budget_server/auth/middleware.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/repo/user_repo.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:shelf/shelf.dart';

/// Small seeded LCG, identical to the client's SynthRandom.
class PerfRandom {
  PerfRandom(int seed) : _s = seed & 0x7fffffff;
  int _s;
  int next(int max) {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s % max;
  }
}

enum PerfCadence { daily, weekly, fortnightly, monthly }

typedef PerfMix = ({int daily, int weekly, int fortnightly, int monthly});

/// Event mixes by stream (even counts: events come in pairs). At 35 years
/// these give about 6.3k / 54k / 215k / 993k occurrences.
const Map<String, PerfMix> perfMixes = {
  'PERF 5k': (daily: 0, weekly: 2, fortnightly: 2, monthly: 2),
  'PERF 50k': (daily: 2, weekly: 8, fortnightly: 6, monthly: 20),
  'PERF 200k': (daily: 12, weekly: 20, fortnightly: 10, monthly: 40),
  'PERF 1M': (daily: 70, weekly: 30, fortnightly: 20, monthly: 60),
};

/// Days generated from the seed: 35 years plus two (the widest view and
/// its margins).
const perfDays = 12785 + 730;

const _labels = [
  'Salary',
  'Rent',
  'Groceries',
  'Coffee',
  'Power bill',
  'Phone plan',
  'Car rego',
  'Insurance',
  'Gym',
  'Streaming',
  'Dividends',
  'Side gig',
];

class PerfEventPlan {
  PerfEventPlan(this.name, this.credit, this.cents, this.start, this.cadence);
  final String name;
  final bool credit;
  final int cents;
  final DateTime start;
  final PerfCadence cadence;
  final skips = <DateTime>[];

  Map<String, Object?> body() => {
        'name': name,
        'direction': credit ? 'credit' : 'debit',
        'amount': _money(cents),
        'startDate': _ymd(start),
        'recurrenceMode': 'every',
        'interval': cadence == PerfCadence.fortnightly ? 2 : 1,
        'unit': switch (cadence) {
          PerfCadence.daily => 'days',
          PerfCadence.weekly || PerfCadence.fortnightly => 'weeks',
          PerfCadence.monthly => 'months',
        },
        if (skips.isNotEmpty) 'skippedDates': [for (final d in skips) _ymd(d)],
      };
}

class PerfStreamPlan {
  PerfStreamPlan(
    this.name,
    this.seedDate,
    this.seedCents,
    this.thresholdCents,
    this.events,
    this.occurrences,
  );
  final String name;
  final DateTime seedDate;
  final int seedCents;
  final int thresholdCents;
  final List<PerfEventPlan> events;
  final int occurrences;
}

DateTime _day(DateTime d, int offset) =>
    DateTime.utc(d.year, d.month, d.day + offset);
String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';
String _money(int cents) =>
    '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';

/// The paired-event stream of [mix] (client: syntheticStream).
PerfStreamPlan planStream(
  String name,
  DateTime seedDate,
  PerfMix mix, {
  int days = perfDays,
  int seed = 1,
  int seedCents = 500000,
}) {
  final rnd = PerfRandom(seed);
  final cadences = [
    for (var i = 0; i < mix.daily; i++) PerfCadence.daily,
    for (var i = 0; i < mix.weekly; i++) PerfCadence.weekly,
    for (var i = 0; i < mix.fortnightly; i++) PerfCadence.fortnightly,
    for (var i = 0; i < mix.monthly; i++) PerfCadence.monthly,
  ];
  final events = <PerfEventPlan>[];
  final offsets = <int>[];
  var cents = 0, base = 0, gap = 0;
  for (final (i, c) in cadences.indexed) {
    final credit = i.isEven;
    if (credit) {
      cents = switch (c) {
        PerfCadence.daily => 300 + rnd.next(1500),
        PerfCadence.weekly => 2000 + rnd.next(20000),
        PerfCadence.fortnightly => 50000 + rnd.next(150000),
        PerfCadence.monthly => 5000 + rnd.next(200000),
      };
      base = rnd.next(24);
      gap = 1 + rnd.next(4);
    }
    final spendFirst = (i ~/ 2).isOdd;
    final startOffset = base + (credit == spendFirst ? gap : 0);
    final label = _labels[(i ~/ 2) % _labels.length];
    events.add(
      PerfEventPlan(
        '$label ${i ~/ 2 + 1}${credit ? '' : ' out'}',
        credit,
        cents,
        _day(seedDate, startOffset),
        c,
      ),
    );
    offsets.add(startOffset);
  }
  var bal = seedCents, count = 0;
  final closes = <int>[];
  for (var d = 0; d < days; d++) {
    final date = _day(seedDate, d);
    for (final (k, e) in events.indexed) {
      final since = d - offsets[k];
      if (since < 0) continue;
      final occurs = switch (e.cadence) {
        PerfCadence.daily => true,
        PerfCadence.weekly => since % 7 == 0,
        PerfCadence.fortnightly => since % 14 == 0,
        PerfCadence.monthly => date.day == e.start.day,
      };
      if (!occurs) continue;
      count++;
      if (rnd.next(50) == 0) {
        e.skips.add(date);
      } else {
        bal += e.credit ? e.cents : -e.cents;
      }
    }
    closes.add(bal);
  }
  closes.sort();
  return PerfStreamPlan(
    name,
    seedDate,
    seedCents,
    closes[closes.length ~/ 2],
    events,
    count,
  );
}

/// Whether [databaseUrl] names a database perf_seed may write to.
bool perfDbAllowed(String databaseUrl) {
  final uri = Uri.tryParse(databaseUrl);
  if (uri == null) return false;
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.length != 1) return false;
  final db = segs.single;
  return db.endsWith('_perf') || db == 'budget_test';
}

/// Writes the PERF streams for [user] (replacing any PERF streams they
/// own) through the API handlers; returns stream ids by name.
Future<Map<String, String>> seedPerf(
  Session c,
  User user, {
  required DateTime seedDate,
  Iterable<String> sizes = const ['5k', '50k', '200k', '1M'],
  int seed = 1,
  bool loan = true,
  bool combined = true,
  void Function(String line)? log,
}) async {
  final streams = buildStreamsApi(c).call;
  final events = eventsRouter(c).call;
  Future<Map<String, dynamic>> call(
    Handler h,
    String method,
    String path, [
    Object? body,
  ]) async {
    final r = await h(
      Request(
        method,
        Uri.parse('http://x$path'),
        context: {'auth': AuthContext(user, 't')},
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final text = await r.readAsString();
    if (r.statusCode >= 300) {
      throw StateError('$method $path -> ${r.statusCode}: $text');
    }
    return text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>;
  }

  await c.execute(
    Sql.named(
      "DELETE FROM streams WHERE owner_id = @o::uuid AND name LIKE 'PERF %'",
    ),
    parameters: {'o': user.id},
  );
  final ids = <String, String>{};
  Future<String> create(
    String name,
    DateTime seedDate,
    int seedCents,
    int thresholdCents,
  ) async {
    final s = await call(streams, 'POST', '/', {
      'name': name,
      'seedBalance': _money(seedCents),
      'seedDate': _ymd(seedDate),
      'lossThreshold': _money(thresholdCents),
    });
    return ids[name] = s['id'] as String;
  }

  Future<String> write(PerfStreamPlan p) async {
    final id = await create(p.name, p.seedDate, p.seedCents, p.thresholdCents);
    for (final e in p.events) {
      await call(streams, 'POST', '/$id/events', e.body());
    }
    log?.call(
      '${p.name}: ${p.events.length} events, ~${p.occurrences} occurrences, '
      '${p.events.fold(0, (n, e) => n + e.skips.length)} skips',
    );
    return id;
  }

  for (final (i, size) in sizes.indexed) {
    final name = 'PERF $size';
    final mix = perfMixes[name];
    if (mix == null) throw ArgumentError('unknown size $size');
    await write(planStream(name, seedDate, mix, seed: seed + i));
  }

  if (loan) {
    final start = _day(seedDate, 15);
    final loanId = await create('PERF Loan', seedDate, 0, 0);
    final offsetId = await create('PERF Offset', seedDate, 3000000, 0);
    final created = await call(streams, 'POST', '/$loanId/events', {
      'name': 'Home loan',
      'kind': 'loan',
      'amount': '450000',
      'startDate': _ymd(start),
      'loan': {
        'v': 1,
        'mode': 'advanced',
        'interestType': 'reducing',
        'termMonths': 360,
        'repaymentFrequency': 'monthly',
        'chargeSchedule': 'monthly',
        'chargeDay': 'anniversary',
        'dayCount': '365',
        'ratePeriods': [
          {
            'from': _ymd(start),
            'ratePct': '6.1',
            'type': 'variable',
            'interestOnly': false,
            'offsetApplies': true,
          },
        ],
      },
    });
    await call(streams, 'POST', '/$offsetId/events', {
      'name': 'Salary',
      'direction': 'credit',
      'amount': '4200',
      'startDate': _ymd(_day(seedDate, 13)),
      'recurrenceMode': 'every',
      'interval': 2,
      'unit': 'weeks',
    });
    await call(streams, 'POST', '/$offsetId/events', {
      'name': 'Repayment',
      'direction': 'debit',
      'amount': '3200',
      'startDate': _ymd(_day(start, 30)),
      'recurrenceMode': 'every',
      'interval': 1,
      'unit': 'months',
      'transferToStreamId': loanId,
    });
    await call(events, 'PATCH', '/${created['id']}', {
      'version': created['version'],
      'offsetStreamIds': [offsetId],
    });
    log?.call('PERF Loan: loan + monthly repayment from PERF Offset');
  }

  if (combined) {
    final parts = [
      planStream(
        'PERF Combined A',
        seedDate,
        (daily: 0, weekly: 2, fortnightly: 0, monthly: 2),
        seed: 11,
      ),
      planStream(
        'PERF Combined B',
        _day(seedDate, -40),
        (daily: 0, weekly: 0, fortnightly: 2, monthly: 2),
        days: perfDays + 40,
        seed: 22,
        seedCents: 1500000,
      ),
      planStream(
        'PERF Combined C',
        _day(seedDate, 20),
        (daily: 0, weekly: 2, fortnightly: 0, monthly: 2),
        days: perfDays - 20,
        seed: 33,
        seedCents: 250000,
      ),
    ];
    final written = [for (final p in parts) await write(p)];
    await call(streams, 'POST', '/${written[0]}/events', {
      'name': 'To savings',
      'direction': 'debit',
      'amount': '400',
      'startDate': _ymd(_day(seedDate, 3)),
      'recurrenceMode': 'every',
      'interval': 1,
      'unit': 'months',
      'transferToStreamId': written[1],
    });
  }
  return ids;
}

Future<void> main(List<String> args) async {
  String? arg(String name) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return null;
  }

  final url = Platform.environment['DATABASE_URL'] ?? '';
  if (!perfDbAllowed(url)) {
    stderr.writeln(
      'perf_seed: refusing: DATABASE_URL must name a database ending in '
      '_perf (or budget_test). Never run this against dev or QA.',
    );
    exitCode = 64;
    return;
  }
  final seedArg = arg('seed-date');
  if (seedArg == null) {
    stderr.writeln('perf_seed: --seed-date=YYYY-MM-DD is required');
    exitCode = 64;
    return;
  }
  final p = seedArg.split('-').map(int.parse).toList();
  final seedDate = DateTime.utc(p[0], p[1], p[2]);
  final sizes = (arg('sizes') ?? '5k,50k,200k,1M').split(',');
  final email = arg('owner') ?? 'perf@example.com';
  final conn = await openConnection(
    Config(databaseUrl: url, host: '', port: 0),
  );
  try {
    await applyMigrations(conn, migrationsDir: 'migrations');
    final user = await UserRepo(conn).ensure(email, isAdmin: false);
    final ids = await seedPerf(
      conn,
      user,
      seedDate: seedDate,
      sizes: sizes,
      seed: int.parse(arg('seed') ?? '1'),
      log: stdout.writeln,
    );
    stdout.writeln('perf_seed: ${ids.length} streams for $email');
  } finally {
    await conn.close();
  }
}
