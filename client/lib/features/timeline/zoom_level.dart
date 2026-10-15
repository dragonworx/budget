/// Discrete timeline zoom levels (§5.2).
enum ZoomLevel {
  day,
  week,
  month,
  quarter,
  year;

  String get label => switch (this) {
    ZoomLevel.day => 'Day',
    ZoomLevel.week => 'Week',
    ZoomLevel.month => 'Month',
    ZoomLevel.quarter => 'Quarter',
    ZoomLevel.year => 'Year',
  };

  /// Approximate visible span in days for the viewport.
  int get visibleDays => switch (this) {
    ZoomLevel.day => 14,
    ZoomLevel.week => 70,
    ZoomLevel.month => 365,
    ZoomLevel.quarter => 730,
    ZoomLevel.year => 1825,
  };

  /// X-axis tick / label coarseness in days.
  int get tickIntervalDays => switch (this) {
    ZoomLevel.day => 1,
    ZoomLevel.week => 7,
    ZoomLevel.month => 30,
    ZoomLevel.quarter => 90,
    ZoomLevel.year => 365,
  };

  ZoomLevel? get zoomedIn {
    final i = index;
    if (i <= 0) return null;
    return ZoomLevel.values[i - 1];
  }

  ZoomLevel? get zoomedOut {
    final i = index;
    if (i >= ZoomLevel.values.length - 1) return null;
    return ZoomLevel.values[i + 1];
  }
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Days since a fixed epoch — stable X coordinate for the chart.
double dateToX(DateTime d) {
  // UTC midnights: every day is 24h, so DST cannot drop or repeat a day.
  return DateTime.utc(
    d.year,
    d.month,
    d.day,
  ).difference(DateTime.utc(1970)).inDays.toDouble();
}

DateTime xToDate(double x) => DateTime(1970, 1, 1 + x.round());
