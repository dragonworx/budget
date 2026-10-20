import 'dart:convert';

import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/transaction_import.dart';
import 'package:test/test.dart';

List<ImportIssue> issuesOf(String raw) {
  try {
    parseImport(raw);
  } on ImportValidationException catch (e) {
    return e.issues;
  }
  fail('expected validation failure');
}

void main() {
  const valid = '''
[
  {"name":"Salary","direction":"credit","amount":"5000","startDate":"2026-11-01",
   "recurrence":{"mode":"every","interval":2,"unit":"weeks"},"end":{"mode":"never"}},
  {"direction":"debit","amount":120.5,"startDate":"2026-12-24","recurrence":{"mode":"once"}},
  {"id":"0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","name":"Gym","direction":"debit","amount":"60",
   "startDate":"2026-11-03","recurrence":{"mode":"every","interval":1,"unit":"months"},
   "end":{"mode":"count","occurrences":12},"enabled":false,
   "skippedDates":["2026-12-03","2026-12-03","2027-01-03"]},
  {"name":"Rent","direction":"debit","amount":"2000","startDate":"2026-11-01",
   "recurrence":{"mode":"every","interval":1,"unit":"months"},
   "end":{"mode":"until_date","endDate":"2027-10-31"}}
]''';

  test('parses a valid array into items', () {
    final items = parseImport(valid);
    expect(items, hasLength(4));
    expect(items[0].recurrenceMode, RecurrenceMode.every);
    expect(items[0].unit, RecurrenceUnit.weeks);
    expect(items[0].interval, 2);
    expect(items[1].name, '');
    expect(items[1].amount.toString(), '120.5');
    expect(items[1].endMode, EndMode.never);
    expect(items[2].id, '0f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9');
    expect(items[2].enabled, isFalse);
    expect(items[2].occurrenceCount, 12);
    expect(items[2].skippedDates,
        [DateTime.utc(2026, 12, 3), DateTime.utc(2027, 1, 3)]);
    expect(items[3].endMode, EndMode.untilDate);
    expect(items[3].endDate, DateTime.utc(2027, 10, 31));
  });

  test('ignores project fields from older files', () {
    final items = parseImport('[{"name":"Old","direction":"debit","amount":"5",'
        '"startDate":"2026-11-01","recurrence":{"mode":"once"},'
        '"projectId":"x","projectName":"Household"}]');
    expect(items.single.name, 'Old');
    expect(
        issuesOf('[{"direction":"debit","amount":"5",'
                '"startDate":"2026-11-01","bogus":1}]')
            .map((i) => i.field),
        contains('bogus'));
  });

  test('accepts ```json fences, bare fences and a single object', () {
    expect(parseImport('```json\n$valid\n```'), hasLength(4));
    expect(parseImport('  ```\n$valid\n```  '), hasLength(4));
    expect(
      parseImport(
          '{"direction":"credit","amount":1,"startDate":"2026-01-01","recurrence":{"mode":"once"}}'),
      hasLength(1),
    );
    expect(parseImport(jsonEncode('```json\n$valid\n```')), hasLength(4));
    expect(stripCodeFence('```json\n[1]\n```'), '[1]');
  });

  test('reports every problem with index and field', () {
    final issues = issuesOf('''[
      {"direction":"in","amount":"-5","startDate":"2026-02-30","recurrence":{"mode":"every","interval":0,"unit":"fortnights"}},
      {"direction":"debit","amount":"x","startDate":"2026-01-01","recurrence":{"mode":"once"},"colour":"red"},
      {"direction":"debit","amount":1,"startDate":"2026-05-01","recurrence":{"mode":"every","interval":1,"unit":"days"},
       "end":{"mode":"until_date","endDate":"2026-04-01"},"skippedDates":["nope"]},
      "hello"
    ]''');
    final keys = issues.map((i) => '${i.index}:${i.field}').toSet();
    expect(
        keys,
        containsAll([
          '0:direction',
          '0:amount',
          '0:startDate',
          '0:recurrence.interval',
          '0:recurrence.unit',
          '0:end',
          '1:amount',
          '1:colour',
          '2:end.endDate',
          '2:skippedDates[0]',
          '3:null',
        ]));
    expect(issues.first.toString(), startsWith('[0].direction: '));
  });

  test('rejects duplicate ids, bad ids, bad JSON and empty arrays', () {
    const item =
        '"direction":"debit","amount":1,"startDate":"2026-01-01","recurrence":{"mode":"once"}';
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
    final items = parseImport(
        '[{"direction":"debit","amount":1,"startDate":"2026-01-01",'
        '"recurrence":{"mode":"once"},"end":{"mode":"count","occurrences":3}}]');
    expect(items.single.endMode, EndMode.never);
    expect(items.single.occurrenceCount, isNull);
  });
}
