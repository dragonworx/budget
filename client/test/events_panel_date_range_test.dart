import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/event_types.dart';
import 'package:budget_client/features/events/events_panel.dart';
import 'package:budget_client/features/timeline/date_range.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:clock/clock.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_categories.dart';

final _today = DateTime(2026, 11, 26);

BudgetEvent ev(
  String id, {
  String? name,
  DateTime? start,
  RecurrenceMode mode = RecurrenceMode.once,
  RecurrenceUnit unit = RecurrenceUnit.weeks,
  int interval = 1,
  EndMode end = EndMode.never,
  DateTime? endDate,
  int? count,
  String? categoryId,
  bool enabled = true,
  bool categoryHidden = false,
  String kind = 'standard',
  EventDirection dir = EventDirection.debit,
}) => BudgetEvent(
  id: id,
  streamId: 'p',
  name: name ?? id,
  direction: dir,
  amount: Decimal.fromInt(10),
  startDate: start ?? DateTime(2026, 1, 1),
  recurrenceMode: mode,
  interval: mode == RecurrenceMode.once ? null : interval,
  unit: mode == RecurrenceMode.once ? null : unit,
  endMode: end,
  endDate: endDate,
  occurrenceCount: count,
  enabled: enabled,
  categoryId: categoryId,
  categoryHidden: categoryHidden,
  kind: kind,
);

BudgetStream streamFor({Role role = Role.owner}) => BudgetStream(
  id: 'p',
  ownerId: 'u1',
  name: 'Everyday',
  seedBalance: Decimal.parse('1000'),
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
  role: role,
);

class _StreamRepo extends StreamRepository {
  _StreamRepo(this.stream) : super(ApiClient());
  final BudgetStream stream;
  @override
  Future<BudgetStream> get(String id) async => stream;
}

class _EventRepo extends EventRepository {
  _EventRepo(this.items) : super(ApiClient());
  final List<BudgetEvent> items;
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => items;
}

DateRange preset(DateRangePreset p) =>
    withClock(Clock.fixed(_today), () => DateRange.fromPreset(p));

void main() {
  setUp(page.clearLocal);

  final weekly = ev(
    'weekly',
    name: 'Weekly',
    start: DateTime(2025, 1, 6), // Monday
    mode: RecurrenceMode.every,
    unit: RecurrenceUnit.weeks,
  );
  final onceLastYear = ev(
    'old',
    name: 'Once last year',
    start: DateTime(2025, 6, 1),
  );
  final onStart = ev('start', name: 'On start', start: DateTime(2026, 11, 1));
  final onEnd = ev('end', name: 'On end', start: DateTime(2026, 11, 30));
  final endedOct = ev(
    'ended',
    name: 'Ended last month',
    start: DateTime(2026, 9, 1),
    mode: RecurrenceMode.every,
    unit: RecurrenceUnit.weeks,
    end: EndMode.untilDate,
    endDate: DateTime(2026, 10, 31),
  );
  final daily = ev(
    'daily',
    name: 'Daily',
    start: DateTime(2025, 1, 1),
    mode: RecurrenceMode.every,
    unit: RecurrenceUnit.days,
  );
  final sync = ev(
    'sync',
    name: 'Sync pin',
    start: DateTime(2026, 10, 15),
    kind: 'sync',
  );
  final skipped = ev('skip', name: 'Skipped', start: DateTime(2026, 11, 10));
  final hidden = ev(
    'hid',
    name: 'Hidden cat',
    start: DateTime(2026, 11, 10),
    categoryId: 'c1',
    categoryHidden: true,
  );
  final june = ev('june', name: 'June once', start: DateTime(2026, 6, 15));
  final sept = ev('sept', name: 'September once', start: DateTime(2026, 9, 15));

  test('predicate: schedule, bounds, skip, hidden, type and category', () {
    withClock(Clock.fixed(_today), () {
      final thisMonth = preset(DateRangePreset.thisMonth);
      final lastMonth = preset(DateRangePreset.lastMonth);

      expect(eventFiresInRange(weekly, thisMonth.start, thisMonth.end), isTrue);
      expect(
        eventFiresInRange(onceLastYear, thisMonth.start, thisMonth.end),
        isFalse,
      );
      expect(
        eventFiresInRange(onStart, thisMonth.start, thisMonth.end),
        isTrue,
      );
      expect(eventFiresInRange(onEnd, thisMonth.start, thisMonth.end), isTrue);
      expect(
        eventFiresInRange(endedOct, thisMonth.start, thisMonth.end),
        isFalse,
      );
      expect(
        eventFiresInRange(endedOct, lastMonth.start, lastMonth.end),
        isTrue,
      );

      for (final p in DateRangePreset.menu.where(
        (p) => p != DateRangePreset.allTime,
      )) {
        final r = DateRange.fromPreset(p);
        expect(
          eventFiresInRange(daily, r.start, r.end),
          isTrue,
          reason: p.label,
        );
      }

      expect(eventFiresInRange(sync, lastMonth.start, lastMonth.end), isTrue);
      expect(eventFiresInRange(sync, thisMonth.start, thisMonth.end), isFalse);

      // Skipped / hidden-category still included (schedule only).
      expect(
        eventFiresInRange(skipped, thisMonth.start, thisMonth.end),
        isTrue,
      );
      expect(eventFiresInRange(hidden, thisMonth.start, thisMonth.end), isTrue);

      final items = [weekly, onStart, hidden, onceLastYear];
      expect(
        filterEvents(
          items,
          const {},
          rangeStart: thisMonth.start,
          rangeEnd: thisMonth.end,
        ).map((t) => t.id),
        ['weekly', 'start', 'hid'],
      );
      expect(
        filterEvents(
          items,
          {EventType.credit},
          rangeStart: thisMonth.start,
          rangeEnd: thisMonth.end,
        ),
        isEmpty,
      );
      expect(
        filterEvents(
          [hidden, onStart],
          const {},
          category: 'c1',
          rangeStart: thisMonth.start,
          rangeEnd: thisMonth.end,
        ).single.id,
        'hid',
      );
    });
  });

  final fixture = [june, sept, weekly, onceLastYear, onStart];

  Future<void> pumpPanel(
    WidgetTester tester, {
    required Size size,
    required ValueNotifier<DateRange> range,
    List<BudgetEvent>? items,
    Role role = Role.owner,
    ValueChanged<DateRange>? onChanged,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final stream = streamFor(role: role);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamRepositoryProvider.overrideWithValue(_StreamRepo(stream)),
          eventRepositoryProvider.overrideWithValue(
            _EventRepo(items ?? fixture),
          ),
          categoryRepositoryProvider.overrideWith(
            (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider)),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: EventsPanel(
              stream: stream,
              rangeListenable: range,
              onRangeChanged: onChanged ?? (r) => range.value = r,
              skipsFor: (_) => const {},
              onPanelClosed: (_) {},
              onChanged: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('All time shows every fixture event', (tester) async {
    final range = ValueNotifier(DateRange.allTime);
    addTearDown(range.dispose);
    await pumpPanel(tester, size: const Size(390, 844), range: range);
    expect(find.text('June once'), findsOneWidget);
    expect(find.text('September once'), findsOneWidget);
    expect(find.text('Weekly'), findsOneWidget);
    expect(find.text('Once last year'), findsOneWidget);
    expect(find.text('On start'), findsOneWidget);
    expect(find.text('All time'), findsWidgets);
  });

  testWidgets('Last three months hides June and keeps September', (
    tester,
  ) async {
    final range = ValueNotifier(preset(DateRangePreset.lastThreeMonths));
    addTearDown(range.dispose);
    await pumpPanel(tester, size: const Size(390, 844), range: range);
    expect(find.text('June once'), findsNothing);
    expect(find.text('September once'), findsOneWidget);
    expect(find.text('Last three months'), findsWidgets);
  });

  testWidgets('picking This week writes the shared range', (tester) async {
    DateRange? got;
    final range = ValueNotifier(DateRange.allTime);
    addTearDown(range.dispose);
    await withClock(Clock.fixed(_today), () async {
      await pumpPanel(
        tester,
        size: const Size(390, 844),
        range: range,
        onChanged: (r) {
          got = r;
          range.value = r;
        },
      );
      await tester.tap(find.byKey(const ValueKey('date-range-preset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('This week').last);
      await tester.pumpAndSettle();
    });
    expect(got?.preset, DateRangePreset.thisWeek);
    expect(got?.start, DateTime(2026, 11, 23));
    expect(got?.end, DateTime(2026, 11, 29));
  });

  testWidgets('an outside range change becomes Custom and filters the list', (
    tester,
  ) async {
    final range = ValueNotifier(DateRange.allTime);
    addTearDown(range.dispose);
    await pumpPanel(tester, size: const Size(390, 844), range: range);
    expect(find.text('June once'), findsOneWidget);
    range.value = DateRange.fromDates(
      DateTime(2026, 9, 1),
      DateTime(2026, 9, 30),
    );
    await tester.pumpAndSettle();
    expect(find.text('Custom'), findsWidgets);
    expect(find.text('June once'), findsNothing);
    expect(find.text('September once'), findsOneWidget);
  });

  testWidgets('Clear filter with only a date filter returns to All time', (
    tester,
  ) async {
    final range = ValueNotifier(
      DateRange.fromDates(DateTime(2026, 1, 1), DateTime(2026, 1, 2)),
    );
    addTearDown(range.dispose);
    DateRange? got;
    await pumpPanel(
      tester,
      size: const Size(390, 844),
      range: range,
      onChanged: (r) {
        got = r;
        range.value = r;
      },
    );
    expect(find.text('No events in this range.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('events-clear-filters')));
    await tester.pumpAndSettle();
    expect(got, DateRange.allTime);
    expect(find.text('June once'), findsOneWidget);
    expect(find.text('All time'), findsWidgets);
  });

  testWidgets('drag-reorder handles hide while a range is active', (
    tester,
  ) async {
    final range = ValueNotifier(DateRange.allTime);
    addTearDown(range.dispose);
    await pumpPanel(tester, size: const Size(390, 844), range: range);
    expect(find.byType(ReorderableDragStartListener), findsWidgets);
    range.value = preset(DateRangePreset.thisMonth);
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableDragStartListener), findsNothing);
    range.value = DateRange.allTime;
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableDragStartListener), findsWidgets);
  });

  for (final size in const [Size(320, 640), Size(390, 844)]) {
    testWidgets('${size.width.toInt()} header does not overflow', (
      tester,
    ) async {
      final range = ValueNotifier(preset(DateRangePreset.thisMonth));
      addTearDown(range.dispose);
      await pumpPanel(tester, size: size, range: range);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('date-range-preset')), findsOneWidget);
      expect(find.text('Transactions'), findsOneWidget);
      expect(find.byKey(const ValueKey('panel-close')), findsOneWidget);
    });
  }

  testWidgets('viewers see the dropdown', (tester) async {
    final range = ValueNotifier(DateRange.allTime);
    addTearDown(range.dispose);
    await pumpPanel(
      tester,
      size: const Size(390, 844),
      range: range,
      role: Role.viewer,
    );
    expect(find.byKey(const ValueKey('date-range-preset')), findsOneWidget);
    expect(find.byKey(const ValueKey('panel-view-only')), findsOneWidget);
  });
}
