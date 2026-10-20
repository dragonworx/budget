// Docked Transactions list: wide landscape screens dock it beside the
// timeline (open by default, remembered), the toolbar button eases it
// in / out without moving the date window or refitting the balance;
// smaller screens keep the overlay panel.
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/features/transactions/transaction_editor.dart';
import 'package:budget_client/features/transactions/transactions_panel.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';

final _now = DateTime.now();
final _today = DateTime(_now.year, _now.month, _now.day);
DateTime _d(int o) => DateTime(_today.year, _today.month, _today.day + o);

final _pool = Pool(
  id: 'a',
  ownerId: 'u1',
  name: 'Everyday',
  seedBalance: Decimal.parse('1000'),
  seedDate: _d(-60),
  lossThreshold: Decimal.zero,
  role: Role.owner,
);

final _txs = [
  Transaction(
    id: 'rent',
    poolId: 'a',
    name: 'Rent',
    direction: TransactionDirection.debit,
    amount: Decimal.parse('500'),
    startDate: _d(40),
    recurrenceMode: RecurrenceMode.once,
    endMode: EndMode.never,
  ),
];

class _Repo extends PoolRepository {
  _Repo() : super(ApiClient());
  @override
  Future<PoolList> list() async => PoolList([_pool]);
  @override
  Future<Pool> get(String id) async => _pool;
  @override
  Future<void> markOpened(String id) async {}
  @override
  Future<BalanceSeries> balance(
    String poolId, {
    required DateTime from,
    required DateTime to,
  }) async => BalanceSeries(
    points: [
      for (
        var d = from;
        !d.isAfter(to);
        d = DateTime(d.year, d.month, d.day + 1)
      )
        BalancePoint(
          date: d,
          closingBalance: Decimal.parse(d.isBefore(_d(40)) ? '1000' : '500'),
        ),
    ],
    occurrences: [
      if (!_d(40).isBefore(from) && !_d(40).isAfter(to))
        Occurrence(
          transactionId: 'rent',
          date: _d(40),
          signedDelta: Decimal.parse('-500'),
        ),
    ],
  );
}

class _TxRepo extends TransactionRepository {
  _TxRepo() : super(ApiClient());
  @override
  Future<List<Transaction>> listForPool(String poolId) async => _txs;
}

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      poolRepositoryProvider.overrideWithValue(_Repo()),
      transactionRepositoryProvider.overrideWithValue(_TxRepo()),
    ],
  );
  addTearDown(c.dispose);
  await c.read(authProvider.future);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: TimelinePage(poolId: 'a')),
    ),
  );
  await tester.pumpAndSettle();
}

final _docked = find.byKey(const ValueKey('docked-transactions'));
Finder get _dockedPanel =>
    find.descendant(of: _docked, matching: find.byType(TransactionsPanel));

({double start, double days, double lo, double hi, double width}) _view(
  WidgetTester t,
) {
  final c = t.widget<BalanceChart>(find.byType(BalanceChart));
  final y =
      (t.state(find.byType(BalanceChart)) as dynamic).debugYRange
          as BalanceExtents;
  return (
    start: dayCoord(c.viewStart),
    days: c.visibleDays,
    lo: y.min,
    hi: y.max,
    width: t.getSize(find.byType(BalanceChart)).width,
  );
}

void main() {
  setUp(() {
    page.clearLocal();
    dockedListEnabled = true;
  });
  tearDown(() => dockedListEnabled = false);

  test('breakpoint and width', () {
    expect(dockedListMinWidth, 1024);
    expect(dockedListWidth(1024), 384);
    expect(dockedListWidth(1180), 384);
    expect(dockedListWidth(1366), closeTo(409.8, 1e-9));
    expect(dockedListWidth(1440), 420);
    expect(dockedListWidth(2560), 420);
  });

  for (final (name, size, kind) in [
    ('1440 desktop', const Size(1440, 900), PointerDeviceKind.mouse),
    (
      '1180x820 landscape tablet',
      const Size(1180, 820),
      PointerDeviceKind.touch,
    ),
  ]) {
    testWidgets('$name: docked open by default; the toolbar button eases it '
        'out / in; the date window and balance range never move; '
        'remembered', (tester) async {
      await _pump(tester, size);
      expect(_dockedPanel, findsOneWidget);
      final panelW = dockedListWidth(size.width);
      expect(tester.getSize(_docked).width, panelW + 16);
      final open = _view(tester);
      expect(open.width, lessThan(size.width - panelW));

      await tester.tap(
        find.byKey(const ValueKey('open-transactions')),
        kind: kind,
      );
      await tester.pump();
      await tester.pump(dockedListDuration ~/ 2);
      final mid = _view(tester);
      // Mid-ease: the timeline is between its two widths (animated, not a
      // jump), same left edge / span / balance range.
      expect(mid.width, greaterThan(open.width + 20));
      expect(mid.width, lessThan(open.width + panelW - 20));
      await tester.pumpAndSettle();
      final closed = _view(tester);
      expect(closed.width, closeTo(open.width + panelW + 16, 1));
      for (final v in [mid, closed]) {
        expect(v.start, open.start, reason: 'left edge stays');
        expect(v.days, open.days, reason: 'same days, new scale');
        expect((v.lo, v.hi), (open.lo, open.hi), reason: 'no refit');
      }
      expect(page.localGet('budget_tx_docked'), '0');
      expect(find.byType(ModalBarrier).evaluate().length, lessThanOrEqualTo(1));

      // Remembered for the next visit (this browser).
      await _pump(tester, size);
      expect(tester.getSize(_docked).width, 0);
      await tester.tap(
        find.byKey(const ValueKey('open-transactions')),
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(_docked).width, panelW + 16);
      expect(page.localGet('budget_tx_docked'), '1');
      // The panel's own hide button does the same.
      await tester.tap(
        find.descendant(
          of: _docked,
          matching: find.byKey(const ValueKey('panel-close')),
        ),
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(_docked).width, 0);
      expect(find.byType(BalanceChart), findsOneWidget, reason: 'no pop');
    });

    testWidgets('$name: Locate from the docked list left-aligns the day and '
        'keeps the list; New ▾ opens the editor in the panel', (tester) async {
      await _pump(tester, size);
      final locate = find.descendant(
        of: _docked,
        matching: find.byTooltip('Show on timeline'),
      );
      if (locate.evaluate().isNotEmpty) {
        await tester.tap(locate, kind: kind);
      } else {
        await tester.tap(
          find.byKey(const ValueKey('row-menu-rent')),
          kind: kind,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show on timeline'), kind: kind);
      }
      await tester.pumpAndSettle();
      final c = tester.widget<BalanceChart>(find.byType(BalanceChart));
      final w = tester.getSize(find.byType(BalanceChart)).width;
      // Left-align rule: the day starts just clear of the left strip.
      final inset = ChartLayout.laneNameWidth(w) * c.visibleDays / w;
      expect(dayCoord(c.viewStart), closeTo(dayCoord(_d(40)) - inset, 0.05));
      expect(_dockedPanel, findsOneWidget);
      expect(tester.getSize(_docked).width, greaterThan(300));

      // New ▾: the main New opens the editor inside the docked panel.
      await tester.tap(
        find.descendant(
          of: _docked,
          matching: find.byKey(const ValueKey('panel-new-transaction')),
        ),
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _docked, matching: find.byType(TransactionEditor)),
        findsOneWidget,
      );
      // ... and its menu offers Plan.
      await tester.tap(
        find.byKey(const ValueKey('editor-close')).first,
        kind: kind,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: _docked,
          matching: find.byKey(const ValueKey('panel-new-menu')),
        ),
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(find.text('Plan'), findsWidgets);
    });
  }

  for (final (name, size) in [
    ('820x1180 portrait tablet', const Size(820, 1180)),
    ('390 phone', const Size(390, 844)),
  ]) {
    testWidgets('$name: no docked list; the button opens the overlay', (
      tester,
    ) async {
      await _pump(tester, size);
      expect(_docked, findsNothing);
      final full = tester.getSize(find.byType(BalanceChart)).width;
      await tester.tap(
        find.byKey(const ValueKey('open-transactions')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(find.byType(TransactionsPanel), findsOneWidget);
      expect(_docked, findsNothing);
      expect(tester.getSize(find.byType(BalanceChart)).width, full);
      await tester.tap(find.byKey(const ValueKey('panel-close')));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionsPanel), findsNothing);
    });
  }
}
