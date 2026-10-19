// Save options in the transaction editor: Save (whole series), Save
// once-off (override one occurrence), From now on (split), and clearing
// overrides back to the natural series value.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/reminders/reminders_model.dart';
import 'package:budget_client/features/timeline/occurrence_info.dart';
import 'package:budget_client/features/transactions/editor_outcome.dart';
import 'package:budget_client/features/transactions/transaction_editor.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2026, 10, 5);
final _focus = DateTime(2026, 10, 19);

Transaction _series({
  Map<DateTime, OccurrenceOverride> overrides = const {},
  RecurrenceMode mode = RecurrenceMode.every,
}) => Transaction(
  id: 't',
  accountId: 'acc',
  name: 'Rent',
  direction: TransactionDirection.debit,
  amount: Decimal.fromInt(100),
  startDate: _start,
  recurrenceMode: mode,
  interval: mode == RecurrenceMode.every ? 1 : null,
  unit: mode == RecurrenceMode.every ? RecurrenceUnit.weeks : null,
  endMode: EndMode.never,
  version: 3,
  overrides: overrides,
);

OccurrenceOverride _o(int amount, [TransactionDirection? d]) =>
    OccurrenceOverride(
      direction: d ?? TransactionDirection.debit,
      amount: Decimal.fromInt(amount),
    );

class _Repo extends TransactionRepository {
  _Repo(this.t) : super(ApiClient());
  Transaction t;
  final calls = <String>[];

  @override
  Future<List<Transaction>> listForAccount(String accountId) async => [t];

  @override
  Future<Transaction> update(Transaction x, {bool force = false}) async {
    calls.add('update ${x.id} ${x.name} ${x.amount} v${x.version}');
    return t = x;
  }

  @override
  Future<Transaction> create(String accountId, Transaction draft) async {
    calls.add('create ${draft.name}');
    return draft;
  }

  @override
  Future<Transaction> setOverride(
    String transactionId,
    DateTime date, {
    required TransactionDirection direction,
    required Decimal amount,
    int? version,
  }) async {
    calls.add(
      'override $transactionId ${formatDate(date)} ${direction.name} '
      '$amount v$version',
    );
    return t = Transaction.fromJson({
      ...t.toJson(),
      'overrides': [
        {
          'date': formatDate(date),
          'direction': direction.name,
          'amount': '$amount',
        },
      ],
    });
  }

  @override
  Future<void> clearOverrides(String transactionId, {DateTime? date}) async {
    calls.add(
      'clear $transactionId ${date == null ? 'all' : formatDate(date)}',
    );
  }

  @override
  Future<({Transaction original, Transaction? created})> split(
    Transaction edited,
    DateTime date, {
    bool force = false,
  }) async {
    calls.add(
      'split ${edited.id} ${formatDate(date)} ${edited.name} '
      '${edited.amount} v${edited.version}',
    );
    return (
      original: t.copyWith(
        endMode: EndMode.untilDate,
        endDate: date.subtract(const Duration(days: 1)),
      ),
      created: edited.copyWith(id: 't2', startDate: date),
    );
  }
}

Future<(_Repo, List<EditorOutcome?>)> _pump(
  WidgetTester tester, {
  Transaction? existing,
  DateTime? focus,
  bool readOnly = false,
  Size size = const Size(1200, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final repo = _Repo(existing ?? _series());
  final outcomes = <EditorOutcome?>[];
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [transactionRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: Scaffold(
          body: TransactionEditor(
            accountId: 'acc',
            existing: repo.t,
            focusDate: focus,
            readOnly: readOnly,
            onDone: outcomes.add,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (repo, outcomes);
}

final _menu = find.byKey(const ValueKey('editor-save-menu'));
final _once = find.byKey(const ValueKey('save-option-once'));
final _forward = find.byKey(const ValueKey('save-option-forward'));
final _seriesOpt = find.byKey(const ValueKey('save-option-series'));

bool _enabled(WidgetTester tester, Finder f) =>
    tester.widget<MenuItemButton>(f).onPressed != null;

Future<void> _open(WidgetTester tester, {PointerDeviceKind? kind}) async {
  await tester.tap(_menu, kind: kind ?? PointerDeviceKind.touch);
  await tester.pumpAndSettle();
}

Future<void> _amount(WidgetTester tester, String v) async {
  await tester.enterText(find.byKey(const ValueKey('editor-amount')), v);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dropdown shows only on an occurrence of a repeating series', (
    tester,
  ) async {
    // No occurrence context: plain Save.
    await _pump(tester);
    expect(find.byKey(const ValueKey('editor-save')), findsOneWidget);
    expect(_menu, findsNothing);
    // Once-only transaction on its date: plain Save.
    await _pump(
      tester,
      existing: _series(mode: RecurrenceMode.once),
      focus: _start,
    );
    expect(_menu, findsNothing);
    // New transaction: no dropdown.
    tester.view.physicalSize = const Size(1200, 1600);
    // Viewers: no save at all.
    await _pump(tester, focus: _focus, readOnly: true);
    expect(find.byKey(const ValueKey('editor-save')), findsNothing);
    expect(_menu, findsNothing);
    // Repeating series opened on a dot: split button with a tooltip.
    await _pump(tester, focus: _focus);
    expect(_menu, findsOneWidget);
    expect(find.byTooltip('More save options'), findsOneWidget);
    await _open(tester);
    expect(_seriesOpt, findsOneWidget);
    expect(_once, findsOneWidget);
    expect(_forward, findsOneWidget);
    // Nothing edited yet: only Save applies, with hints why.
    expect(_enabled(tester, _seriesOpt), isTrue);
    expect(_enabled(tester, _once), isFalse);
    expect(_enabled(tester, _forward), isFalse);
    expect(find.text('Change the amount first'), findsOneWidget);
    expect(find.text('Change something first'), findsOneWidget);
  });

  testWidgets('Save once-off overrides only that date (touch, phone)', (
    tester,
  ) async {
    final (repo, outcomes) = await _pump(
      tester,
      focus: _focus,
      size: const Size(390, 844),
    );
    await _amount(tester, '250');
    await _open(tester);
    expect(_enabled(tester, _once), isTrue);
    expect(
      find.text('Only ${formatOccurrenceDate(_focus)} (amount)'),
      findsOneWidget,
    );
    await tester.tap(_once);
    await tester.pumpAndSettle();
    expect(repo.calls, ['override t 2026-10-19 debit 250 v3']);
    expect(outcomes.single!.action, EditorAction.overridden);
    expect(outcomes.single!.date, _focus);
    expect(
      describeOutcome(outcomes.single),
      'Changed “Rent” on ${formatOccurrenceDate(_focus)} only',
    );
  });

  testWidgets('once-off is blocked when other fields changed', (tester) async {
    final (repo, _) = await _pump(tester, focus: _focus);
    await _amount(tester, '250');
    await tester.enterText(find.byKey(const ValueKey('editor-name')), 'Other');
    await tester.pumpAndSettle();
    await _open(tester, kind: PointerDeviceKind.mouse);
    expect(_enabled(tester, _once), isFalse);
    expect(
      find.text('Only the amount can change for one date'),
      findsOneWidget,
    );
    expect(_enabled(tester, _forward), isTrue);
    expect(repo.calls, isEmpty);
  });

  testWidgets('From now on splits at the occurrence (mouse, desktop)', (
    tester,
  ) async {
    final (repo, outcomes) = await _pump(tester, focus: _focus);
    await _amount(tester, '150');
    await _open(tester, kind: PointerDeviceKind.mouse);
    expect(
      find.text(
        '${formatOccurrenceDate(_focus)} onwards; earlier dates keep the old values',
      ),
      findsOneWidget,
    );
    await tester.tap(_forward, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(repo.calls, ['split t 2026-10-19 Rent 150 v3']);
    final o = outcomes.single!;
    expect(o.action, EditorAction.split);
    expect(o.transaction.id, 't2');
    expect(o.original!.endDate, DateTime(2026, 10, 18));
    expect(
      describeOutcome(o),
      'Changed “Rent” from ${formatOccurrenceDate(_focus)} on',
    );
  });

  testWidgets('From now on at the first occurrence is a plain Save', (
    tester,
  ) async {
    final (repo, outcomes) = await _pump(tester, focus: _start);
    await _amount(tester, '150');
    await _open(tester);
    expect(find.text('First occurrence: same as Save'), findsOneWidget);
    await tester.tap(_forward);
    await tester.pumpAndSettle();
    expect(repo.calls, ['update t Rent 150 v3']);
    expect(outcomes.single!.action, EditorAction.saved);
  });

  testWidgets('From now on is blocked for start / end changes', (tester) async {
    await _pump(tester, focus: _focus);
    // Switch the end condition to "After…" a count.
    final after = find.text('After…');
    await tester.ensureVisible(after);
    await tester.tap(after);
    await tester.pumpAndSettle();
    await _open(tester);
    expect(_enabled(tester, _forward), isFalse);
    expect(
      find.text('Start, end and transfer changes need Save'),
      findsOneWidget,
    );
    expect(_enabled(tester, _seriesOpt), isTrue);
  });

  testWidgets('the main Save click still saves the whole series', (
    tester,
  ) async {
    final (repo, outcomes) = await _pump(tester, focus: _focus);
    await _amount(tester, '120');
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['update t Rent 120 v3']);
    expect(outcomes.single!.action, EditorAction.saved);
  });

  testWidgets('overridden occurrence: banner shows both values; reset clears', (
    tester,
  ) async {
    final (repo, outcomes) = await _pump(
      tester,
      existing: _series(overrides: {_focus: _o(250)}),
      focus: _focus,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('focus-banner-detail')))
          .data,
      'Once-off −\$250 on this date · series −\$100',
    );
    expect(find.text('Reset to series −\$100'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chip-override-2026-10-19')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('editor-clear-override')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['clear t 2026-10-19']);
    final o = outcomes.single!;
    expect(o.action, EditorAction.overrideCleared);
    expect(
      describeOutcome(o),
      'Reset “Rent” on ${formatOccurrenceDate(_focus)} to the series',
    );
  });

  testWidgets('once-off back to the series value clears the override', (
    tester,
  ) async {
    final (repo, outcomes) = await _pump(
      tester,
      existing: _series(overrides: {_focus: _o(250)}),
      focus: _focus,
    );
    // The form holds the series value (100); once-off with it = reset.
    await _open(tester);
    expect(_enabled(tester, _once), isTrue);
    await tester.tap(_once);
    await tester.pumpAndSettle();
    expect(repo.calls, ['clear t 2026-10-19']);
    expect(outcomes.single!.action, EditorAction.overrideCleared);
  });

  testWidgets('clear all overrides shows the count and confirms', (
    tester,
  ) async {
    final (repo, outcomes) = await _pump(
      tester,
      existing: _series(
        overrides: {_focus: _o(250), DateTime(2026, 10, 26): _o(5)},
      ),
      focus: _focus,
    );
    final clearAll = find.byKey(const ValueKey('editor-clear-overrides'));
    await tester.ensureVisible(clearAll);
    expect(find.text('2 once-off overrides on single dates'), findsOneWidget);
    await tester.tap(clearAll);
    await tester.pumpAndSettle();
    expect(find.text('Clear 2 once-off overrides?'), findsOneWidget);
    // Cancel first: nothing happens.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(repo.calls, isEmpty);
    await tester.tap(clearAll);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pumpAndSettle();
    expect(repo.calls, ['clear t all']);
    expect(outcomes.single!.action, EditorAction.overridesCleared);
    expect(
      describeOutcome(outcomes.single),
      'Cleared 2 once-off overrides · “Rent”',
    );
  });

  testWidgets('viewers see overrides but cannot clear them', (tester) async {
    final (repo, _) = await _pump(
      tester,
      existing: _series(overrides: {_focus: _o(250)}),
      focus: _focus,
      readOnly: true,
    );
    expect(find.textContaining('Once-off −\$250'), findsWidgets);
    expect(find.byKey(const ValueKey('editor-clear-override')), findsNothing);
    expect(find.byKey(const ValueKey('editor-clear-overrides')), findsNothing);
    expect(find.text('1 once-off override on single dates'), findsOneWidget);
    expect(repo.calls, isEmpty);
  });

  test('model: overrides parse and set the occurrence amount', () {
    final t = Transaction.fromJson({
      ..._series().toJson(),
      'overrides': [
        {'date': '2026-10-19', 'direction': 'credit', 'amount': '30'},
      ],
    });
    expect(
      t.overrideOn(DateTime(2026, 10, 19)),
      _o(30, TransactionDirection.credit),
    );
    expect(t.signedAmountOn(DateTime(2026, 10, 19)), Decimal.fromInt(30));
    expect(t.signedAmountOn(DateTime(2026, 10, 12)), Decimal.fromInt(-100));
    expect(t.copyWith(name: 'x').overrides, t.overrides);
  });

  test('reminders use the once-off amount for that date', () {
    final t = _series(overrides: {_focus: _o(250)});
    final items = expandOccurrences(
      [t],
      from: DateTime(2026, 10, 12),
      to: DateTime(2026, 10, 26),
    );
    expect(
      [for (final i in items) i.signed.toString()],
      ['-100', '-250', '-100'],
    );
    final day = DayTotals.of(items.where((i) => i.date == _focus));
    expect(day.losses, Decimal.fromInt(250));
    final credit = _series(
      overrides: {_focus: _o(40, TransactionDirection.credit)},
    );
    final i = expandOccurrences([credit], from: _focus, to: _focus).single;
    expect(i.isGain, isTrue);
    expect(DayTotals.of([i]).gains, Decimal.fromInt(40));
  });
}
