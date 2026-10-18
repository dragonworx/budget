import 'package:budget_client/features/timeline/duration_format.dart';
import 'package:flutter_test/flutter_test.dart';

String f(
  DateTime a,
  DateTime b, [
  DurationPrecision p = DurationPrecision.days,
]) => formatSpanDuration(a, b, precision: p);

void main() {
  test('same day is 1 Day', () {
    expect(f(DateTime(2026, 10, 5), DateTime(2026, 10, 5)), '1 Day');
  });
  test('plurals and weeks', () {
    expect(f(DateTime(2026, 10, 1), DateTime(2026, 10, 2)), '2 Days');
    expect(f(DateTime(2026, 10, 1), DateTime(2026, 10, 7)), '1 Week');
    expect(f(DateTime(2026, 10, 1), DateTime(2026, 10, 15)), '2 Weeks, 1 Day');
  });
  test('whole month, month + weeks + day', () {
    expect(f(DateTime(2026, 10, 1), DateTime(2026, 10, 31)), '1 Month');
    expect(
      f(DateTime(2026, 10, 1), DateTime(2026, 11, 15)),
      '1 Month, 2 Weeks, 1 Day',
    );
  });
  test('month-end rollovers clamp', () {
    // 31 Jan + 1 month clamps to 28 Feb, so 31 Jan..27 Feb is a month.
    expect(f(DateTime(2026, 1, 31), DateTime(2026, 2, 27)), '1 Month');
    expect(f(DateTime(2026, 1, 31), DateTime(2026, 2, 28)), '1 Month, 1 Day');
    expect(f(DateTime(2026, 1, 31), DateTime(2026, 2, 26)), '3 Weeks, 6 Days');
    expect(f(DateTime(2026, 2, 1), DateTime(2026, 2, 28)), '1 Month');
    expect(f(DateTime(2026, 4, 30), DateTime(2026, 5, 29)), '1 Month');
  });
  test('leap years', () {
    expect(f(DateTime(2028, 2, 1), DateTime(2028, 2, 29)), '1 Month');
    expect(f(DateTime(2028, 2, 1), DateTime(2028, 2, 28)), '4 Weeks');
    expect(f(DateTime(2028, 2, 29), DateTime(2029, 2, 27)), '1 Year');
  });
  test('exactly 1 year', () {
    expect(f(DateTime(2026, 1, 1), DateTime(2026, 12, 31)), '1 Year');
    expect(f(DateTime(2026, 10, 18), DateTime(2027, 10, 17)), '1 Year');
  });
  test('reversed range is the same', () {
    expect(f(DateTime(2026, 10, 15), DateTime(2026, 10, 1)), '2 Weeks, 1 Day');
  });
  test('precision follows the time scale', () {
    final a = DateTime(2026, 1, 1), b = DateTime(2027, 3, 17);
    expect(f(a, b), '1 Year, 2 Months, 2 Weeks'); // max 3 parts
    expect(f(a, b, DurationPrecision.weeks), '1 Year, 2 Months, 2 Weeks');
    expect(f(a, b, DurationPrecision.months), '1 Year, 2 Months');
    expect(
      f(DateTime(2026, 10, 1), DateTime(2026, 11, 15), DurationPrecision.weeks),
      '1 Month, 2 Weeks',
    );
    // Short spans never come out empty.
    expect(
      f(DateTime(2026, 10, 1), DateTime(2026, 10, 3), DurationPrecision.weeks),
      '3 Days',
    );
    expect(
      f(
        DateTime(2026, 10, 1),
        DateTime(2026, 10, 20),
        DurationPrecision.months,
      ),
      '2 Weeks',
    );
    expect(durationPrecisionFor(7), DurationPrecision.days);
    expect(durationPrecisionFor(91), DurationPrecision.weeks);
    expect(durationPrecisionFor(365), DurationPrecision.months);
  });
}
