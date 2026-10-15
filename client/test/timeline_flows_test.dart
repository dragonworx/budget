import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/occurrence_dates.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _today = DateTime.now();
final _day = DateTime(_today.year, _today.month, _today.day);

Account _account() => Account(
  id: 'acc',
  projectId: 'p',
  name: 'Everyday',
  currency: 'AUD',
  seedBalance: Decimal.fromInt(1000),
  seedDate: _day.subtract(const Duration(days: 30)),
  lossThreshold: Decimal.zero,
);

Transaction _tx(String id, String name, {TransactionDirection? dir}) =>
    Transaction(
      id: id,
      accountId: 'acc',
      name: name,
      direction: dir ?? TransactionDirection.debit,
      amount: Decimal.fromInt(id == 'salary' ? 4200 : 50),
      startDate: _day.subtract(const Duration(days: 14)),
      recurrenceMode: RecurrenceMode.every,
      interval: 1,
      unit: RecurrenceUnit.weeks,
      endMode: EndMode.never,
    );

/// In-memory server: transactions, skips and a flat balance.
class _Store {
  final txs = <String, Transaction>{
    'rent': _tx('rent', 'Rent'),
    'salary': _tx('salary', 'Salary', dir: TransactionDirection.credit),
  };
  final skips = <String, Set<DateTime>>{};
  final calls = <String>[];
}

class _AccountRepo extends AccountRepository {
  _AccountRepo(this.s) : super(ApiClient());
  final _Store s;

  @override
  Future<Account> get(String id) async => _account();

  @override
  Future<BalanceSeries> balance(
    String accountId, {
    required DateTime from,
    required DateTime to,
  }) async {
    s.calls.add('balance');
    final points = <BalancePoint>[];
    for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1))) {
      points.add(BalancePoint(date: d, closingBalance: Decimal.fromInt(1000)));
    }
    final occ = <Occurrence>[];
    for (final t in s.txs.values) {
      for (final d in estimateOccurrenceDates(t, maxCount: 400, through: to)) {
        if (d.isBefore(from)) continue;
        final sign = t.direction == TransactionDirection.credit ? 1 : -1;
        occ.add(
          Occurrence(
            transactionId: t.id,
            date: d,
            signedDelta: t.amount * Decimal.fromInt(sign),
            skipped: s.skips[t.id]?.contains(d) ?? false,
          ),
        );
      }
    }
    return BalanceSeries(points: points, occurrences: occ);
  }
}

class _TxRepo extends TransactionRepository {
  _TxRepo(this.s) : super(ApiClient());
  final _Store s;

  @override
  Future<List<Transaction>> listForAccount(String accountId) async =>
      s.txs.values.toList();

  @override
  Future<Transaction> update(Transaction t) async {
    s.calls.add('update ${t.id} ${t.interval} ${t.unit?.name}');
    return s.txs[t.id] = t;
  }

  @override
  Future<Transaction> create(String accountId, Transaction draft) async {
    s.calls.add('create ${draft.name}');
    return s.txs[draft.id] = draft;
  }

  @override
  Future<void> delete(String id) async {
    s.calls.add('delete $id');
    s.txs.remove(id);
  }

  @override
  Future<void> skipOccurrence(
    String transactionId,
    DateTime date, {
    bool skipped = true,
  }) async {
    s.calls.add('skip $transactionId $skipped');
    final set = s.skips.putIfAbsent(transactionId, () => {});
    skipped ? set.add(date) : set.remove(date);
  }
}

Future<_Store> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  // The test font (Ahem) is much wider than the app's fonts.
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = _Store();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(_AccountRepo(store)),
        transactionRepositoryProvider.overrideWithValue(_TxRepo(store)),
      ],
      child: const MaterialApp(home: TimelinePage(accountId: 'acc')),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

/// Simulates the chart reporting a click on [id]'s dot nearest today.
Future<DateTime> _clickDot(WidgetTester tester, String id) async {
  final chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
  final occ = chart.series.occurrences.firstWhere(
    (o) => o.transactionId == id && !o.date.isBefore(_day),
  );
  chart.onOccurrenceTap!([occ]);
  await tester.pumpAndSettle();
  return occ.date;
}

void main() {
  testWidgets('dot click opens that series with the occurrence focused', (
    tester,
  ) async {
    await _pump(tester);
    await _clickDot(tester, 'salary');
    expect(find.byKey(const ValueKey('focus-banner')), findsOneWidget);
    final name = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('editor-name')),
        matching: find.byType(TextField),
      ),
    );
    expect(name.controller!.text, 'Salary');
  });

  testWidgets('editing the frequency saves and refreshes the timeline', (
    tester,
  ) async {
    final store = await _pump(tester);
    await _clickDot(tester, 'rent');
    final balanceCalls = store.calls.where((c) => c == 'balance').length;
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('editor-interval')),
        matching: find.byType(TextField),
      ),
      '2',
    );
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(store.calls, contains('update rent 2 weeks'));
    expect(find.text('Saved “Rent”'), findsOneWidget);
    expect(
      store.calls.where((c) => c == 'balance').length,
      greaterThan(balanceCalls),
    );
    expect(find.byKey(const ValueKey('focus-banner')), findsNothing);
  });

  testWidgets('skip then close reports a skip (not a save) with undo', (
    tester,
  ) async {
    final store = await _pump(tester);
    await _clickDot(tester, 'rent');
    await tester.tap(find.byKey(const ValueKey('skip-occurrence')));
    await tester.pumpAndSettle();
    expect(store.calls, contains('skip rent true'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.textContaining('Skipped'), findsOneWidget);
    expect(find.textContaining('Saved'), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.calls, contains('skip rent false'));
  });

  testWidgets('skip and unskip again reports nothing', (tester) async {
    final store = await _pump(tester);
    await _clickDot(tester, 'rent');
    await tester.tap(find.byKey(const ValueKey('skip-occurrence')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('skip-occurrence')));
    await tester.pumpAndSettle();
    expect(store.calls.where((c) => c.startsWith('skip')), hasLength(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('delete asks to confirm, updates the count, and can be undone', (
    tester,
  ) async {
    final store = await _pump(tester);
    expect(find.text('Transactions · 2'), findsOneWidget);
    await _clickDot(tester, 'rent');
    await tester.tap(find.byKey(const ValueKey('editor-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this series?'), findsOneWidget);
    // Cancelling keeps it.
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(store.calls.where((c) => c.startsWith('delete')), isEmpty);
    await tester.tap(find.byKey(const ValueKey('editor-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(store.calls, contains('delete rent'));
    expect(find.text('Deleted “Rent”'), findsOneWidget);
    expect(find.text('Transactions · 1'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.calls, contains('create Rent'));
    expect(find.text('Transactions · 2'), findsOneWidget);
  });

  testWidgets('unsaved edits ask before discarding', (tester) async {
    await _pump(tester);
    await _clickDot(tester, 'rent');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('editor-name')),
        matching: find.byType(TextField),
      ),
      'Rent (new)',
    );
    await tester.tap(find.byKey(const ValueKey('editor-close')));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-save')), findsOneWidget);
  });

  testWidgets('transactions panel opens the editor in place, back returns', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('open-transactions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salary'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-back')), findsOneWidget);
    // Only one panel route: the list is replaced, not stacked.
    expect(find.byKey(const ValueKey('transactions-search')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('transactions-search')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('transactions-search')), findsNothing);
  });

  testWidgets('new transaction button creates and the count updates', (
    tester,
  ) async {
    final store = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('new-transaction')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('editor-name')),
        matching: find.byType(TextField),
      ),
      'Coffee',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('editor-amount')),
        matching: find.byType(TextField),
      ),
      '4.5',
    );
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(store.calls, contains('create Coffee'));
    expect(find.text('Created “Coffee”'), findsOneWidget);
    expect(find.text('Transactions · 3'), findsOneWidget);
  });
}
