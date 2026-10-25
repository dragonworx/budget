// Docked Events list: wide landscape screens dock it beside the
// timeline (open by default, remembered), the toolbar button eases it
// in / out without moving the date window or refitting the balance;
// smaller screens keep the overlay panel.
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/dock_split.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/features/events/events_panel.dart';
import 'package:budget_client/state/app_prefs.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/theme/app_theme.dart';
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

final _stream = BudgetStream(
  id: 'a',
  ownerId: 'u1',
  name: 'Everyday',
  seedBalance: Decimal.parse('1000'),
  seedDate: _d(-60),
  lossThreshold: Decimal.zero,
  role: Role.owner,
);

final _txs = [
  BudgetEvent(
    id: 'rent',
    streamId: 'a',
    name: 'Rent',
    direction: EventDirection.debit,
    amount: Decimal.parse('500'),
    startDate: _d(40),
    recurrenceMode: RecurrenceMode.once,
    endMode: EndMode.never,
  ),
];

class _Repo extends StreamRepository {
  _Repo() : super(ApiClient());
  @override
  Future<StreamList> list() async => StreamList([_stream]);
  @override
  Future<BudgetStream> get(String id) async => _stream;
  @override
  Future<void> markOpened(String id) async {}
  @override
  Future<BalanceSeries> balance(
    String streamId, {
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
          eventId: 'rent',
          date: _d(40),
          signedDelta: Decimal.parse('-500'),
        ),
    ],
  );
}

class _TxRepo extends EventRepository {
  _TxRepo() : super(ApiClient());
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => _txs;
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
      streamRepositoryProvider.overrideWithValue(_Repo()),
      eventRepositoryProvider.overrideWithValue(_TxRepo()),
    ],
  );
  addTearDown(c.dispose);
  await c.read(authProvider.future);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: TimelinePage(streamId: 'a')),
    ),
  );
  await tester.pumpAndSettle();
}

final _docked = find.byKey(const ValueKey('docked-events'));
Finder get _dockedPanel =>
    find.descendant(of: _docked, matching: find.byType(EventsPanel));

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
      // Docked too, the chart fills the height under the header: no date
      // range / heat map row, no tips row.
      final bar = tester.getRect(find.byType(AppBar));
      final chartR = tester.getRect(find.byType(BalanceChart));
      expect(chartR.top - bar.bottom, inInclusiveRange(0, 14));
      expect(size.height - chartR.bottom, inInclusiveRange(0, 14));
      expect(find.byKey(const ValueKey('jump-to-date')), findsNothing);
      expect(find.textContaining('for actions'), findsNothing);
      final panelW = dockedListWidth(size.width);
      expect(tester.getSize(_docked).width, panelW + 16);
      final open = _view(tester);
      expect(open.width, lessThan(size.width - panelW));
      // Open state: the plain list icon is tinted accent (no fill/border).
      Color? txColor() => tester
          .widget<IconButton>(find.byKey(const ValueKey('open-events')))
          .color;
      expect(txColor(), AppTheme.accent);

      await tester.tap(find.byKey(const ValueKey('open-events')), kind: kind);
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
      expect(txColor(), isNull, reason: 'closed: default icon colour');
      for (final v in [mid, closed]) {
        expect(v.start, open.start, reason: 'left edge stays');
        expect(v.days, open.days, reason: 'same days, new scale');
        expect((v.lo, v.hi), (open.lo, open.hi), reason: 'no refit');
      }
      expect(page.localGet('budget_events_docked'), '0');
      expect(find.byType(ModalBarrier).evaluate().length, lessThanOrEqualTo(1));

      // Remembered for the next visit (this browser).
      await _pump(tester, size);
      expect(tester.getSize(_docked).width, 0);
      await tester.tap(find.byKey(const ValueKey('open-events')), kind: kind);
      await tester.pumpAndSettle();
      expect(tester.getSize(_docked).width, panelW + 16);
      expect(page.localGet('budget_events_docked'), '1');
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

    testWidgets('$name: rows have no Show on timeline (a row opens the '
        'editor in the panel), show the start date; New ▾ opens the editor '
        'in the panel', (tester) async {
      await _pump(tester, size);
      expect(find.byTooltip('Show on timeline'), findsNothing);
      expect(find.text('Show on timeline'), findsNothing);
      expect(find.byIcon(Icons.my_location_rounded), findsNothing);
      final before = _view(tester);
      await tester.tap(
        find.descendant(of: _docked, matching: find.text('Rent')),
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _docked, matching: find.byType(EventEditor)),
        findsOneWidget,
      );
      expect(_view(tester).start, before.start, reason: 'view unchanged');
      await tester.tap(
        find.byKey(const ValueKey('editor-close')).first,
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(_dockedPanel, findsOneWidget);
      expect(tester.getSize(_docked).width, greaterThan(300));

      // New ▾: the main New opens the editor inside the docked panel.
      await tester.tap(
        find.descendant(
          of: _docked,
          matching: find.byKey(const ValueKey('panel-new-event')),
        ),
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _docked, matching: find.byType(EventEditor)),
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
        find.byKey(const ValueKey('open-events')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(find.byType(EventsPanel), findsOneWidget);
      expect(_docked, findsNothing);
      expect(tester.getSize(find.byType(BalanceChart)).width, full);
      await tester.tap(find.byKey(const ValueKey('panel-close')));
      await tester.pumpAndSettle();
      expect(find.byType(EventsPanel), findsNothing);
    });
  }

  group('splitter', () {
    final split = find.byKey(const ValueKey('dock-splitter'));
    double panelW(WidgetTester t) => t.getSize(_dockedPanel).width;
    String? saved() =>
        page.localGet('${AppPrefs.prefix}${PrefKeys.dockedListWidth}');

    test('limits and the stored width (px, clamped to the window)', () {
      expect(dockedListMinDrag, 280);
      expect(dockedListMaxWidth(1440), 864);
      expect(dockedListMaxWidth(1024), 464);
      expect(dockedListEffectiveWidth(1440, null), 420);
      expect(dockedListEffectiveWidth(1440, 620), 620);
      expect(dockedListEffectiveWidth(1100, 620), 540);
      expect(dockedListEffectiveWidth(1440, 100), 280);
      expect(dockedListEffectiveWidth(1440, 5000), 864);
      const prefs = AppPrefs();
      prefs.setDouble('x', 1.5);
      expect(page.localGet('budgie.prefs.v1.x'), '1.5');
      expect(prefs.getDouble('x'), 1.5);
      page.localSet('budgie.prefs.v1.x', 'NaN');
      expect(prefs.getDouble('x'), isNull);
      prefs.remove('x');
      expect(prefs.getString('x'), isNull);
      prefs.setBool('b', true);
      expect(prefs.getBool('b'), isTrue);
    });

    for (final (name, size, kind) in [
      ('1440 mouse', const Size(1440, 900), PointerDeviceKind.mouse),
      ('1180x820 touch', const Size(1180, 820), PointerDeviceKind.touch),
    ]) {
      testWidgets('$name: dragging resizes the list (the timeline keeps its '
          'date window, no day picked); saved; a reload restores it; '
          'hide / show restores it; double-tap resets', (tester) async {
        await _pump(tester, size);
        final w0 = panelW(tester);
        expect(w0, dockedListWidth(size.width));
        final before = _view(tester);
        // The splitter sits in the gap, left of the list.
        final sr = tester.getRect(split);
        final pr = tester.getRect(_dockedPanel);
        expect(sr.width, 24);
        expect(sr.center.dx, closeTo(pr.left - 8, 0.5));
        final chartR = tester.getRect(find.byType(BalanceChart));
        expect(chartR.right, lessThanOrEqualTo(sr.left + 4 + 1));

        final g = await tester.startGesture(sr.center, kind: kind);
        for (var i = 0; i < 10; i++) {
          await g.moveBy(const Offset(-15, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        // Live while dragging, not saved until release.
        expect(panelW(tester), closeTo(w0 + 150, 0.5));
        expect(saved(), isNull);
        await g.up();
        await tester.pumpAndSettle();
        expect(panelW(tester), closeTo(w0 + 150, 0.5));
        expect(double.parse(saved()!), closeTo(w0 + 150, 0.5));
        final after = _view(tester);
        expect(after.start, before.start, reason: 'left edge stays');
        expect(after.days, before.days, reason: 'same days, new scale');
        expect(after.width, closeTo(before.width - 150, 1));
        expect(find.byKey(const ValueKey('selection-band')), findsNothing);
        expect(
          find.byTooltip(RegExp(r'^Add an event on ').pattern),
          findsNothing,
        );
        expect(find.byType(EventEditor), findsNothing);

        // Reload: restored from the app prefs.
        await _pump(tester, size);
        expect(panelW(tester), closeTo(w0 + 150, 0.5));
        // Hide / show eases back to the saved width.
        await tester.tap(find.byKey(const ValueKey('open-events')), kind: kind);
        await tester.pumpAndSettle();
        expect(tester.getSize(_docked).width, 0);
        expect(split, findsNothing);
        await tester.tap(find.byKey(const ValueKey('open-events')), kind: kind);
        await tester.pump();
        await tester.pump(dockedListDuration ~/ 2);
        final midW = tester.getSize(_docked).width;
        expect(midW, greaterThan(20));
        expect(midW, lessThan(w0 + 150 + 16 - 20));
        await tester.pumpAndSettle();
        expect(panelW(tester), closeTo(w0 + 150, 0.5));

        // Double-tap: back to the default; the saved width goes.
        final c = tester.getCenter(split);
        await tester.tapAt(c, kind: kind);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(c, kind: kind);
        await tester.pumpAndSettle();
        expect(panelW(tester), w0);
        expect(saved(), isNull);
      });
    }

    testWidgets('clamps: min 280, the timeline keeps its room; a narrower '
        'window clamps without forgetting the chosen width', (tester) async {
      await _pump(tester, const Size(1440, 900));
      Future<void> drag(double dx) async {
        await tester.drag(split, Offset(dx, 0), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
      }

      await drag(600);
      expect(panelW(tester), 280);
      final e = tester.takeException();
      expect(e, isNull, reason: 'at 280');
      await drag(-2000);
      expect(panelW(tester), 864);
      expect(
        tester.getSize(find.byType(BalanceChart)).width,
        greaterThan(1440 - 864 - 80),
      );
      // Narrower window (still docked): clamped, the choice is kept.
      tester.view.physicalSize = const Size(1100, 800);
      await tester.pumpAndSettle();
      expect(panelW(tester), 540);
      expect(tester.takeException(), isNull, reason: 'at 1100');
      expect(saved(), '864.0');
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();
      expect(panelW(tester), 864);
      // Too narrow to dock: the overlay takes over (no splitter).
      tester.view.physicalSize = const Size(1000, 800);
      await tester.pumpAndSettle();
      expect(_docked, findsNothing);
      expect(split, findsNothing);
    });
  });
}
