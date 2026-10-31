import 'dart:convert';

import 'package:test/test.dart';

import 'harness.dart';

// Spec 004 through the full handler (authz middleware included): offset
// link validation and owner-only changes, the viewer's redacted summary,
// the streams-list indicator, unlink on delete, trim-undo filtering, the
// stream.offset_changed fan-out, and the offset stream's own /balance and
// /insights byte-identical before and after linking.
void main() {
  final h = Harness('offset.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  Future<String> stream(String who, String name,
      {String seed = '0', String? threshold}) async {
    final r = await h.call('POST', '/api/streams', as: who, body: {
      'name': name,
      'seedDate': '2027-01-01',
      'seedBalance': seed,
      if (threshold != null) 'lossThreshold': threshold,
    });
    expect(r.status, 201, reason: '${r.json}');
    return r.json['id'] as String;
  }

  Map<String, Object?> loan({List<String>? offsets, bool flat = false}) => {
        'name': 'Home loan',
        'kind': 'loan',
        'amount': '100000',
        'startDate': '2027-01-01',
        'loan': {
          'v': 1,
          'mode': 'simple',
          'interestType': flat ? 'flat' : 'reducing',
          'termMonths': 360,
          'repaymentFrequency': 'monthly',
          if (!flat) 'chargeDay': 'monthEnd',
          if (!flat) 'dayCount': '365',
          'ratePeriods': [
            {'from': '2027-01-01', 'ratePct': '3.65'}
          ],
        },
        if (offsets != null) 'offsetStreamIds': offsets,
      };

  Future<void> share(String streamId, String who, String role) async {
    await h.login(who);
    final r = await h.call('POST', '/api/streams/$streamId/invites',
        as: 'own', body: {'email': h.email(who), 'role': role});
    expect(r.status, 201, reason: '${r.json}');
  }

  Future<String?> janCharge(String who, String loanStream) async {
    final r = await h.call(
        'GET', '/api/streams/$loanStream/balance?from=2027-01-01&to=2027-01-31',
        as: who);
    expect(r.status, 200, reason: '${r.json}');
    final d = (r.json['occurrences'] as List)
        .where((o) => o['derived'] == true)
        .toList();
    return d.isEmpty ? null : d.single['signedDelta'] as String;
  }

  Future<List<Map>> auditOf(String streamId) async => [
        for (final r in await h.conn!
            .execute("SELECT action, detail::text, client_id FROM audit_log "
                "WHERE stream_id = '$streamId' ORDER BY id"))
          {'action': r[0], 'detail': jsonDecode(r[1] as String), 'client': r[2]}
      ];

  test('link, validation, owner-only, redaction, list, fan-out', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('own', 'Loan A');
    final b = await stream('own', 'Everyday', seed: '40000');
    final c = await stream('own', 'Other');
    final selfLoan = await stream('own', 'Car loan');
    final mine = await stream('ed', 'Editor savings', seed: '1000');
    // ed shares their stream with own: shared with the owner is not enough.
    await h.login('own');
    final inv = await h.call('POST', '/api/streams/$mine/invites',
        as: 'ed', body: {'email': h.email('own'), 'role': 'editor'});
    expect(inv.status, 201, reason: '${inv.json}');

    final offB = await h.call(
        'GET', '/api/streams/$b/balance?from=2027-01-01&to=2027-03-31',
        as: 'own');
    final insB = await h.call(
        'GET', '/api/streams/$b/insights?from=2027-01-01&to=2027-03-31',
        as: 'own');
    expect(insB.status, 200, reason: '${insB.json}');

    // A standard event may not carry offsets.
    final std =
        await h.call('POST', '/api/streams/$c/events', as: 'own', body: {
      ...Harness.tx('Pay'),
      'offsetStreamIds': [b]
    });
    expect(std.status, 400, reason: '${std.json}');

    // Bad links on create: 2 ids, self, other owner's (shared with me),
    // missing, a stream holding a loan, a flat loan.
    final carLoan = await h.call('POST', '/api/streams/$selfLoan/events',
        as: 'own', body: loan());
    expect(carLoan.status, 201, reason: '${carLoan.json}');
    for (final (body, msg) in [
      (loan(offsets: [b, c]), 'at most 1'),
      (loan(offsets: [a]), 'its own offset'),
      (loan(offsets: [mine]), ''),
      (loan(offsets: ['00000000-0000-0000-0000-00000000dead']), ''),
      (loan(offsets: [selfLoan]), 'loan'),
      (loan(offsets: [b], flat: true), 'flat-rate'),
    ]) {
      final r =
          await h.call('POST', '/api/streams/$a/events', as: 'own', body: body);
      expect(r.status, 400, reason: '${body['offsetStreamIds']} ${r.json}');
      expect(jsonEncode(r.json).toLowerCase(), contains(msg));
    }
    // Missing and another owner's give the same message.
    final m1 = await h.call('POST', '/api/streams/$a/events',
        as: 'own', body: loan(offsets: [mine]));
    final m2 = await h.call('POST', '/api/streams/$a/events',
        as: 'own',
        body: loan(offsets: ['00000000-0000-0000-0000-00000000dead']));
    expect(m1.json, m2.json);

    // A valid link.
    final created = await h.call('POST', '/api/streams/$a/events',
        as: 'own', body: loan(offsets: [b]));
    expect(created.status, 201, reason: '${created.json}');
    final loanId = created.json['id'] as String;
    expect(created.json['offsetStreamIds'], [b]);
    expect(await janCharge('own', a), '-186');

    // The offset stream may not receive a loan: 409.
    final onOff =
        await h.call('POST', '/api/streams/$b/events', as: 'own', body: loan());
    expect(onOff.status, 409, reason: '${onOff.json}');
    expect(jsonEncode(onOff.json),
        contains('this stream is the offset account for Loan A'));

    // Offset stream's own /balance and /insights: byte-identical.
    final offB2 = await h.call(
        'GET', '/api/streams/$b/balance?from=2027-01-01&to=2027-03-31',
        as: 'own');
    final insB2 = await h.call(
        'GET', '/api/streams/$b/insights?from=2027-01-01&to=2027-03-31',
        as: 'own');
    expect(jsonEncode(offB2.json), jsonEncode(offB.json));
    expect(jsonEncode(insB2.json), jsonEncode(insB.json));

    // Editor and viewer on the loan stream only (not the offset).
    await share(a, 'ed', 'editor');
    await share(a, 'vi', 'viewer');
    // Editor: changing the link is 403; an unchanged list is accepted;
    // other terms may change.
    final ver = created.json['version'];
    final edChange = await h.call('PATCH', '/api/events/$loanId',
        as: 'ed', body: {'version': ver, 'offsetStreamIds': <String>[]});
    expect(edChange.status, 403, reason: '${edChange.json}');
    final edSame =
        await h.call('PATCH', '/api/events/$loanId', as: 'ed', body: {
      'version': ver,
      'offsetStreamIds': [b],
      'name': 'Mortgage'
    });
    expect(edSame.status, 200, reason: '${edSame.json}');
    // The editor can't see b: the id is redacted, offsetHidden says so.
    expect(edSame.json['offsetStreamIds'], isEmpty);
    expect(edSame.json['offsetHidden'], isTrue);
    final ownView = await h.call('GET', '/api/events/$loanId', as: 'own');
    expect(ownView.json['offsetStreamIds'], [b]);
    expect(ownView.json.containsKey('offsetHidden'), isFalse);

    // Viewer: balances include the offset; the summary hides the stream.
    expect(await janCharge('vi', a), '-186');
    final vs = await h
        .call('GET', '/api/streams/$a/loan-summary?from=2027-01-15', as: 'vi');
    expect(vs.status, 200, reason: '${vs.json}');
    final vo = vs.json['offset'] as Map;
    expect(vo['streamId'], isNull);
    expect(vo['streamName'], isNull);
    expect(vo['visible'], isFalse);
    expect(vo['usableToday'], '40000.00');
    expect(jsonEncode(vs.json), isNot(contains(b)));
    expect(jsonEncode(vs.json), isNot(contains('Everyday')));
    final os = await h
        .call('GET', '/api/streams/$a/loan-summary?from=2027-01-15', as: 'own');
    expect(os.json['offset']['streamId'], b);
    expect(os.json['offset']['streamName'], 'Everyday');
    final vEvents = await h.call('GET', '/api/streams/$a/events', as: 'vi');
    expect(jsonEncode(vEvents.json), isNot(contains(b)));

    // Streams list indicators.
    final ownList = (await h.call('GET', '/api/streams', as: 'own'))
        .json['streams'] as List;
    Map row(List l, String id) => l.firstWhere((s) => s['id'] == id) as Map;
    expect(row(ownList, a)['offset'],
        {'streamId': b, 'name': 'Everyday', 'visible': true});
    expect(row(ownList, b)['offsetFor'], [
      {'streamId': a, 'name': 'Loan A', 'visible': true}
    ]);
    expect(row(ownList, c).containsKey('offset'), isFalse);
    expect(row(ownList, c).containsKey('offsetFor'), isFalse);
    final viList =
        (await h.call('GET', '/api/streams', as: 'vi')).json['streams'] as List;
    expect(row(viList, a)['offset'],
        {'streamId': null, 'name': null, 'visible': false});

    // Fan-out: an event in b records stream.offset_changed on a, without a
    // client id and without b's id.
    final pay = await h.call('POST', '/api/streams/$b/events',
        as: 'own',
        body: {...Harness.tx('Groceries'), 'startDate': '2027-01-10'},
        headers: {'x-client-id': 'client-1'});
    expect(pay.status, 201, reason: '${pay.json}');
    final fan = (await auditOf(a))
        .where((x) => x['action'] == 'stream.offset_changed')
        .toList();
    expect(fan, isNotEmpty);
    expect(fan.last['client'], isNull);
    expect(fan.last['detail'], {'via': 'event.created'});
    // Groceries 10 on 10 Jan: 9 x 6.00 + 22 x 6.001 = 186.022 -> 186.02.
    expect(await janCharge('own', a), '-186.02');

    // Owner unlinks with []: back to 310.
    final cur = (await h.call('GET', '/api/events/$loanId', as: 'own')).json;
    final un = await h.call('PATCH', '/api/events/$loanId',
        as: 'own',
        body: {'version': cur['version'], 'offsetStreamIds': <String>[]});
    expect(un.status, 200, reason: '${un.json}');
    expect(un.json['offsetStreamIds'], isEmpty);
    expect(await janCharge('own', a), '-310');
    // Re-link via PATCH, then switching to flat while linked is 400.
    final re = await h.call('PATCH', '/api/events/$loanId', as: 'own', body: {
      'version': un.json['version'],
      'offsetStreamIds': [b]
    });
    expect(re.status, 200, reason: '${re.json}');
    final toFlat = await h.call('PATCH', '/api/events/$loanId',
        as: 'own',
        body: {
          'version': re.json['version'],
          'loan': loan(flat: true)['loan']
        });
    expect(toFlat.status, 400, reason: '${toFlat.json}');
    expect(jsonEncode(toFlat.json), contains('flat-rate'));

    // Project preview with a changed link: owner only.
    final proj = {
      'from': '2027-01-01',
      'to': '2027-01-31',
      'events': [
        {
          'replacesEventId': loanId,
          ...loan(offsets: []),
        }
      ],
    };
    final pv =
        await h.call('POST', '/api/streams/$a/project', as: 'own', body: proj);
    expect(pv.status, 200, reason: '${pv.json}');
    // Unlinked in the preview: Jan's balance includes the full 310.
    expect((pv.json['points'] as List).last['closingBalance'], '-100310');
    // An editor previewing the saved link (no ids) is fine.
    final same =
        await h.call('POST', '/api/streams/$a/project', as: 'ed', body: {
      ...proj,
      'events': [
        {'replacesEventId': loanId, ...loan()}
      ],
    });
    expect(same.status, 200, reason: '${same.json}');
    expect((same.json['points'] as List).last['closingBalance'], '-100186.02');
    final pe =
        await h.call('POST', '/api/streams/$a/project', as: 'ed', body: proj);
    expect(pe.status, 403, reason: '${pe.json}');

    // Deleting the offset stream unlinks and audits the loan stream.
    final del = await h.call('DELETE', '/api/streams/$b', as: 'own');
    expect(del.status, 200, reason: '${del.json}');
    final after = (await h.call('GET', '/api/events/$loanId', as: 'own')).json;
    expect(after['offsetStreamIds'], isEmpty);
    expect(await janCharge('own', a), '-310');
    final unl = (await auditOf(a)).where((x) =>
        x['action'] == 'event.updated' &&
        (x['detail'] as Map)['via'] == 'offset_deleted');
    expect(unl, hasLength(1));
  });

  test('trim undo drops an offset that was deleted meanwhile', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('own', 'Trim loan');
    final b = await stream('own', 'Trim offset', seed: '40000');
    final keep = await stream('own', 'Trim keep', seed: '40000');
    Future<String> make(String offset) async {
      final r =
          await h.call('POST', '/api/streams/$a/events', as: 'own', body: {
        ...loan(offsets: [offset]),
        'startDate': '2027-02-01',
        'loan': {
          ...(loan()['loan'] as Map),
          'ratePeriods': [
            {'from': '2027-02-01', 'ratePct': '3.65'}
          ]
        }
      });
      expect(r.status, 201, reason: '${r.json}');
      return r.json['id'] as String;
    }

    Future<String> trimUndo(String id,
        {Future<void> Function()? between}) async {
      final t =
          await h.call('POST', '/api/streams/$a/events/trim', as: 'own', body: {
        'date': '2027-01-15',
        'ids': [id]
      });
      expect(t.status, 200, reason: '${t.json}');
      await between?.call();
      final u = await h.call('POST', '/api/streams/$a/events/trim/undo',
          as: 'own', body: {'batchId': t.json['batchId']});
      expect(u.status, 200, reason: '${u.json}');
      return jsonEncode((await h.call('GET', '/api/events/$id', as: 'own'))
          .json['offsetStreamIds']);
    }

    // Still valid: kept.
    final l1 = await make(keep);
    expect(await trimUndo(l1), jsonEncode([keep]));
    // Re-link to b, trim, delete b, undo: the id is dropped.
    final cur = (await h.call('GET', '/api/events/$l1', as: 'own')).json;
    final p = await h.call('PATCH', '/api/events/$l1', as: 'own', body: {
      'version': cur['version'],
      'offsetStreamIds': [b]
    });
    expect(p.status, 200, reason: '${p.json}');
    expect(
        await trimUndo(l1, between: () async {
          final d = await h.call('DELETE', '/api/streams/$b', as: 'own');
          expect(d.status, 200);
        }),
        '[]');
  });
}
