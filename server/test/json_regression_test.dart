// DB-backed (TEST_DATABASE_URL, default local budget_test). Every
// response of a fixture built through the API (streams, plain / repeating
// / counted events, a transfer, a loan, overrides, skips, a split,
// scenarios) must stay byte-identical (after replacing ids and
// timestamps) when no formula is involved: spec 010's regression goldens,
// recorded on the code before variables existed.
//
// Regenerate (only when a change is meant to alter this output):
//   UPDATE_GOLDENS=1 dart test test/json_regression_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'authz/harness.dart';

const _golden = 'test/goldens/json_regression/fixture.json';

/// Ids become `id1`, `id2`, … in order of first appearance; ISO
/// timestamps become `<ts>`.
class _Normaliser {
  final _ids = <String, String>{};
  static final _uuid = RegExp(
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');
  static final _ts = RegExp(r'^\d{4}-\d\d-\d\dT[0-9:.]+(Z|[+-]\d\d:?\d\d)?$');

  Object? norm(Object? v) {
    if (v is Map) {
      return {for (final e in v.entries) e.key as String: norm(e.value)};
    }
    if (v is List) return [for (final x in v) norm(x)];
    if (v is String) {
      if (_ts.hasMatch(v)) return '<ts>';
      return v.replaceAllMapped(
          _uuid,
          (m) => _ids.putIfAbsent(
              m[0]!.toLowerCase(), () => 'id${_ids.length + 1}'));
    }
    return v;
  }
}

void main() {
  final h = Harness('jsonreg.test');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  test('stream / event / scenario JSON is unchanged', () async {
    if (!h.ok) {
      markTestSkipped('no test DB');
      return;
    }
    final steps = <Map<String, Object?>>[];
    final n = _Normaliser();
    Future<Res> step(String label, String method, String path,
        [Object? body]) async {
      final r = await h.call(method, path, as: 'owner', body: body);
      steps.add({
        'step': label,
        'request': '$method ${n.norm(path)}',
        'status': r.status,
        'json': n.norm(r.json),
      });
      expect(r.status, lessThan(500), reason: '$label ${r.json}');
      return r;
    }

    final a = (await step('create stream A', 'POST', '/api/streams', {
      'name': 'Everyday',
      'seedDate': '2026-01-01',
      'seedBalance': '1500.25',
      'lossThreshold': '200',
    }))
        .json['id'];
    final b = (await step('create stream B', 'POST', '/api/streams',
            {'name': 'Savings', 'seedDate': '2026-01-01'}))
        .json['id'];
    final c = (await step('create stream C', 'POST', '/api/streams',
            {'name': 'Home', 'seedDate': '2027-01-01'}))
        .json['id'];

    final once = (await step('once event', 'POST', '/api/streams/$a/events', {
      'name': 'Car service',
      'direction': 'debit',
      'amount': '1,250.50'.replaceAll(',', ''),
      'startDate': '2026-02-03',
      'recurrenceMode': 'once',
      'endMode': 'never',
    }))
        .json['id'];
    final monthly =
        (await step('monthly counted', 'POST', '/api/streams/$a/events', {
      'name': 'Rent',
      'direction': 'debit',
      'amount': '1200',
      'startDate': '2026-01-15',
      'frequency': {'rule': 'monthly', 'interval': 1},
      'endMode': 'count',
      'occurrenceCount': 12,
    }))
            .json['id'];
    final weekly =
        (await step('weekly days', 'POST', '/api/streams/$a/events', {
      'name': 'Coffee',
      'direction': 'debit',
      'amount': '4.50',
      'startDate': '2026-01-05',
      'frequency': {
        'rule': 'weekly',
        'interval': 2,
        'days': [1, 3]
      },
      'endMode': 'until_date',
      'endDate': '2026-12-31',
    }))
            .json['id'];
    await step('legacy cadence', 'POST', '/api/streams/$a/events', {
      'name': 'Salary',
      'direction': 'credit',
      'amount': '2500.5',
      'startDate': '2026-01-28',
      'recurrenceMode': 'every',
      'interval': 1,
      'unit': 'months',
      'endMode': 'never',
    });
    final transfer =
        (await step('transfer A to B', 'POST', '/api/streams/$a/events', {
      'name': 'To savings',
      'direction': 'debit',
      'amount': '300',
      'startDate': '2026-01-20',
      'frequency': {'rule': 'monthly', 'interval': 1},
      'endMode': 'never',
      'transferToStreamId': b,
    }))
            .json['id'];
    await step('loan', 'POST', '/api/streams/$c/events', {
      'name': 'Home loan',
      'kind': 'loan',
      'amount': '600000',
      'startDate': '2027-01-15',
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
            'from': '2027-01-15',
            'ratePct': '5.89',
            'type': 'fixed',
            'interestOnly': false,
            'offsetApplies': false
          },
        ],
      },
    });

    await step('override', 'PUT', '/api/events/$monthly/overrides/2026-03-15',
        {'amount': '1300.10', 'direction': 'debit'});
    await step('transfer override', 'PUT',
        '/api/events/$transfer/overrides/2026-02-20',
        {'amount': '450', 'direction': 'debit'});
    await step('skip', 'PUT', '/api/events/$weekly/skips/2026-01-07',
        {'skipped': true});
    await step('patch amount', 'PATCH', '/api/events/$once',
        {'amount': '1300', 'name': 'Car service'});
    await step('patch count', 'PATCH', '/api/events/$monthly',
        {'occurrenceCount': 10});
    await step('patch interval', 'PATCH', '/api/events/$weekly', {
      'frequency': {
        'rule': 'weekly',
        'interval': 3,
        'days': [1, 3]
      }
    });
    await step('patch transfer amount', 'PATCH', '/api/events/$transfer',
        {'amount': '320'});
    await step('split', 'POST', '/api/events/$monthly/split', {
      'date': '2026-06-15',
      'direction': 'debit',
      'amount': '1250',
    });
    await step('patch stream', 'PATCH', '/api/streams/$a',
        {'seedBalance': '1600', 'lossThreshold': '-50.5'});
    await step('scenario', 'POST', '/api/streams/$a/scenarios', {
      'name': 'Holiday',
      'request': {
        'solveFor': 'amount',
        'mode': 'onDate',
        'unit': 'weeks',
        'startDate': '2026-03-01',
        'endDate': '2026-09-01',
        'targetBalance': '5000',
        'interval': 1,
      },
    });

    await step('list streams', 'GET', '/api/streams');
    for (final s in [a, b, c]) {
      await step('get stream', 'GET', '/api/streams/$s');
      await step('list events', 'GET', '/api/streams/$s/events');
    }
    for (final t in [once, monthly, weekly, transfer]) {
      await step('get event', 'GET', '/api/events/$t');
    }
    await step('scenarios', 'GET', '/api/streams/$a/scenarios');
    await step('balance', 'GET',
        '/api/streams/$a/balance?from=2026-01-01&to=2026-12-31');

    final text = const JsonEncoder.withIndent(' ').convert(steps);
    final f = File(_golden);
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      f.writeAsStringSync('$text\n');
      return;
    }
    expect(f.existsSync(), isTrue, reason: 'record with UPDATE_GOLDENS=1');
    expect(text, f.readAsStringSync().trimRight());
  });
}
