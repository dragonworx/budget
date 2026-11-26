import 'dart:async';

import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/category_charts_sheet.dart';
import 'package:budget_client/features/timeline/category_totals.dart';
import 'package:budget_client/features/timeline/date_range.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:clock/clock.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BudgetEvent _event(String id, String cat) => BudgetEvent(
  id: id,
  streamId: 's',
  name: id,
  direction: EventDirection.debit,
  amount: Decimal.fromInt(1),
  startDate: DateTime(2026, 11, 1),
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
  categoryId: cat,
);

Category _cat(String id, String name, String color) =>
    Category(id: id, streamId: 's', name: name, color: color);

Occurrence _o(String id, int cents) => Occurrence(
  eventId: id,
  date: DateTime(2026, 11, 10),
  signedDelta: Decimal.fromInt(cents).shift(-2),
);

CategoryTotals fixtureTotals() => summarizeCategories(
  occurrences: [
    _o('g', -6000),
    _o('r', -2500),
    _o('t', -1300),
    _o('s', -100),
    _o('pay', 8000),
  ],
  start: DateTime(2026, 11, 1),
  end: DateTime(2026, 11, 30),
  events: {
    'g': _event('g', 'groc'),
    'r': _event('r', 'rent'),
    't': _event('t', 'tran'),
    's': _event('s', 'snack'),
    'pay': _event('pay', 'sal'),
  },
  categories: [
    _cat('groc', 'Groceries', '#4CAF50'),
    _cat('rent', 'Rent', '#2196F3'),
    _cat('tran', 'Transport', '#FF9800'),
    _cat('snack', 'Snacks', '#9C27B0'),
    _cat('sal', 'Salary', '#FFC107'),
  ],
);

final ThemeData testTheme = runZonedGuarded(AppTheme.dark, (_, _) {})!;

Future<void> pumpSheet(
  WidgetTester tester, {
  required double width,
  required double height,
  required CategoryTotals totals,
  DateRange? range,
  bool hasEvents = true,
  ValueChanged<DateRange>? onChanged,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  DateRange current =
      range ??
      withClock(Clock.fixed(DateTime(2026, 11, 26)), () {
        return DateRange.fromPreset(DateRangePreset.thisMonth);
      });
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme,
      home: Scaffold(
        body: CategoryChartsView(
          range: current,
          onRangeChanged: onChanged ?? (_) {},
          totals: totals,
          hasEvents: hasEvents,
          onClose: () {},
          showHandle: width < 600,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(page.clearLocal);

  testWidgets('sheet at 320: preset next to pie/bar, no overflow', (
    tester,
  ) async {
    await pumpSheet(tester, width: 320, height: 640, totals: fixtureTotals());
    expect(tester.takeException(), isNull);
    expect(find.text('Category charts'), findsOneWidget);
    expect(find.byKey(const ValueKey('date-range-preset')), findsOneWidget);
    expect(find.byKey(const ValueKey('charts-mode-pie')), findsOneWidget);
    expect(find.byKey(const ValueKey('charts-mode-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('charts-side-out')), findsOneWidget);
    expect(find.byKey(const ValueKey('charts-side-in')), findsOneWidget);
    expect(find.text('This month'), findsWidgets);
    expect(find.text('Groceries'), findsWidgets);
    expect(find.text('Other'), findsWidgets);
    final sheet = tester.getRect(find.byType(CategoryChartsView));
    expect(sheet.width, lessThanOrEqualTo(320.5));
  });

  testWidgets('empty state at 320: no events to chart yet', (tester) async {
    await pumpSheet(
      tester,
      width: 320,
      height: 640,
      totals: CategoryTotals.empty,
      range: DateRange.allTime,
      hasEvents: false,
    );
    expect(find.text('No events to chart yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty counted range and empty money-in side', (tester) async {
    await pumpSheet(
      tester,
      width: 320,
      height: 640,
      totals: CategoryTotals.empty,
      hasEvents: true,
    );
    expect(find.text('No counted events in this range'), findsOneWidget);

    await pumpSheet(tester, width: 320, height: 640, totals: fixtureTotals());
    await tester.tap(find.byKey(const ValueKey('charts-side-in')));
    await tester.pumpAndSettle();
    expect(find.text('Salary'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('charts-side-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('charts-mode-bar')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('charts-bar-groc')), findsOneWidget);
  });

  testWidgets('picking Last month writes the shared range', (tester) async {
    DateRange? got;
    await withClock(Clock.fixed(DateTime(2026, 11, 26)), () async {
      await pumpSheet(
        tester,
        width: 600,
        height: 800,
        totals: fixtureTotals(),
        onChanged: (r) => got = r,
      );
      await tester.tap(find.byKey(const ValueKey('date-range-preset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last month').last);
      await tester.pumpAndSettle();
    });
    expect(got?.preset, DateRangePreset.lastMonth);
    expect(got?.start, DateTime(2026, 10, 1));
    expect(got?.end, DateTime(2026, 10, 31));
  });

  for (final (tag, width, pie) in [
    ('320_pie', 320.0, true),
    ('320_bar', 320.0, false),
    ('600_pie', 600.0, true),
    ('600_bar', 600.0, false),
  ]) {
    testWidgets('golden $tag', (tester) async {
      if (!pie) {
        // Pref is read in initState: set before pump.
        // ignore: unused_local_variable
        final _ = () {
          page.clearLocal();
        }();
        // Use prefs after binding: pump a dummy first? AppPrefs works after
        // first pump. Set via the same API as the widget.
      }
      await pumpSheet(
        tester,
        width: width,
        height: width < 600 ? 640 : 800,
        totals: fixtureTotals(),
      );
      if (!pie) {
        await tester.tap(find.byKey(const ValueKey('charts-mode-bar')));
        await tester.pumpAndSettle();
      }
      await expectLater(
        find.byType(CategoryChartsView),
        matchesGoldenFile('goldens/category_charts_$tag.png'),
      );
    });
  }

  testWidgets('golden empty 320', (tester) async {
    await pumpSheet(
      tester,
      width: 320,
      height: 640,
      totals: CategoryTotals.empty,
      range: DateRange.allTime,
      hasEvents: false,
    );
    await expectLater(
      find.byType(CategoryChartsView),
      matchesGoldenFile('goldens/category_charts_empty_320.png'),
    );
  });
}
