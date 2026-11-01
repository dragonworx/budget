// DB-backed timing check (spec 010): with 1000 fields across 20 streams
// referencing one variable, p95 of a value PATCH (re-resolve + fan-out),
// a rename and a preview <= 250 ms; a formula event write adds <= 5 ms
// (p95) over a plain one.
@Tags(['perf'])
library;

import 'package:test/test.dart';

import 'authz/harness.dart';

void main() {
  final h = Harness('varsperf.test', rateLimitPerMinute: 0);
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  double p(List<int> us, double q) {
    final s = [...us]..sort();
    return s[((s.length - 1) * q).round()] / 1000;
  }

  test('1000 refs: patch / rename / preview p95 <= 250 ms', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final streams = [
      for (var i = 0; i < 20; i++)
        (await h.call('POST', '/api/streams',
                as: 'p', body: {'name': 'Perf $i', 'seedDate': '2026-01-01'}))
            .json['id'],
    ];
    final a = streams.first;
    final v = await h.call('POST', '/api/streams/$a/variables',
        as: 'p', body: {'name': 'base', 'expr': '100', 'unit': 'money'});
    final vid = v.json['id'];
    var version = v.json['version'];
    Map<String, Object?> ev(int i, {bool formula = true}) => {
          'name': 'E$i',
          'direction': 'debit',
          'startDate': '2026-01-01',
          'recurrenceMode': 'every',
          'interval': 1,
          'unit': 'months',
          'endMode': 'never',
          if (formula) 'amountExpr': '\$base + $i' else 'amount': '${100 + i}',
        };
    // Write cost: plain vs formula creates (warm, interleaved).
    final plain = <int>[], formula = <int>[];
    for (var i = 0; i < 1000; i++) {
      final s = streams[i % 20];
      final sw = Stopwatch()..start();
      final r = await h.call('POST', '/api/streams/$s/events',
          as: 'p', body: ev(i, formula: true));
      formula.add(sw.elapsedMicroseconds);
      expect(r.status, 201);
      if (i < 200) {
        final sw2 = Stopwatch()..start();
        await h.call('POST', '/api/streams/$s/events',
            as: 'p', body: ev(i, formula: false));
        plain.add(sw2.elapsedMicroseconds);
      }
    }
    // Like for like: the 200 interleaved pairs.
    final paired = formula.take(200).toList();
    final added = p(paired, .95) - p(plain, .95);
    // ignore: avoid_print
    print('create p95: plain ${p(plain, .95)} ms, formula '
        '${p(paired, .95)} ms (+${added.toStringAsFixed(2)} ms); median '
        '+${(p(paired, .5) - p(plain, .5)).toStringAsFixed(2)} ms');
    expect(added, lessThanOrEqualTo(5));

    // Patch cost: plain vs formula amount on the same rows (interleaved).
    final ids = [
      for (final s in streams.take(5))
        for (final e in (await h.call('GET', '/api/streams/$s/events', as: 'p'))
            .json['events'] as List)
          (e as Map)['id'] as String,
    ].take(100).toList();
    final pPlain = <int>[], pFormula = <int>[];
    for (var i = 0; i < ids.length; i++) {
      var sw = Stopwatch()..start();
      var r = await h.call('PATCH', '/api/events/${ids[i]}',
          as: 'p', body: {'amount': '${50 + i}'});
      pPlain.add(sw.elapsedMicroseconds);
      expect(r.status, 200, reason: '${r.json}');
      sw = Stopwatch()..start();
      r = await h.call('PATCH', '/api/events/${ids[i]}',
          as: 'p', body: {'amountExpr': '\$base + $i'});
      pFormula.add(sw.elapsedMicroseconds);
      expect(r.status, 200, reason: '${r.json}');
    }
    final pAdded = p(pFormula, .95) - p(pPlain, .95);
    // ignore: avoid_print
    print('patch p95: plain ${p(pPlain, .95)} ms, formula '
        '${p(pFormula, .95)} ms (+${pAdded.toStringAsFixed(2)} ms)');
    expect(pAdded, lessThanOrEqualTo(5));

    final patch = <int>[], rename = <int>[], preview = <int>[];
    for (var i = 0; i < 20; i++) {
      var sw = Stopwatch()..start();
      final r = await h.call('PATCH', '/api/variables/$vid',
          as: 'p', body: {'expr': '${200 + i}', 'version': version});
      patch.add(sw.elapsedMicroseconds);
      expect(r.status, 200, reason: '${r.json}');
      version = r.json['version'];
      sw = Stopwatch()..start();
      final n = await h.call('PATCH', '/api/variables/$vid',
          as: 'p',
          body: {'name': i.isEven ? 'base2' : 'base', 'version': version});
      rename.add(sw.elapsedMicroseconds);
      expect(n.status, 200, reason: '${n.json}');
      version = n.json['version'];
      sw = Stopwatch()..start();
      final pv = await h.call('POST', '/api/variables/$vid/preview',
          as: 'p', body: {'expr': '999'});
      preview.add(sw.elapsedMicroseconds);
      expect(pv.status, 200);
    }
    // ignore: avoid_print
    print('1000 refs p95: patch ${p(patch, .95)} ms, rename '
        '${p(rename, .95)} ms, preview ${p(preview, .95)} ms');
    expect(p(patch, .95), lessThanOrEqualTo(250));
    expect(p(rename, .95), lessThanOrEqualTo(250));
    expect(p(preview, .95), lessThanOrEqualTo(250));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
