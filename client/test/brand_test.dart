import 'package:budget_client/app.dart';
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/brand/brand.dart';
import 'package:budget_client/brand/landing_intro.dart';
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/auth_repository.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';
import 'support/fake_pools.dart';

final _now = DateTime.now();
final _seed = DateTime(_now.year, _now.month, _now.day - 20);

final _pool = Pool(
  id: 'a',
  ownerId: 'u1',
  name: 'Everyday spending',
  seedBalance: Decimal.parse('1000'),
  seedDate: _seed,
  lossThreshold: Decimal.zero,
  role: Role.owner,
);

class _PoolRepo extends PoolRepository {
  _PoolRepo() : super(ApiClient());

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
  }) async {
    final points = <BalancePoint>[];
    for (
      var d = from.isBefore(_seed) ? _seed : from;
      !d.isAfter(to);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      points.add(BalancePoint(date: d, closingBalance: _pool.seedBalance));
    }
    return BalanceSeries(points: points, occurrences: const []);
  }
}

class _TxRepo extends TransactionRepository {
  _TxRepo() : super(ApiClient());

  @override
  Future<List<Transaction>> listForPool(String poolId) async => const [];
}

Future<void> _pumpTimeline(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      poolRepositoryProvider.overrideWithValue(_PoolRepo()),
      transactionRepositoryProvider.overrideWithValue(_TxRepo()),
    ],
  );
  addTearDown(c.dispose);
  await c.read(authProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: TimelinePage(poolId: 'a')),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpApp(WidgetTester tester, {AuthUser? user}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: user),
        ),
        poolRepositoryProvider.overrideWithValue(FakePoolRepository()),
      ],
      child: const BudgetApp(),
    ),
  );
}

double _opacityOf(WidgetTester tester, Finder anchor) => tester
    .widget<Opacity>(
      find.descendant(of: anchor, matching: find.byType(Opacity)).first,
    )
    .opacity;

void main() {
  setUp(LandingIntro.reset);
  tearDown(() {
    LandingIntro.reset();
    page.prefersReducedMotionForTest = false;
  });

  testWidgets('sign-in shows the stacked lockup (icon, wordmark, tagline)', (
    tester,
  ) async {
    await _pumpApp(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brand-stacked')), findsOneWidget);
    final handle = tester.ensureSemantics();
    await tester.pump();
    expect(
      find.bySemanticsLabel(RegExp('Budgie: tweet your budget right')),
      findsOneWidget,
    );
    handle.dispose();
    expect(find.text('Budget'), findsNothing);
    expect(find.text('Sign in to see your pools'), findsOneWidget);
  });

  for (final width in [320.0, 390.0, 800.0, 1440.0]) {
    testWidgets('timeline header: Budgie icon at the left at ${width}px', (
      tester,
    ) async {
      await _pumpTimeline(tester, Size(width, 800));
      expect(tester.takeException(), isNull);
      final icon = find.byKey(const ValueKey('timeline-brand'));
      expect(icon, findsOneWidget);
      // Icon only: no wordmark in the timeline header.
      expect(find.byKey(const ValueKey('brand-navbar')), findsNothing);
      final r = tester.getRect(icon);
      expect(r.width, width < 600 ? 26 : 32);
      // Left side: right after the back button, before the pool name.
      final back = tester.getRect(find.byKey(const ValueKey('timeline-back')));
      expect(r.left, greaterThanOrEqualTo(back.right - 1));
      expect(r.left, lessThan(back.right + 12));
      final name = tester.getRect(find.text('Everyday spending').first);
      expect(r.right, lessThanOrEqualTo(name.left));
      final bar = tester.getRect(find.byType(AppBar));
      expect(r.top, greaterThan(bar.top));
      expect(r.bottom, lessThan(bar.bottom));
      // The actions keep their room and stay clear of the logo.
      final reminders = tester.getRect(
        find.byKey(const ValueKey('open-reminders')),
      );
      expect(reminders.left - r.right, greaterThan(40));
      final last = tester.getRect(
        find.byKey(
          ValueKey(width < 960 ? 'timeline-more' : 'open-transactions'),
        ),
      );
      expect(last.right, lessThanOrEqualTo(width));
    });
  }

  group('landing intro', () {
    testWidgets('icon large in the centre, coin drops, glides to the header '
        'lockup, then hands over to it; once per load', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      LandingIntro.arm();
      await _pumpApp(tester, user: adminUser);
      await tester.pumpAndSettle();
      final anchor = find.byType(BrandAnchor);
      expect(anchor, findsOneWidget);
      // Armed (boot loader still up): the real logo is hidden.
      expect(_opacityOf(tester, anchor), 0);

      LandingIntro.play();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final overlay = find.byKey(const ValueKey('landing-intro'));
      expect(overlay, findsOneWidget);
      final noCoin = find.descendant(
        of: overlay,
        matching: find.byWidgetPredicate((w) => w is BudgieIcon && w.noCoin),
      );
      final big = tester.getRect(noCoin);
      expect(big.center.dx, closeTo(640, 1));
      expect(big.center.dy, closeTo(400, 1));
      expect(big.width, closeTo(240, 1));

      // Coin: above its resting spot early in the drop, lands in the slot.
      final coin = find.descendant(
        of: overlay,
        matching: find.byType(BudgieCoin),
      );
      final early = tester.getRect(coin).top;
      await tester.pump(const Duration(milliseconds: 500)); // t=900
      final landed = tester.getRect(coin).top;
      expect(early, lessThan(landed - 50));
      expect(landed, closeTo(big.top + 240 * Brand.coinTop, 1));

      // Mid-glide: smaller and on the way to the header icon.
      await tester.pump(const Duration(milliseconds: 475));
      final target = tester.getRect(anchor);
      final mid = tester.getRect(noCoin);
      expect(mid.width, lessThan(240));
      expect(mid.width, greaterThan(target.width));
      expect(mid.center.dx, lessThan(640));
      expect(mid.center.dx, greaterThan(target.center.dx));

      // Done: overlay gone, the real logo shows exactly where it landed.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(overlay, findsNothing);
      expect(_opacityOf(tester, anchor), 1);
      expect(LandingIntro.phase.value, IntroPhase.off);

      // Once per load: arming / playing again does nothing.
      LandingIntro.arm();
      LandingIntro.play();
      await tester.pump();
      expect(overlay, findsNothing);
      expect(_opacityOf(tester, anchor), 1);
    });

    testWidgets('reduced motion skips straight to the end state', (
      tester,
    ) async {
      page.prefersReducedMotionForTest = true;
      LandingIntro.arm();
      await _pumpApp(tester, user: adminUser);
      await tester.pumpAndSettle();
      LandingIntro.play();
      await tester.pump();
      expect(find.byKey(const ValueKey('landing-intro')), findsNothing);
      expect(LandingIntro.phase.value, IntroPhase.off);
      expect(_opacityOf(tester, find.byType(BrandAnchor)), 1);
    });

    testWidgets('MediaQuery.disableAnimations also skips it', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      LandingIntro.arm();
      await _pumpApp(tester, user: adminUser);
      await tester.pumpAndSettle();
      LandingIntro.play();
      await tester.pump();
      expect(find.byKey(const ValueKey('landing-intro')), findsNothing);
      expect(LandingIntro.phase.value, IntroPhase.off);
    });

    testWidgets('a tap skips it; input is only blocked before the glide', (
      tester,
    ) async {
      LandingIntro.arm();
      await _pumpApp(tester, user: adminUser);
      await tester.pumpAndSettle();
      LandingIntro.play();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tapAt(const Offset(20, 300));
      await tester.pump();
      expect(find.byKey(const ValueKey('landing-intro')), findsNothing);
      expect(_opacityOf(tester, find.byType(BrandAnchor)), 1);
    });

    testWidgets('not armed (tests, non-web): nothing hidden, nothing plays', (
      tester,
    ) async {
      await _pumpApp(tester, user: adminUser);
      await tester.pumpAndSettle();
      LandingIntro.play();
      await tester.pump();
      expect(find.byKey(const ValueKey('landing-intro')), findsNothing);
      expect(_opacityOf(tester, find.byType(BrandAnchor)), 1);
    });
  });
}
