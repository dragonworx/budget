import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/features/timeline/date_range.dart';
import 'package:budget_client/state/app_prefs.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:budget_client/widgets/date_range_preset_control.dart';

DateTime d(int y, int m, int day) => DateTime(y, m, day);

void main() {
  setUp(page.clearLocal);

  test('preset table for Thursday 26 Nov 2026', () {
    withClock(Clock.fixed(d(2026, 11, 26)), () {
      expect(DateRange.fromPreset(DateRangePreset.allTime), DateRange.allTime);
      expect(DateRange.allTime.start, isNull);
      expect(DateRange.allTime.end, isNull);

      final thisWeek = DateRange.fromPreset(DateRangePreset.thisWeek);
      expect(thisWeek.start, d(2026, 11, 23));
      expect(thisWeek.end, d(2026, 11, 29));
      expect(thisWeek.preset, DateRangePreset.thisWeek);

      final lastWeek = DateRange.fromPreset(DateRangePreset.lastWeek);
      expect(lastWeek.start, d(2026, 11, 16));
      expect(lastWeek.end, d(2026, 11, 22));

      final thisMonth = DateRange.fromPreset(DateRangePreset.thisMonth);
      expect(thisMonth.start, d(2026, 11, 1));
      expect(thisMonth.end, d(2026, 11, 30));

      final lastMonth = DateRange.fromPreset(DateRangePreset.lastMonth);
      expect(lastMonth.start, d(2026, 10, 1));
      expect(lastMonth.end, d(2026, 10, 31));

      final last3 = DateRange.fromPreset(DateRangePreset.lastThreeMonths);
      expect(last3.start, d(2026, 8, 1));
      expect(last3.end, d(2026, 10, 31));
    });
  });

  test('This week and Last week when today is Monday or Sunday', () {
    // Monday 23 Nov 2026.
    withClock(Clock.fixed(d(2026, 11, 23)), () {
      final w = DateRange.fromPreset(DateRangePreset.thisWeek);
      expect(w.start, d(2026, 11, 23));
      expect(w.end, d(2026, 11, 29));
      final last = DateRange.fromPreset(DateRangePreset.lastWeek);
      expect(last.start, d(2026, 11, 16));
      expect(last.end, d(2026, 11, 22));
    });
    // Sunday 29 Nov 2026.
    withClock(Clock.fixed(d(2026, 11, 29)), () {
      final w = DateRange.fromPreset(DateRangePreset.thisWeek);
      expect(w.start, d(2026, 11, 23));
      expect(w.end, d(2026, 11, 29));
      final last = DateRange.fromPreset(DateRangePreset.lastWeek);
      expect(last.start, d(2026, 11, 16));
      expect(last.end, d(2026, 11, 22));
    });
  });

  test('month ends: 28/29 Feb, 31 Jan, 31 Oct', () {
    withClock(Clock.fixed(d(2026, 3, 10)), () {
      final last = DateRange.fromPreset(DateRangePreset.lastMonth);
      expect(last.start, d(2026, 2, 1));
      expect(last.end, d(2026, 2, 28));
    });
    withClock(Clock.fixed(d(2028, 3, 10)), () {
      final last = DateRange.fromPreset(DateRangePreset.lastMonth);
      expect(last.start, d(2028, 2, 1));
      expect(last.end, d(2028, 2, 29));
    });
    withClock(Clock.fixed(d(2026, 2, 10)), () {
      final last = DateRange.fromPreset(DateRangePreset.lastMonth);
      expect(last.start, d(2026, 1, 1));
      expect(last.end, d(2026, 1, 31));
    });
    withClock(Clock.fixed(d(2026, 11, 26)), () {
      final last = DateRange.fromPreset(DateRangePreset.lastMonth);
      expect(last.end, d(2026, 10, 31));
    });
  });

  test('Last three months from 1 Jan and from 1 Mar in a leap year', () {
    withClock(Clock.fixed(d(2027, 1, 1)), () {
      final r = DateRange.fromPreset(DateRangePreset.lastThreeMonths);
      expect(r.start, d(2026, 10, 1));
      expect(r.end, d(2026, 12, 31));
    });
    withClock(Clock.fixed(d(2028, 3, 1)), () {
      final r = DateRange.fromPreset(DateRangePreset.lastThreeMonths);
      expect(r.start, d(2027, 12, 1));
      expect(r.end, d(2028, 2, 29));
    });
  });

  test('fromDates reports thisMonth when exact, custom when a day off', () {
    withClock(Clock.fixed(d(2026, 11, 26)), () {
      final exact = DateRange.fromDates(d(2026, 11, 1), d(2026, 11, 30));
      expect(exact.preset, DateRangePreset.thisMonth);
      final off = DateRange.fromDates(d(2026, 11, 1), d(2026, 11, 29));
      expect(off.preset, DateRangePreset.custom);
      expect(off.start, d(2026, 11, 1));
      expect(off.end, d(2026, 11, 29));
      // Unordered edges are ordered.
      final swapped = DateRange.fromDates(d(2026, 11, 30), d(2026, 11, 1));
      expect(swapped.preset, DateRangePreset.thisMonth);
    });
  });

  test('persistence: relative presets recompute; Custom dates do not', () {
    withClock(Clock.fixed(d(2026, 11, 26)), () {
      saveDateRange(DateRange.fromPreset(DateRangePreset.thisMonth));
      expect(appPrefs.getString(PrefKeys.dateRangePreset), 'thisMonth');
      expect(appPrefs.getString(PrefKeys.dateRangeCustomFrom), isNull);
    });
    withClock(Clock.fixed(d(2026, 12, 5)), () {
      final r = loadDateRange();
      expect(r.preset, DateRangePreset.thisMonth);
      expect(r.start, d(2026, 12, 1));
      expect(r.end, d(2026, 12, 31));
    });

    withClock(Clock.fixed(d(2026, 11, 26)), () {
      saveDateRange(DateRange.fromDates(d(2026, 9, 3), d(2026, 9, 10)));
      expect(appPrefs.getString(PrefKeys.dateRangePreset), 'custom');
    });
    withClock(Clock.fixed(d(2026, 12, 5)), () {
      final r = loadDateRange();
      expect(r.preset, DateRangePreset.custom);
      expect(r.start, d(2026, 9, 3));
      expect(r.end, d(2026, 9, 10));
    });

    saveDateRange(DateRange.allTime);
    expect(loadDateRange(), DateRange.allTime);
    expect(appPrefs.getString(PrefKeys.dateRangeCustomFrom), isNull);
  });

  testWidgets('the dropdown lists the six named presets, not Custom', (
    tester,
  ) async {
    DateRange current = DateRange.allTime;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => DateRangePresetControl(
              range: current,
              onChanged: (r) => setState(() => current = r),
            ),
          ),
        ),
      ),
    );
    expect(find.text('All time'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('date-range-preset')));
    await tester.pumpAndSettle();
    for (final p in DateRangePreset.menu) {
      expect(find.text(p.label), findsWidgets);
    }
    expect(find.text('Custom'), findsNothing);
    await tester.tap(find.text('Last month').last);
    await tester.pumpAndSettle();
    expect(current.preset, DateRangePreset.lastMonth);
  });
}
