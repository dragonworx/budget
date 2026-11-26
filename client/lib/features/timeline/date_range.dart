import 'package:clock/clock.dart';

import '../../data/models.dart';
import '../../state/app_prefs.dart';
import 'zoom_level.dart' show dateOnly;

/// Named periods for the shared timeline / charts / Events list range.
///
/// [custom] is never a menu item: it is only the closed-dropdown label
/// when the current dates do not match a named preset.
enum DateRangePreset {
  allTime,
  thisWeek,
  lastWeek,
  thisMonth,
  lastMonth,
  lastThreeMonths,
  custom;

  /// Labels, matching the menu order (Custom is not listed).
  String get label => switch (this) {
    DateRangePreset.allTime => 'All time',
    DateRangePreset.thisWeek => 'This week',
    DateRangePreset.lastWeek => 'Last week',
    DateRangePreset.thisMonth => 'This month',
    DateRangePreset.lastMonth => 'Last month',
    DateRangePreset.lastThreeMonths => 'Last three months',
    DateRangePreset.custom => 'Custom',
  };

  /// The six named presets, in menu order.
  static const menu = [
    DateRangePreset.allTime,
    DateRangePreset.thisWeek,
    DateRangePreset.lastWeek,
    DateRangePreset.thisMonth,
    DateRangePreset.lastMonth,
    DateRangePreset.lastThreeMonths,
  ];

  static DateRangePreset? tryParse(String? raw) {
    if (raw == null) return null;
    for (final p in DateRangePreset.values) {
      if (p.name == raw) return p;
    }
    return null;
  }
}

/// Inclusive day range plus the preset that produced it.
///
/// [start] and [end] are null only for [DateRangePreset.allTime].
class DateRange {
  const DateRange({this.start, this.end, required this.preset});

  /// No start and no end: the timeline band is cleared.
  static const allTime = DateRange(preset: DateRangePreset.allTime);

  final DateTime? start;
  final DateTime? end;
  final DateRangePreset preset;

  bool get isAllTime =>
      preset == DateRangePreset.allTime || (start == null && end == null);

  /// A named preset (including All time) resolved from [now] (or
  /// [clock.now]). [custom] is rejected — use [fromDates].
  factory DateRange.fromPreset(DateRangePreset preset, [DateTime? now]) {
    if (preset == DateRangePreset.custom) {
      throw ArgumentError.value(preset, 'preset', 'use DateRange.fromDates');
    }
    if (preset == DateRangePreset.allTime) return DateRange.allTime;
    final period = periodOf(preset, now);
    return DateRange(start: period.start, end: period.end, preset: preset);
  }

  /// Explicit inclusive dates. If they exactly equal a named preset's
  /// current period (from [now]), that preset is used; otherwise Custom.
  factory DateRange.fromDates(DateTime start, DateTime end, [DateTime? now]) {
    final a = dateOnly(start);
    final b = dateOnly(end);
    final lo = a.isBefore(b) ? a : b;
    final hi = a.isBefore(b) ? b : a;
    for (final p in DateRangePreset.menu) {
      if (p == DateRangePreset.allTime) continue;
      final period = periodOf(p, now);
      if (period.start == lo && period.end == hi) {
        return DateRange(start: lo, end: hi, preset: p);
      }
    }
    return DateRange(start: lo, end: hi, preset: DateRangePreset.custom);
  }

  @override
  bool operator ==(Object other) =>
      other is DateRange &&
      other.preset == preset &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(preset, start, end);

  @override
  String toString() => isAllTime
      ? 'DateRange.allTime'
      : 'DateRange($preset, ${formatDate(start!)}..${formatDate(end!)})';
}

/// Inclusive start/end of a named, bounded preset, from [now] (or
/// [clock.now]). Weeks start Monday and end Sunday. "Last …" periods are
/// previous full calendar periods, not rolling.
({DateTime start, DateTime end}) periodOf(
  DateRangePreset preset, [
  DateTime? now,
]) {
  final today = dateOnly(now ?? clock.now());
  switch (preset) {
    case DateRangePreset.thisWeek:
      final start = _mondayOnOrBefore(today);
      return (start: start, end: _addCalendarDays(start, 6));
    case DateRangePreset.lastWeek:
      final start = _addCalendarDays(_mondayOnOrBefore(today), -7);
      return (start: start, end: _addCalendarDays(start, 6));
    case DateRangePreset.thisMonth:
      return (
        start: DateTime(today.year, today.month, 1),
        end: DateTime(today.year, today.month + 1, 0),
      );
    case DateRangePreset.lastMonth:
      final start = DateTime(today.year, today.month - 1, 1);
      return (start: start, end: DateTime(start.year, start.month + 1, 0));
    case DateRangePreset.lastThreeMonths:
      final start = DateTime(today.year, today.month - 3, 1);
      return (start: start, end: DateTime(today.year, today.month, 0));
    case DateRangePreset.allTime:
    case DateRangePreset.custom:
      throw ArgumentError.value(preset, 'preset', 'has no fixed period');
  }
}

DateTime _mondayOnOrBefore(DateTime day) =>
    _addCalendarDays(day, -(day.weekday - DateTime.monday));

DateTime _addCalendarDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);

/// Persist [range] on this device. Relative presets store only the name;
/// Custom also stores its dates.
void saveDateRange(DateRange range, {AppPrefs prefs = appPrefs}) {
  prefs.setString(PrefKeys.dateRangePreset, range.preset.name);
  if (range.preset == DateRangePreset.custom &&
      range.start != null &&
      range.end != null) {
    prefs.setString(PrefKeys.dateRangeCustomFrom, formatDate(range.start!));
    prefs.setString(PrefKeys.dateRangeCustomTo, formatDate(range.end!));
  } else {
    prefs.remove(PrefKeys.dateRangeCustomFrom);
    prefs.remove(PrefKeys.dateRangeCustomTo);
  }
}

/// Restore the last chosen preset. Relative presets are recomputed from
/// [now] (or [clock.now]); a stored Custom range is restored as those
/// exact dates. Invalid or missing storage is All time.
DateRange loadDateRange({AppPrefs prefs = appPrefs, DateTime? now}) {
  final preset =
      DateRangePreset.tryParse(prefs.getString(PrefKeys.dateRangePreset)) ??
      DateRangePreset.allTime;
  if (preset == DateRangePreset.custom) {
    final from = prefs.getString(PrefKeys.dateRangeCustomFrom);
    final to = prefs.getString(PrefKeys.dateRangeCustomTo);
    if (from == null || to == null) return DateRange.allTime;
    try {
      return DateRange.fromDates(parseDate(from), parseDate(to), now);
    } on FormatException {
      return DateRange.allTime;
    }
  }
  return DateRange.fromPreset(preset, now);
}
