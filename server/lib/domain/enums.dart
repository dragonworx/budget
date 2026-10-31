enum Direction {
  credit,
  debit;

  static Direction parse(String value) {
    return Direction.values.firstWhere(
      (e) => e.name == value,
      orElse: () => throw FormatException('Invalid direction: $value'),
    );
  }
}

enum RecurrenceMode {
  once,
  every;

  static RecurrenceMode parse(String value) {
    return RecurrenceMode.values.firstWhere(
      (e) => e.name == value,
      orElse: () => throw FormatException('Invalid recurrence_mode: $value'),
    );
  }
}

enum RecurrenceUnit {
  days,
  weeks,
  months,
  years;

  static RecurrenceUnit parse(String value) {
    return RecurrenceUnit.values.firstWhere(
      (e) => e.name == value,
      orElse: () => throw FormatException('Invalid unit: $value'),
    );
  }
}

enum EndMode {
  never,
  untilDate,
  count;

  String get apiName => switch (this) {
        EndMode.never => 'never',
        EndMode.untilDate => 'until_date',
        EndMode.count => 'count',
      };

  static EndMode parse(String value) {
    return switch (value) {
      'never' => EndMode.never,
      'until_date' || 'untilDate' => EndMode.untilDate,
      'count' => EndMode.count,
      _ => throw FormatException('Invalid end_mode: $value'),
    };
  }
}

enum RoundingMode {
  nearest,
  atLeast,
  atMost;

  static RoundingMode parse(String value) {
    return switch (value) {
      'nearest' => RoundingMode.nearest,
      'atLeast' || 'at_least' => RoundingMode.atLeast,
      'atMost' || 'at_most' => RoundingMode.atMost,
      _ => throw FormatException('Invalid rounding: $value'),
    };
  }
}

/// An event's kind (migration 026): a standard event, or a stream's loan
/// (a once-off debit drawdown whose `loan` terms accrue interest).
enum EventKind {
  standard,
  loan;

  static EventKind parse(String value) {
    return EventKind.values.firstWhere(
      (e) => e.name == value,
      orElse: () => throw FormatException('kind must be standard or loan'),
    );
  }
}
