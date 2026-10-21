import 'dart:convert';

import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/transaction_import.dart';
import 'package:test/test.dart';

/// The selected timeline day every offset counts from.
final root = DateTime.utc(2026, 11, 1);

List<ImportItem> parse(String raw, {DateTime? at}) =>
    parseImport(raw, root: at ?? root);

List<ImportIssue> issuesOf(String raw) {
  try {
    parse(raw);
  } on ImportValidationException catch (e) {
    return e.issues;
  }
  fail('expected validation failure');
}

String once(int offset) => '{"direction":"debit","amount":1,'
    '"startOffset":$offset,"recurrence":{"mode":"once"}}';

void main() {
  const valid = '''
[
  {"name":"Salary","direction":"credit","amount":"5000","startOffset":0,
   "recurrence":{"mode":"every","interval":2,"unit":"weeks"},"end":{"mode":"never"}},
  {"direction":"debit","amount":120.5,"startOffset":53,"recurrence":{"mode":"once"}},
  {"id":"0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","name":"Gym","direction":"debit","amount":"60",
   "startOffset":2,"recurrence":{"mode":"every","interval":1,"unit":"months"},
   "end":{"mode":"count","occurrences":12},"enabled":false,
   "skippedOffsets":[32,32,63]},
  {"name":"Rent","direction":"debit","amount":"2000","startOffset":0,
   "recurrence":{"mode":"every","interval":1,"unit":"months"},
   "end":{"mode":"until_offset","endOffset":364}}
]''';

  test('parses a valid array, resolving offsets from the root', () {
    final items = parse(valid);
    expect(items, hasLength(4));
    expect(items[0].recurrenceMode, RecurrenceMode.every);
    expect(items[0].unit, RecurrenceUnit.weeks);
    expect(items[0].interval, 2);
    expect(items[0].startDate, DateTime.utc(2026, 11, 1));
    expect(items[1].name, '');
    expect(items[1].amount.toString(), '120.5');
    expect(items[1].endMode, EndMode.never);
    expect(items[1].startDate, DateTime.utc(2026, 12, 24));
    expect(items[2].id, '0f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9');
    expect(items[2].enabled, isFalse);
    expect(items[2].occurrenceCount, 12);
    expect(items[2].startDate, DateTime.utc(2026, 11, 3));
    expect(items[2].skippedDates,
        [DateTime.utc(2026, 12, 3), DateTime.utc(2027, 1, 3)]);
    expect(items[2].skippedOffsets, [32, 63]);
    expect(items[3].endMode, EndMode.untilDate);
    expect(items[3].endDate, DateTime.utc(2027, 10, 31));
    expect(items[3].endOffset, 364);
    final json = items[3].toJson();
    expect(json['startDate'], '2026-11-01');
    expect(json['endDate'], '2027-10-31');
    expect(json['startOffset'], 0);
  });

  test('a different root moves every date by calendar days', () {
    final items = parse(valid, at: DateTime.utc(2027, 1, 31));
    expect(items[0].startDate, DateTime.utc(2027, 1, 31));
    expect(items[2].startDate, DateTime.utc(2027, 2, 2));
    expect(items[2].skippedDates.first, DateTime.utc(2027, 3, 4));
    // A local-time root is reduced to its calendar date.
    expect(parse(once(0), at: DateTime(2026, 10, 4, 23, 30)).single.startDate,
        DateTime.utc(2026, 10, 4));
  });

  group('resolveOffset', () {
    DateTime r(int y, int m, int d, int n) =>
        resolveOffset(DateTime.utc(y, m, d), n);
    test('month ends, leap years and year rollover', () {
      expect(r(2026, 1, 31, 1), DateTime.utc(2026, 2, 1));
      expect(r(2027, 2, 28, 1), DateTime.utc(2027, 3, 1));
      expect(r(2028, 2, 28, 1), DateTime.utc(2028, 2, 29));
      expect(r(2028, 2, 29, 1), DateTime.utc(2028, 3, 1));
      expect(r(2028, 1, 31, 29), DateTime.utc(2028, 2, 29));
      expect(r(2026, 12, 31, 1), DateTime.utc(2027, 1, 1));
      expect(r(2027, 1, 1, -1), DateTime.utc(2026, 12, 31));
      expect(r(2026, 1, 1, 365), DateTime.utc(2027, 1, 1));
      expect(r(2028, 1, 1, 366), DateTime.utc(2029, 1, 1));
    });
    test('Sydney DST changes never shift a date', () {
      // DST starts Sun 4 Oct 2026 and ends Sun 5 Apr 2026 / 4 Apr 2027.
      expect(r(2026, 10, 3, 1), DateTime.utc(2026, 10, 4));
      expect(r(2026, 10, 3, 2), DateTime.utc(2026, 10, 5));
      expect(r(2026, 10, 4, 0), DateTime.utc(2026, 10, 4));
      expect(r(2026, 4, 4, 1), DateTime.utc(2026, 4, 5));
      expect(r(2026, 4, 4, 2), DateTime.utc(2026, 4, 6));
      expect(r(2026, 9, 1, 180), DateTime.utc(2027, 2, 28));
      expect(r(2026, 10, 1, 186), DateTime.utc(2027, 4, 5));
      for (var n = -400; n <= 400; n++) {
        final d = r(2026, 10, 4, n);
        expect(d.hour, 0);
        expect(d.difference(DateTime.utc(2026, 10, 4)).inDays, n);
      }
    });
  });

  test('negative offsets resolve before the root', () {
    final items = parse('[${once(-3)}]');
    expect(items.single.startDate, DateTime.utc(2026, 10, 29));
  });

  test('skippedOffsets and endOffset resolve from the root', () {
    final item = parse('[{"name":"Phone","direction":"debit","amount":"40",'
            '"startOffset":30,"recurrence":{"mode":"every","interval":1,"unit":"months"},'
            '"end":{"mode":"until_offset","endOffset":120},"skippedOffsets":[61,-2]}]')
        .single;
    expect(item.startDate, DateTime.utc(2026, 12, 1));
    expect(item.endDate, DateTime.utc(2027, 3, 1));
    expect(item.skippedDates,
        [DateTime.utc(2027, 1, 1), DateTime.utc(2026, 10, 30)]);
    expect(
        issuesOf('[{"direction":"debit","amount":1,"startOffset":10,'
                '"recurrence":{"mode":"every","interval":1,"unit":"days"},'
                '"end":{"mode":"until_offset","endOffset":9}}]')
            .single
            .toString(),
        '[0].end.endOffset: is before startOffset');
  });

  test('offsets must be whole numbers', () {
    expect(parse('[${once(0).replaceFirst('0,', '7.0,')}]').single.startDate,
        DateTime.utc(2026, 11, 8));
    for (final bad in ['1.5', '"3"', 'true', 'null', '[1]', '1e400']) {
      final issues = issuesOf('[{"direction":"debit","amount":1,'
          '"startOffset":$bad,"recurrence":{"mode":"once"}}]');
      expect(issues.single.field, 'startOffset', reason: bad);
    }
    expect(
        issuesOf('[{"direction":"debit","amount":1,"startOffset":"3",'
                '"recurrence":{"mode":"once"}}]')
            .single
            .message,
        contains('not a string'));
    final issues = issuesOf('[{"direction":"debit","amount":1,"startOffset":0,'
        '"recurrence":{"mode":"every","interval":1,"unit":"weeks"},'
        '"end":{"mode":"until_offset","endOffset":2.5},'
        '"skippedOffsets":[7,"14",1.5]}]');
    expect(issues.map((i) => i.field), [
      'end.endOffset',
      'skippedOffsets[1]',
      'skippedOffsets[2]',
    ]);
    expect(issuesOf('[${once(99999)}]').single.message, contains('too far'));
    expect(
        issuesOf('[{"direction":"debit","amount":1,"startOffset":0,'
                '"recurrence":{"mode":"once"},"skippedOffsets":5}]')
            .single
            .field,
        'skippedOffsets');
  });

  test('absolute dates are rejected, naming the field and its replacement', () {
    final issues = issuesOf('''[
      {"direction":"debit","amount":1,"startDate":"2026-11-01","recurrence":{"mode":"once"}},
      {"direction":"debit","amount":1,"startOffset":0,"endDate":"2026-12-01",
       "recurrence":{"mode":"once"}},
      {"direction":"debit","amount":1,"startOffset":0,
       "recurrence":{"mode":"every","interval":1,"unit":"days"},
       "end":{"mode":"until_date","endDate":"2026-12-01"},"skippedDates":["2026-11-05"]}
    ]''');
    final byKey = {for (final i in issues) '${i.index}:${i.field}': i.message};
    expect(byKey.keys.toSet(), {
      '0:startDate',
      '1:endDate',
      '2:end.mode',
      '2:end.endDate',
      '2:skippedDates',
    });
    expect(byKey['0:startDate'], contains('use startOffset'));
    expect(byKey['1:endDate'], contains('until_offset'));
    expect(byKey['2:end.mode'], contains('"until_offset"'));
    expect(byKey['2:end.endDate'], contains('end.endOffset'));
    expect(byKey['2:skippedDates'], contains('use skippedOffsets'));
    for (final m in byKey.values) {
      expect(m, contains('selected day'));
    }
  });

  test('ignores project fields from older files', () {
    final items = parse('[{"name":"Old","direction":"debit","amount":"5",'
        '"startOffset":0,"recurrence":{"mode":"once"},'
        '"projectId":"x","projectName":"Household"}]');
    expect(items.single.name, 'Old');
    expect(
        issuesOf('[{"direction":"debit","amount":"5",'
                '"startOffset":0,"bogus":1}]')
            .map((i) => i.field),
        contains('bogus'));
  });

  test('accepts ```json fences, bare fences and a single object', () {
    expect(parse('```json\n$valid\n```'), hasLength(4));
    expect(parse('  ```\n$valid\n```  '), hasLength(4));
    expect(
      parse(
          '{"direction":"credit","amount":1,"startOffset":0,"recurrence":{"mode":"once"}}'),
      hasLength(1),
    );
    expect(parse(jsonEncode('```json\n$valid\n```')), hasLength(4));
    expect(stripCodeFence('```json\n[1]\n```'), '[1]');
  });

  test('reports every problem with index and field', () {
    final issues = issuesOf('''[
      {"direction":"in","amount":"-5","recurrence":{"mode":"every","interval":0,"unit":"fortnights"}},
      {"direction":"debit","amount":"x","startOffset":0,"recurrence":{"mode":"once"},"colour":"red"},
      {"direction":"debit","amount":1,"startOffset":5,"recurrence":{"mode":"every","interval":1,"unit":"days"},
       "end":{"mode":"until_offset","endOffset":1},"skippedOffsets":["nope"]},
      "hello"
    ]''');
    final keys = issues.map((i) => '${i.index}:${i.field}').toSet();
    expect(
        keys,
        containsAll([
          '0:direction',
          '0:amount',
          '0:startOffset',
          '0:recurrence.interval',
          '0:recurrence.unit',
          '0:end',
          '1:amount',
          '1:colour',
          '2:end.endOffset',
          '2:skippedOffsets[0]',
          '3:null',
        ]));
    expect(issues.first.toString(), startsWith('[0].direction: '));
  });

  test('rejects duplicate ids, bad ids, bad JSON and empty arrays', () {
    const item =
        '"direction":"debit","amount":1,"startOffset":0,"recurrence":{"mode":"once"}';
    final dup = issuesOf('[{"id":"0f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9",$item},'
        '{"id":"0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9",$item}]');
    expect(dup.single.toString(), '[1].id: duplicate of item [0]');
    expect(issuesOf('[{"id":"abc",$item}]').single.field, 'id');
    expect(issuesOf('[{').single.message, startsWith('Invalid JSON'));
    expect(issuesOf('[]').single.message, 'The array is empty');
    expect(issuesOf('   ').single.message, startsWith('Nothing to import'));
    expect(issuesOf('42').single.message, startsWith('Expected a JSON array'));
  });

  test('once items ignore a supplied end rule', () {
    final items = parse('[{"direction":"debit","amount":1,"startOffset":0,'
        '"recurrence":{"mode":"once"},"end":{"mode":"count","occurrences":3}}]');
    expect(items.single.endMode, EndMode.never);
    expect(items.single.occurrenceCount, isNull);
  });

  test('parseImportRoot accepts only real YYYY-MM-DD dates', () {
    expect(parseImportRoot('2026-10-04'), DateTime.utc(2026, 10, 4));
    expect(parseImportRoot('2026-02-30'), isNull);
    expect(parseImportRoot(null), isNull);
    expect(parseImportRoot('4/10/2026'), isNull);
  });
}
