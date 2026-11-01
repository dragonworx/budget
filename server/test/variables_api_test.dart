// DB-backed (TEST_DATABASE_URL, default local budget_test): spec 010's
// variables API and formula fields end to end through the real handler.
import 'package:budget_server/domain/variable_verify.dart';
import 'package:test/test.dart';

import 'authz/harness.dart';

void main() {
  final h = Harness('vars.test');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  Future<String> stream(String who, String name,
      {Map<String, Object?> extra = const {}}) async {
    final r = await h.call('POST', '/api/streams',
        as: who, body: {'name': name, 'seedDate': '2026-01-01', ...extra});
    expect(r.status, 201, reason: '${r.json}');
    return r.json['id'] as String;
  }

  Future<Res> variable(String who, String a, String name, Object value,
          {String unit = 'money'}) =>
      h.call('POST', '/api/streams/$a/variables',
          as: who, body: {'name': name, 'expr': '$value', 'unit': unit});

  Map<String, Object?> ev(String name, Map<String, Object?> extra) => {
        'name': name,
        'direction': 'debit',
        'startDate': '2026-01-01',
        'recurrenceMode': 'once',
        'endMode': 'never',
        ...extra,
      };

  Future<Map<String, dynamic>> getEvent(String id) async =>
      (await h.call('GET', '/api/events/$id', as: 'owner')).json
          as Map<String, dynamic>;

  test('acceptance: create, resolve, fan out, rename, delete', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('owner', 'Vars A');
    final rent = await variable('owner', a, 'rent', 1200);
    expect(rent.status, 201, reason: '${rent.json}');
    expect(rent.json['name'], 'rent');
    expect(rent.json['value'], '1200');
    final rentId = rent.json['id'] as String;

    // Names: unique ignoring case, `$` stripped, validated.
    final dup = await variable('owner', a, r'$RENT', 1);
    expect(dup.status, 409);
    expect(dup.json['details']['code'], 'variable_name_taken');
    expect((await variable('owner', a, '1bad', 1)).status, 400);

    // Event amount from a formula.
    final e = await h.call('POST', '/api/streams/$a/events',
        as: 'owner', body: ev('Rent share', {'amountExpr': r'$rent / 4'}));
    expect(e.status, 201, reason: '${e.json}');
    expect(e.json['amount'], '300');
    expect(e.json['amountExpr'], r'$rent / 4');
    expect(e.json.containsKey('formulaResolvedDifferently'), isFalse);
    final eid = e.json['id'] as String;

    // Rule 2: formula wins over a differing plain amount, flagged.
    final both = await h.call('POST', '/api/streams/$a/events',
        as: 'owner',
        body: ev('Both', {'amount': '5', 'amountExpr': r'$rent / 2'}));
    expect(both.json['amount'], '600');
    expect(both.json['formulaResolvedDifferently'], true);

    // Unknown name: 400 with field details, nothing stored.
    final bad = await h.call('POST', '/api/streams/$a/events',
        as: 'owner', body: ev('Bad', {'amountExpr': r'$nope * 2'}));
    expect(bad.status, 400);
    expect(bad.json['details']['field'], 'amountExpr');

    // Guard: long text and huge exponents rejected before parsing.
    for (final t in ['1' * 501, '1e999', '1e31', '-2E+40']) {
      final r = await h.call('POST', '/api/streams/$a/events',
          as: 'owner', body: ev('G', {'amountExpr': t}));
      expect(r.status, 400, reason: t);
    }

    final balBefore = (await h.call(
            'GET', '/api/streams/$a/balance?from=2026-01-01&to=2026-01-02',
            as: 'owner'))
        .json;

    // Usages and a dry-run preview change nothing.
    final usages =
        await h.call('GET', '/api/variables/$rentId/usages', as: 'owner');
    expect(usages.status, 200, reason: '${usages.json}');
    expect((usages.json['usages'] as List).length, 2);
    final preview = await h.call('POST', '/api/variables/$rentId/preview',
        as: 'owner', body: {'expr': '2000'});
    expect(preview.status, 200, reason: '${preview.json}');
    expect(
        (preview.json['changes'] as List)
            .any((c) => c['entityId'] == eid && c['newValue'] == '500'),
        isTrue,
        reason: '${preview.json}');
    expect((await getEvent(eid))['amount'], '300');

    // PATCH the value: dependents re-resolve in the same transaction.
    final v1 = rent.json['version'];
    final p = await h.call('PATCH', '/api/variables/$rentId',
        as: 'owner', body: {'expr': '1600', 'version': v1});
    expect(p.status, 200, reason: '${p.json}');
    expect((await getEvent(eid))['amount'], '400');
    final balAfter = (await h.call(
            'GET', '/api/streams/$a/balance?from=2026-01-01&to=2026-01-02',
            as: 'owner'))
        .json;
    expect(balAfter, isNot(balBefore));

    // Stale version: 409.
    final stale = await h.call('PATCH', '/api/variables/$rentId',
        as: 'owner', body: {'expr': '1700', 'version': v1});
    expect(stale.status, 409);

    // Rename rewrites references; values unchanged; inverse restores.
    final cur = (await h.call('GET', '/api/streams/$a/variables', as: 'owner'))
        .json['variables'] as List;
    var ver = cur.firstWhere((x) => x['id'] == rentId)['version'];
    final ren = await h.call('PATCH', '/api/variables/$rentId',
        as: 'owner', body: {'name': 'housing', 'version': ver});
    expect(ren.status, 200, reason: '${ren.json}');
    var got = await getEvent(eid);
    expect(got['amountExpr'], r'$housing / 4');
    expect(got['amount'], '400');
    ver = ren.json['version'];
    final back = await h.call('PATCH', '/api/variables/$rentId',
        as: 'owner', body: {'name': 'rent', 'version': ver});
    expect(back.status, 200);
    expect((await getEvent(eid))['amountExpr'], r'$rent / 4');

    // Dependent variables and cycles.
    final half = await variable('owner', a, 'half', r'$rent / 2');
    expect(half.status, 201, reason: '${half.json}');
    expect(half.json['value'], '800');
    final cyc = await h.call('PATCH', '/api/variables/$rentId',
        as: 'owner',
        body: {'expr': r'$half * 2', 'version': back.json['version']});
    expect(cyc.status, 400);
    expect(cyc.json['details']['code'], 'cycle');

    // Delete in use: 409 listing usages; free once unreferenced.
    final del = await h.call('DELETE', '/api/variables/$rentId', as: 'owner');
    expect(del.status, 409);
    expect(del.json['details']['code'], 'variable_in_use');

    // Live: the value change was recorded per affected stream.
    final live = await h.conn!
        .execute("SELECT count(*) FROM audit_log WHERE stream_id = '$a' "
            "AND action IN ('variable.values_changed', 'variable.renamed')");
    expect(live.first[0], greaterThanOrEqualTo(3));

    expect(await verifyVariables(h.conn!), isEmpty);
    // The reconciler catches drift (and changes nothing).
    await h.conn!.execute("UPDATE events SET amount = 1 WHERE id = '$eid'");
    final drift = await verifyVariables(h.conn!);
    expect(drift.single, contains('event $eid'));
    expect((await getEvent(eid))['amount'], '1');
    await h.conn!.execute("UPDATE events SET amount = 400 WHERE id = '$eid'");
    expect(await verifyVariables(h.conn!), isEmpty);
  });

  test('members read all of the owner\'s variables; only the owner manages',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('vowner', 'Shared');
    final other = await stream('vowner', 'Private');
    expect((await variable('vowner', other, 'secret', 7)).status, 201);
    final inv = await h.call('POST', '/api/streams/$a/invites',
        as: 'vowner', body: {'email': h.email('vviewer'), 'role': 'viewer'});
    expect(inv.status, 201, reason: '${inv.json}');
    await h.login('vviewer'); // signing in accepts the pending invite
    final list =
        await h.call('GET', '/api/streams/$a/variables', as: 'vviewer');
    expect(list.status, 200);
    // D20: every one of the owner's variables, for now.
    expect((list.json['variables'] as List).map((v) => v['name']),
        contains('secret'));
    expect(
        (await h.call('POST', '/api/streams/$a/variables',
                as: 'vviewer',
                body: {'name': 'x', 'expr': '1', 'unit': 'number'}))
            .status,
        403);
    // Outsiders see nothing.
    expect(
        (await h.call('GET', '/api/streams/$a/variables', as: 'voutsider'))
            .status,
        404);
  });

  test('transfers, overrides, split, loans, stream fields', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('towner', 'From');
    final b = await stream('towner', 'To');
    final pay = (await variable('towner', a, 'pay', 100)).json['id'];
    final t = await h.call('POST', '/api/streams/$a/events',
        as: 'towner',
        body: ev('Move', {
          'amountExpr': r'$pay * 2',
          'transferToStreamId': b,
          'recurrenceMode': 'every',
          'interval': 1,
          'unit': 'months',
        }));
    expect(t.status, 201, reason: '${t.json}');
    expect(t.json['amount'], '200');
    final peerId = t.json['transfer']['peerEventId'] as String;
    Future<Map<String, dynamic>> get(String id) async =>
        (await h.call('GET', '/api/events/$id', as: 'towner')).json;
    expect((await get(peerId))['amount'], '200');

    // Formula override.
    final o = await h.call(
        'PUT', '/api/events/${t.json['id']}/overrides/2026-03-01',
        as: 'towner', body: {'amountExpr': r'$pay + 1', 'direction': 'debit'});
    expect(o.status, 200, reason: '${o.json}');

    final vs = (await h.call('GET', '/api/variables', as: 'towner'))
        .json['variables'] as List;
    final p = await h.call('PATCH', '/api/variables/$pay',
        as: 'towner', body: {'expr': '150', 'version': vs.first['version']});
    expect(p.status, 200, reason: '${p.json}');
    expect((await get(t.json['id'] as String))['amount'], '300');
    expect((await get(peerId))['amount'], '300');
    final ov =
        ((await get(t.json['id'] as String))['overrides'] as List?) ?? const [];
    expect(ov.any((x) => '$x'.contains('151')), isTrue, reason: '$ov');

    // Split "from now on" with a formula amount.
    final s = await h
        .call('POST', '/api/events/${t.json['id']}/split', as: 'towner', body: {
      'date': '2026-06-01',
      'direction': 'debit',
      'amountExpr': r'$pay / 3',
    });
    expect(s.status, 200, reason: '${s.json}');
    expect(s.json['created']['amount'], '50');
    expect(s.json['created']['amountExpr'], r'$pay / 3');

    // Stream fields.
    final sp = await h.call('PATCH', '/api/streams/$b',
        as: 'towner', body: {'seedBalanceExpr': r'$pay * 10'});
    expect(sp.status, 200, reason: '${sp.json}');
    expect(sp.json['seedBalance'], '1500');
    expect(sp.json['seedBalanceExpr'], r'$pay * 10');

    // A loan whose rate is a variable.
    final c = await stream('towner', 'Loan');
    expect((await variable('towner', c, 'rate', 5.89, unit: 'percent')).status,
        201);
    final loan =
        await h.call('POST', '/api/streams/$c/events', as: 'towner', body: {
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
            'ratePct': '1',
            'ratePctExpr': r'$rate',
            'type': 'fixed',
            'interestOnly': false,
            'offsetApplies': false
          }
        ],
      },
    });
    expect(loan.status, 201, reason: '${loan.json}');
    expect(loan.json['loan']['ratePeriods'][0]['ratePct'], '5.89');
    expect(loan.json['formulaResolvedDifferently'], true);

    expect(await verifyVariables(h.conn!), isEmpty);
  });

  test('trim/undo round-trips formulas; undo after a rename flags D9',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('uowner', 'Undo');
    final x = await variable('uowner', a, 'x', 40);
    final e = await h.call('POST', '/api/streams/$a/events',
        as: 'uowner',
        body: ev('X', {'amountExpr': r'$x + 2', 'startDate': '2026-03-01'}));
    final eid = e.json['id'] as String;
    final trim = await h
        .call('POST', '/api/streams/$a/events/trim', as: 'uowner', body: {
      // After the trim day: the trim deletes it (snapshot restore).
      'date': '2026-01-15',
      'ids': [eid]
    });
    expect(trim.status, 200, reason: '${trim.json}');
    expect(trim.json['batchId'], isA<String>(), reason: '${trim.json}');
    // Rename while the row is gone: the restored text names $x.
    final ren = await h.call('PATCH', '/api/variables/${x.json['id']}',
        as: 'uowner', body: {'name': 'y', 'version': x.json['version']});
    expect(ren.status, 200, reason: '${ren.json}');
    final undo = await h.call('POST', '/api/streams/$a/events/trim/undo',
        as: 'uowner', body: {'batchId': trim.json['batchId']});
    expect(undo.status, 200, reason: '${undo.json}');
    final got =
        (await h.call('GET', '/api/events/$eid', as: 'uowner')).json as Map;
    expect(got['amount'], '42');
    expect(got['amountExpr'], r'$x + 2');
    expect(got['exprErrors']['amount']['code'], 'unknown_variable');
    expect(await verifyVariables(h.conn!), isEmpty);
  });

  test('import amountExpr, scenarios exprs', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('iowner', 'Import');
    await variable('iowner', a, 'k', 10);
    final item = {
      'name': 'I',
      'direction': 'debit',
      'amountExpr': r'$k * 3',
      'startOffset': 0,
      'recurrence': {'mode': 'once'},
    };
    final ok = await h.call(
        'POST', '/api/streams/$a/events/import?root=2026-01-01',
        as: 'iowner', body: [item]);
    expect(ok.status, 201, reason: '${ok.json}');
    final id = (ok.json['createdIds'] as List).single;
    final got = (await h.call('GET', '/api/events/$id', as: 'iowner')).json;
    expect(got['amount'], '30');
    expect(got['amountExpr'], r'$k * 3');
    final bad = await h.call(
        'POST', '/api/streams/$a/events/import?root=2026-01-01',
        as: 'iowner',
        body: [
          {...item, 'amountExpr': r'$missing'}
        ]);
    expect(bad.status, 400);
    expect((bad.json['details'] as List).single['field'], 'amountExpr');

    final sc =
        await h.call('POST', '/api/streams/$a/scenarios', as: 'iowner', body: {
      'name': 'S',
      'request': {
        'solveFor': 'amount',
        'exprs': {'amount': r'$k * 2'}
      }
    });
    expect(sc.status, lessThan(300), reason: '${sc.json}');
    expect(sc.json['request']['exprs'], {'amount': r'$k * 2'});
    final scBad =
        await h.call('POST', '/api/streams/$a/scenarios', as: 'iowner', body: {
      'name': 'S2',
      'request': {
        'solveFor': 'amount',
        'exprs': {'amount': r'$k * (2'}
      }
    });
    expect(scBad.status, 400);
  });

  group('FEATURE_VARIABLES=false', () {
    final off = Harness('varsoff.test', featureVariables: false);
    setUpAll(() => off.open());
    tearDownAll(() => off.close());
    test('variable routes 404, formula keys 400, config says off', () async {
      if (!off.ok) return markTestSkipped('no test DB');
      final a = await off.call('POST', '/api/streams',
          as: 'o', body: {'name': 'Off', 'seedDate': '2026-01-01'});
      final id = a.json['id'];
      expect(
          (await off.call('GET', '/api/streams/$id/variables', as: 'o')).status,
          404);
      expect((await off.call('GET', '/api/variables', as: 'o')).status, 404);
      final r = await off.call('POST', '/api/streams/$id/events',
          as: 'o', body: ev('E', {'amount': '1', 'amountExpr': '2'}));
      expect(r.status, 400);
      expect(r.json['details']['code'], 'formulas_disabled');
      final cfg = await off.call('GET', '/api/auth/config');
      expect(cfg.json['features'], {'variables': false});
      // Plain writes are untouched.
      expect(
          (await off.call('POST', '/api/streams/$id/events',
                  as: 'o', body: ev('E', {'amount': '1'})))
              .status,
          201);
    });
  });
}
