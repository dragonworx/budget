// Human-readable selection lengths ("1 Month, 2 Weeks, 1 Day").

/// How fine a duration is shown, picked from the view's time scale.
enum DurationPrecision {
  /// Day … 3-week scales: years, months, weeks and days.
  days,

  /// Month … 6-month scales: years, months and weeks (days dropped).
  weeks,

  /// Year scale and wider: years and months.
  months,
}

/// Precision for a view [visibleDays] wide: day/week units show days,
/// month/quarter units drop them, year scales show years and months.
DurationPrecision durationPrecisionFor(double visibleDays) {
  if (visibleDays <= 32) return DurationPrecision.days;
  if (visibleDays <= 300) return DurationPrecision.weeks;
  return DurationPrecision.months;
}

/// Calendar-aware length of the inclusive day range [start]..[end]
/// ("same day" is 1 Day). Whole years and months are counted from [start]
/// (clamping to month ends, so 31 Jan + 1 month = 28/29 Feb), then the rest
/// as weeks and days. Zero parts are dropped and at most [maxParts] kept;
/// coarser [precision] drops the finer parts, except that a span shorter
/// than the coarsest kept part still falls back to its largest non-zero
/// part (never empty).
String formatSpanDuration(
  DateTime start,
  DateTime end, {
  DurationPrecision precision = DurationPrecision.days,
  int maxParts = 3,
}) {
  var a = DateTime.utc(start.year, start.month, start.day);
  var b = DateTime.utc(end.year, end.month, end.day);
  if (b.isBefore(a)) (a, b) = (b, a);
  final stop = b.add(const Duration(days: 1)); // exclusive end

  var months = 0;
  while (!_addMonths(a, months + 1).isAfter(stop)) {
    months++;
  }
  final rest = stop.difference(_addMonths(a, months)).inDays;
  final parts = <(int, String)>[
    (months ~/ 12, 'Year'),
    (months % 12, 'Month'),
    (rest ~/ 7, 'Week'),
    (rest % 7, 'Day'),
  ];
  final keep = switch (precision) {
    DurationPrecision.days => 4,
    DurationPrecision.weeks => 3,
    DurationPrecision.months => 2,
  };
  var shown = [
    for (final p in parts.take(keep))
      if (p.$1 > 0) p,
  ];
  if (shown.isEmpty) {
    shown = [parts.firstWhere((p) => p.$1 > 0)];
  }
  return shown
      .take(maxParts)
      .map((p) => '${p.$1} ${p.$2}${p.$1 == 1 ? '' : 's'}')
      .join(', ');
}

/// [d] plus [n] calendar months, clamped to the target month's last day.
DateTime _addMonths(DateTime d, int n) {
  final m = d.month - 1 + n;
  final y = d.year + m ~/ 12, mo = m % 12 + 1;
  final last = DateTime.utc(y, mo + 1, 0).day;
  return DateTime.utc(y, mo, d.day > last ? last : d.day);
}
