// Saved timeline view: reopening a pool restores my last view of it
// (horizontal + balance range), saves are debounced (never per drag
// frame), flushed on page hide, and explicit actions become the new view.
import 'dart:async';

import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/saved_view.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/features/timeline/view_units.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';

final _now = DateTime.now();
final _today = DateTime(_now.year, _now.month, _now.day);
DateTime _d(int o) => DateTime(_today.year, _today.month, _today.day + o);

class _Repo extends PoolRepository {
  _Repo() : super(ApiClient());

  final pools = {
    for (final id in ['a', 'b'])
      id: Pool(
        id: id,
        ownerId: 'u1',
        name: id == 'a' ? 'Everyday' : 'Savings',
        seedBalance: Decimal.parse(id == 'a' ? '1000' : '300'),
        seedDate: _d(-40),
        lossThreshold: Decimal.zero,
        role: Role.owner,
      ),
  };
  final server = <String, SavedView>{};
  final saves = <(String, SavedView, bool)>[];

  /// Completes the server copy of a view later (null: at once).
  Completer<void>? loadGate;

  @override
  Future<PoolList> list() async => PoolList(pools.values.toList());

  @override
  Future<Pool> get(String id) async => pools[id]!;

  @override
  Future<void> markOpened(String id) async {}

  @override
  Future<SavedView?> loadView(String id) async {
    await loadGate?.future;
    return server[id];
  }

  @override
  Future<void> saveView(
    String id,
    SavedView view, {
    bool keepalive = false,
  }) async {
    saves.add((id, view, keepalive));
    server[id] = view;
  }

  @override
  Future<BalanceSeries> balance(
    String poolId, {
    required DateTime from,
    required DateTime to,
  }) async {
    final seed = pools[poolId]!.seedBalance.toDouble();
    return BalanceSeries(
      points: [
        for (
          var d = from;
          !d.isAfter(to);
          d = DateTime(d.year, d.month, d.day + 1)
        )
          BalancePoint(
            date: d,
            closingBalance: Decimal.parse(
              '${seed + (d.difference(_today).inDays * 3)}',
            ),
          ),
      ],
      occurrences: const [],
    );
  }
}

class _TxRepo extends TransactionRepository {
  _TxRepo() : super(ApiClient());
  @override
  Future<List<Transaction>> listForPool(String poolId) async => const [];
}

late _Repo _repo;
late ProviderContainer _c;

Future<void> _open(WidgetTester tester, {String pool = 'a'}) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _c,
      child: MaterialApp(
        home: TimelinePage(key: ValueKey(pool), poolId: pool),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _setUp(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  _repo = _Repo();
  _c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      poolRepositoryProvider.overrideWithValue(_repo),
      transactionRepositoryProvider.overrideWithValue(_TxRepo()),
    ],
  );
  addTearDown(_c.dispose);
  await _c.read(authProvider.future);
}

BalanceChart _chart(WidgetTester t) =>
    t.widget<BalanceChart>(find.byType(BalanceChart));

BalanceExtents _y(WidgetTester t) =>
    (t.state(find.byType(BalanceChart)) as dynamic).debugYRange
        as BalanceExtents;

/// Drags the plot left by [steps] x 12px, one move per frame 50ms apart.
Future<void> _drag(WidgetTester tester, {int steps = 30}) async {
  final c = tester.getCenter(find.byType(BalanceChart));
  final g = await tester.startGesture(c);
  for (var i = 0; i < steps; i++) {
    await g.moveBy(const Offset(-12, 4));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await g.up();
  await tester.pump();
}

({double start, double days, double lo, double hi}) _snap(WidgetTester t) {
  final c = _chart(t);
  final y = _y(t);
  return (
    start: dayCoord(c.viewStart),
    days: c.visibleDays,
    lo: y.min,
    hi: y.max,
  );
}

void main() {
  setUp(page.clearLocal);

  test('SavedView.fromJson validates and clamps', () {
    expect(SavedView.fromJson(null), isNull);
    expect(SavedView.fromJson({'start': 'x', 'days': 3}), isNull);
    final v = SavedView.fromJson({
      'start': 1e12,
      'days': 1e9,
      'unit': 'bogus',
      'yMin': 10,
      'yMax': 2,
    })!;
    expect(v.start, maxSavedStartDay);
    expect(v.days, maxVisibleDays);
    expect(v.unit, isNull);
    expect(v.yRange, isNull); // inverted range dropped: default fit
    final w = SavedView.fromJson({
      'start': 20000.5,
      'days': 0.001,
      'unit': 'year',
      'yMin': -1e30,
      'yMax': 5,
    })!;
    expect(w.days, minVisibleDays);
    expect(w.unit, ViewUnit.year);
    expect(w.yMin, -maxSavedBalance);
  });

  testWidgets('an untouched default view is never saved', (tester) async {
    await _setUp(tester);
    await _open(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(_repo.saves, isEmpty);
    await _open(tester, pool: 'b'); // leave (dispose flush): still nothing
    await tester.pump(const Duration(seconds: 3));
    expect(_repo.saves, isEmpty);
  });

  testWidgets('drag: no save during the frames, one ~1s after it settles; '
      'reopening (and reloading) restores exactly that view', (tester) async {
    await _setUp(tester);
    await _open(tester);
    final before = _snap(tester);
    await _drag(tester); // 1.5s of frames
    expect(_repo.saves, isEmpty, reason: 'never per drag frame');
    final after = _snap(tester);
    expect(after.start, isNot(before.start));
    await tester.pump(const Duration(milliseconds: 900));
    expect(_repo.saves, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_repo.saves, hasLength(1));
    final saved = _repo.saves.single.$2;
    expect(saved.start, closeTo(after.start, 1e-9));
    expect(saved.days, after.days);
    expect((saved.yMin, saved.yMax), (after.lo, after.hi));
    expect(_repo.saves.single.$3, isFalse);

    // Reopen in this browser (local copy): identical, no re-save.
    await _open(tester, pool: 'b');
    await _open(tester);
    final again = _snap(tester);
    expect(again.start, closeTo(after.start, 1e-9));
    expect(again.days, after.days);
    expect((again.lo, again.hi), (after.lo, after.hi));

    // Another device / cleared storage: the server copy restores it.
    page.clearLocal();
    await _open(tester, pool: 'b');
    await _open(tester);
    final remote = _snap(tester);
    expect(remote.start, closeTo(after.start, 1e-9));
    expect((remote.lo, remote.hi), (after.lo, after.hi));
    await tester.pump(const Duration(seconds: 2));
    expect(_repo.saves.where((s) => s.$1 == 'a'), hasLength(1));
  });

  testWidgets('a server copy arriving late restores (unless I moved)', (
    tester,
  ) async {
    await _setUp(tester);
    final view = SavedView(
      start: dayCoord(_d(-200)),
      days: 91.31,
      unit: ViewUnit.quarter,
      yMin: -500,
      yMax: 4000,
    );
    _repo.server['a'] = view;
    _repo.loadGate = Completer<void>();
    await _open(tester);
    // Default first (nothing local yet) ...
    expect(dayCoord(_chart(tester).viewStart), isNot(view.start));
    _repo.loadGate!.complete();
    await tester.pumpAndSettle();
    // ... then the saved view, balance range included, without a refit.
    expect(dayCoord(_chart(tester).viewStart), closeTo(view.start, 1e-9));
    expect(_chart(tester).visibleDays, 91.31);
    expect((_y(tester).min, _y(tester).max), (-500.0, 4000.0));
    await tester.pump(const Duration(seconds: 2));
    expect(_repo.saves, isEmpty, reason: 'a restore is not a change');

    // Moved before the server answers: mine wins.
    _repo.loadGate = Completer<void>();
    page.clearLocal();
    await _open(tester, pool: 'b');
    await _open(tester);
    await _drag(tester, steps: 5);
    final mine = _snap(tester);
    _repo.loadGate!.complete();
    await tester.pumpAndSettle();
    expect(_snap(tester).start, closeTo(mine.start, 1e-9));
  });

  testWidgets('hiding the page saves at once with keepalive', (tester) async {
    await _setUp(tester);
    await _open(tester);
    await _drag(tester, steps: 4);
    expect(_repo.saves, isEmpty);
    page.firePageHidden();
    expect(_repo.saves, hasLength(1));
    expect(_repo.saves.single.$3, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(_repo.saves, hasLength(1), reason: 'pending save was flushed');
  });

  testWidgets('Today (an explicit action) becomes the saved view', (
    tester,
  ) async {
    await _setUp(tester);
    _repo.server['a'] = SavedView(
      start: dayCoord(_d(-400)),
      days: 30.44,
      unit: ViewUnit.month,
      yMin: 0,
      yMax: 100,
    );
    await _open(tester);
    expect(
      dayCoord(_chart(tester).viewStart),
      closeTo(dayCoord(_d(-400)), 1e-9),
    );
    await tester.tap(find.byKey(const ValueKey('go-today')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(_repo.saves, hasLength(1));
    final s = _repo.saves.single.$2;
    expect(s.startDate.isAfter(_d(-3)), isTrue);
    expect(s.yMax, isNot(100), reason: 'Today refits the balance');
  });
}
