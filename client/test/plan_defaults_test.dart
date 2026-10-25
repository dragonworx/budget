import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/solve_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

/// Toy solver: complete when start, interval and count are all known
/// (others derived); start+interval+end+count together conflict unless
/// consistent (end must equal start + (count-1) weeks).
Future<SolveResult> _solve(SolveRequest r) async {
  final s = r.startDate, i = r.interval, n = r.occurrenceCount, e = r.endDate;
  final solved = <String>[];
  var start = s, end = e;
  if (s == null && e != null && i != null && n != null) {
    start = e.subtract(Duration(days: 7 * i * (n - 1)));
    solved.add('startDate');
  }
  if (e == null && s != null && i != null && n != null) {
    end = s.add(Duration(days: 7 * i * (n - 1)));
    solved.add('endDate');
  }
  if (s != null &&
      e != null &&
      i != null &&
      n != null &&
      e != s.add(Duration(days: 7 * i * (n - 1)))) {
    throw Exception('conflict');
  }
  final complete = start != null && end != null && i != null && n != null;
  return SolveResult.fromJson({
    'status': complete ? 'solved' : 'incomplete',
    'solved': solved,
    'values': {
      'startDate': start == null ? null : formatDate(start),
      'endDate': end == null ? null : formatDate(end),
      'interval': i,
      'count': n,
    },
    'needsMore': complete ? 0 : 1,
    'needsOneOf': complete ? <String>[] : ['count'],
    if (complete)
      'event': {
        'id': 't',
        'streamId': 'a',
        'name': 'n',
        'direction': 'credit',
        'amount': '1',
        'startDate': formatDate(start),
        'recurrenceMode': 'every',
        'interval': i,
        'unit': 'weeks',
        'endMode': 'count',
        'occurrenceCount': n,
      },
    'previewOccurrences': <Object>[],
  });
}

SolveRequest _req({
  DateTime? start,
  DateTime? end,
  int? interval,
  int? count,
}) => SolveRequest(
  name: 'n',
  direction: EventDirection.credit,
  unit: RecurrenceUnit.weeks,
  startDate: start,
  endDate: end,
  interval: interval,
  occurrenceCount: count,
);

void main() {
  final today = DateTime(2026, 10, 16, 15);

  test('user-entered values that already solve need no defaults', () async {
    final (r, d) = await solveWithDefaults(
      _req(start: DateTime(2026, 10, 1), interval: 2, count: 3),
      _solve,
      today: today,
    );
    expect(r.isComplete, isTrue);
    expect(d, isEmpty);
  });

  test('blank start and spacing default to today / every 1 (auto)', () async {
    final (r, d) = await solveWithDefaults(
      _req(count: 4),
      _solve,
      today: today,
    );
    expect(r.isComplete, isTrue);
    expect(d, {SolveVar.startDate, SolveVar.interval});
    expect(r.values.startDate, DateTime(2026, 10, 16));
    expect(r.values.interval, 1);
  });

  test('end + count: only spacing assumed, start is calculated back', () async {
    final (r, d) = await solveWithDefaults(
      _req(end: DateTime(2026, 11, 13), count: 5),
      _solve,
      today: today,
    );
    expect(d, {SolveVar.interval});
    expect(r.solved, contains(SolveVar.startDate));
    expect(r.values.startDate, DateTime(2026, 10, 16));
  });

  test('a typed value takes over from the default', () async {
    final (r, d) = await solveWithDefaults(
      _req(start: DateTime(2026, 12, 1), count: 2),
      _solve,
      today: today,
    );
    expect(d, {SolveVar.interval});
    expect(r.values.startDate, DateTime(2026, 12, 1));
  });

  test(
    'nothing entered: shows assumed start and spacing, still incomplete',
    () async {
      final (r, d) = await solveWithDefaults(_req(), _solve, today: today);
      expect(r.isComplete, isFalse);
      expect(d, {SolveVar.startDate, SolveVar.interval});
    },
  );
}
