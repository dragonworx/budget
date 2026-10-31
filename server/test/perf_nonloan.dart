// The non-loan /balance benchmark of spec 002 (a 7-event 20-year stream),
// shared by perf_loan_test.dart. Uses only pre-loan APIs so the same file
// times the baseline commit too.
import 'dart:convert';

import 'package:budget_server/auth/middleware.dart';
import 'package:budget_server/repo/stream_repo.dart';
import 'package:budget_server/repo/user_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:shelf/shelf.dart';

/// p95 in milliseconds of [runs] timed calls of [f] (after one warm-up).
Future<int> p95(int runs, Future<void> Function() f) async {
  await f();
  final ms = <int>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    await f();
    ms.add(sw.elapsedMilliseconds);
  }
  ms.sort();
  return ms[((runs * 95 + 99) ~/ 100) - 1];
}

/// Creates the 7-event stream under [owner] and returns the /balance p95
/// over 20 runs of a 20-year window.
Future<int> nonLoanBalanceP95(
    Session c, String owner, User user, Handler h) async {
  Future<Response> req(String method, String path, [Object? body]) async =>
      h(Request(method, Uri.parse('http://x$path'),
          context: {'auth': AuthContext(user, 't')},
          body: body == null ? null : jsonEncode(body)));
  final s = (await StreamRepo(c).create(
          ownerId: owner,
          name: 'Bench',
          seedBalance: Decimal.fromInt(2000),
          seedDate: DateTime.utc(2027, 1, 1),
          lossThreshold: Decimal.zero))
      .id;
  final bodies = [
    ('Salary', 'credit', '3200', 'every', 2, 'weeks'),
    ('Rent', 'debit', '2400', 'every', 1, 'months'),
    ('Groceries', 'debit', '180', 'every', 1, 'weeks'),
    ('Power', 'debit', '320', 'every', 3, 'months'),
    ('Phone', 'debit', '65', 'every', 1, 'months'),
    ('Coffee', 'debit', '5', 'every', 1, 'days'),
    ('Bonus', 'credit', '1500', 'once', null, null),
  ];
  for (final (name, dir, amt, mode, n, unit) in bodies) {
    final r = await req('POST', '/$s/events', {
      'name': name,
      'direction': dir,
      'amount': amt,
      'startDate': '2027-01-05',
      'recurrenceMode': mode,
      if (n != null) 'interval': n,
      if (unit != null) 'unit': unit,
    });
    if (r.statusCode != 201) throw StateError(await r.readAsString());
  }
  return p95(20, () async {
    final r = await req('GET', '/$s/balance?from=2027-01-01&to=2046-12-31');
    if (r.statusCode != 200) throw StateError('balance ${r.statusCode}');
    await r.readAsString();
  });
}
