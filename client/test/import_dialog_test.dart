import 'dart:convert';

import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/import_dialog.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records calls; dry runs answer [preview] (or throw [error]).
class _Repo extends EventRepository {
  _Repo() : super(ApiClient());
  final calls = <String>[];
  Map<String, dynamic> Function(String raw) preview = (_) => {};
  Object? error;

  @override
  Future<Map<String, dynamic>> import(
    String streamId,
    String raw, {
    required DateTime root,
    bool dryRun = false,
  }) async {
    calls.add('import ${importRootParam(root)} dryRun=$dryRun $raw');
    if (error != null) throw error!;
    if (dryRun) return preview(raw);
    return {
      'created': 2,
      'skipped': 1,
      'createdIds': ['a', 'b'],
    };
  }
}

Map<String, dynamic> _item(
  String name, {
  String start = '2026-10-22',
  String dir = 'debit',
  num amount = 10,
  String mode = 'once',
  int? interval,
  String? unit,
  String endMode = 'never',
  String? endDate,
  int? count,
  bool exists = false,
}) => {
  'name': name,
  'startDate': start,
  'direction': dir,
  'amount': amount,
  'recurrenceMode': mode,
  'interval': ?interval,
  'unit': ?unit,
  'endMode': endMode,
  'endDate': ?endDate,
  'occurrenceCount': ?count,
  'exists': exists,
  'skippedDates': const [],
  'enabled': true,
};

String? _clip;
Object? _clipError;

void _mockClipboard(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method != 'Clipboard.getData') return null;
      if (_clipError != null) throw _clipError!;
      return _clip == null ? null : {'text': _clip};
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

Future<(_Repo, List<ImportResult?>)> _open(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _clip = null;
  _clipError = null;
  _mockClipboard(tester);
  final repo = _Repo();
  final results = <ImportResult?>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [eventRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => results.add(
                  await showImportDialog(
                    context,
                    streamId: 'p1',
                    root: DateTime(2026, 10, 22),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (repo, results);
}

final _paste = find.byKey(const ValueKey('import-paste'));
final _confirm = find.byKey(const ValueKey('import-confirm'));

Future<void> _tapPaste(WidgetTester tester) async {
  await tester.tap(_paste);
  await tester.pumpAndSettle();
}

bool _enabled(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(_confirm).onPressed != null;

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  testWidgets('no tip text or text field: just Paste; Import disabled', (
    tester,
  ) async {
    await _open(tester);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(EditableText), findsNothing);
    expect(find.textContaining('JSON array'), findsNothing);
    expect(_paste, findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);
    expect(_enabled(tester), isFalse);
    expect(find.byKey(const ValueKey('import-preview')), findsNothing);
  });

  testWidgets('Paste previews one row per event (recurring once)', (
    tester,
  ) async {
    final (repo, results) = await _open(tester);
    _clip = '[pasted]';
    repo.preview = (_) => {
      'items': [
        _item('Bonus', dir: 'credit', amount: 1250.5),
        _item(
          'Rent',
          start: '2026-10-25',
          amount: 400,
          mode: 'repeat',
          interval: 1,
          unit: 'weeks',
          endMode: 'count',
          count: 12,
        ),
        _item(
          'Gym',
          start: '2026-11-01',
          amount: 30,
          mode: 'repeat',
          interval: 1,
          unit: 'months',
          endMode: 'until_date',
          endDate: '2027-06-01',
          exists: true,
        ),
      ],
      'toCreate': 2,
      'toSkip': 1,
    };
    await _tapPaste(tester);
    expect(repo.calls, ['import 2026-10-22 dryRun=true [pasted]']);
    expect(find.byKey(const ValueKey('import-preview-table')), findsOneWidget);
    // Exactly three rows: the weekly Rent is not expanded per occurrence.
    expect(find.byKey(const ValueKey('import-row-2-date')), findsOneWidget);
    expect(find.byKey(const ValueKey('import-row-3-date')), findsNothing);
    expect(find.text('Rent'), findsOneWidget);
    expect(_text(tester, 'import-row-0-date'), 'Thu 22 Oct 2026');
    expect(_text(tester, 'import-row-1-date'), 'Sun 25 Oct 2026');
    expect(_text(tester, 'import-row-0-name'), 'Bonus');
    expect(_text(tester, 'import-row-0-frequency'), 'Once');
    expect(_text(tester, 'import-row-1-frequency'), 'Weekly');
    expect(_text(tester, 'import-row-2-frequency'), 'Monthly');
    expect(find.textContaining('12 times'), findsOneWidget);
    expect(find.textContaining('until 1 Jun 2027'), findsOneWidget);
    expect(find.textContaining('already exists'), findsOneWidget);
    final bonus = tester.widget<Text>(
      find.byKey(const ValueKey('import-row-0-amount')),
    );
    expect(bonus.data, '+\$1,251');
    expect(bonus.style!.color, AppTheme.creditColor);
    final rent = tester.widget<Text>(
      find.byKey(const ValueKey('import-row-1-amount')),
    );
    expect(rent.data, contains('400'));
    expect(rent.style!.color, AppTheme.debitColor);
    expect(find.text('Import 2'), findsOneWidget);
    expect(find.text('Paste again'), findsOneWidget);
    expect(_enabled(tester), isTrue);

    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'import 2026-10-22 dryRun=false [pasted]');
    expect(results.single!.created, 2);
    expect(results.single!.createdIds, ['a', 'b']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the preview table scrolls on a phone', (tester) async {
    final (repo, _) = await _open(tester, size: const Size(402, 874));
    _clip = 'many';
    repo.preview = (_) => {
      'items': [
        for (var i = 0; i < 40; i++)
          _item(
            'Item $i',
            start: '2026-11-${(i % 28 + 1).toString().padLeft(2, '0')}',
          ),
      ],
      'toCreate': 40,
    };
    await _tapPaste(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Import 40'), findsOneWidget);
    final scroll = find.byKey(const ValueKey('import-preview-scroll'));
    expect(tester.getSize(scroll).height, lessThanOrEqualTo(874 * 0.5 + 1));
    expect(find.text('Item 39').hitTestable(), findsNothing);
    await tester.drag(scroll, const Offset(0, -3000));
    await tester.pumpAndSettle();
    // All four columns fit a phone's width: no sideways scrolling.
    final view = tester.getRect(scroll);
    for (final k in ['date', 'name', 'amount', 'frequency']) {
      final r = tester.getRect(find.byKey(ValueKey('import-row-39-$k')));
      expect(r.left, greaterThanOrEqualTo(view.left), reason: k);
      expect(r.right, lessThanOrEqualTo(view.right), reason: k);
    }
    expect(find.text('Item 39').hitTestable(), findsOneWidget);
    // The Import button stays on screen.
    expect(_confirm.hitTestable(), findsOneWidget);
  });

  testWidgets('Paste again replaces the preview', (tester) async {
    final (repo, _) = await _open(tester);
    _clip = 'first';
    repo.preview = (raw) => {
      'items': raw == 'first' ? [_item('One'), _item('Two')] : [_item('Three')],
    };
    await _tapPaste(tester);
    expect(find.text('Import 2'), findsOneWidget);
    _clip = 'second';
    await _tapPaste(tester);
    expect(find.text('One'), findsNothing);
    expect(find.text('Three'), findsOneWidget);
    expect(find.text('Import 1'), findsOneWidget);
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'import 2026-10-22 dryRun=false second');
  });

  testWidgets('an empty clipboard is reported inline, no preview', (
    tester,
  ) async {
    final (repo, _) = await _open(tester);
    _clip = '  ';
    await _tapPaste(tester);
    expect(find.byKey(const ValueKey('import-error')), findsOneWidget);
    expect(find.textContaining('clipboard is empty'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-preview')), findsNothing);
    expect(repo.calls, isEmpty);
    expect(_enabled(tester), isFalse);
  });

  testWidgets('a clipboard failure is reported inline, no preview', (
    tester,
  ) async {
    final (repo, _) = await _open(tester);
    _clipError = PlatformException(code: 'denied', message: 'NotAllowed');
    await _tapPaste(tester);
    expect(find.textContaining('Couldn’t read the clipboard'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-preview')), findsNothing);
    expect(repo.calls, isEmpty);
    expect(_enabled(tester), isFalse);
  });

  testWidgets('server validation errors replace the preview, Import off', (
    tester,
  ) async {
    final (repo, _) = await _open(tester);
    _clip = 'ok';
    repo.preview = (_) => {
      'items': [_item('Fine')],
    };
    await _tapPaste(tester);
    expect(_enabled(tester), isTrue);
    _clip = 'bad';
    repo.error = ApiException(
      'Invalid import',
      statusCode: 400,
      body: jsonEncode({
        'error': 'Invalid import',
        'details': [
          {'text': '[0] startDate: use startOffset (days from the root)'},
          {'text': '[1] startOffset: must be a whole number'},
        ],
      }),
    );
    await _tapPaste(tester);
    expect(find.byKey(const ValueKey('import-preview')), findsNothing);
    expect(find.text('Fine'), findsNothing);
    expect(find.textContaining('use startOffset'), findsOneWidget);
    expect(find.textContaining('must be a whole number'), findsOneWidget);
    expect(_enabled(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  test('importFrequency uses the editor wording', () {
    expect(importFrequency(_item('a')), ('Once', null));
    Map<String, dynamic> rep(int n, String unit, {String end = 'never'}) =>
        _item('a', mode: 'repeat', interval: n, unit: unit, endMode: end);
    expect(importFrequency(rep(1, 'days')).$1, 'Daily');
    expect(importFrequency(rep(2, 'weeks')).$1, 'Fortnightly');
    expect(importFrequency(rep(3, 'months')).$1, 'Quarterly');
    expect(importFrequency(rep(1, 'years')).$1, 'Yearly');
    expect(importFrequency(rep(5, 'days')).$1, 'Every 5 days');
    expect(
      importFrequency(
        _item(
          'a',
          mode: 'repeat',
          interval: 1,
          unit: 'months',
          endMode: 'count',
          count: 6,
        ),
      ),
      ('Monthly', '6 times'),
    );
  });

  test('importFrequency: a structured rule with days reads as its phrase', () {
    Map<String, dynamic> rule(String r, int n, List<int> days) => {
      ..._item('a', mode: 'repeat', interval: n, unit: 'weeks'),
      'frequency': {'rule': r, 'interval': n, 'days': days},
      'days': days,
    };
    expect(
      importFrequency(rule('weekly', 1, [2, 1])).$1,
      'Every week on Mon, Tue',
    );
    expect(
      importFrequency(rule('monthly', 1, [15, 1])).$1,
      'Monthly on the 1st and 15th',
    );
    expect(
      importFrequency(rule('every_n_months', 3, [31])).$1,
      'Every 3 months on the 31st',
    );
    // No days: the editor wording stays.
    expect(importFrequency(rule('every_n_weeks', 2, [])).$1, 'Fortnightly');
  });
}
