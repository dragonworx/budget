import 'frequency.dart';

const weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _monthShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// 1st 2nd 3rd 4th … 11th 12th 13th … 21st 22nd 23rd … 31st.
String ordinalDay(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen
      ? 'th'
      : switch (n % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$n$suffix';
}

/// "8 Oct 2026".
String shortDate(DateTime d) =>
    '${d.day} ${_monthShort[d.month - 1]} ${d.year}';

/// "a", "a and b", "a, b and c".
String joinAnd(List<String> parts) => switch (parts.length) {
      0 => '',
      1 => parts.first,
      _ => '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}',
    };

/// The rule's own words, without days: "Every day", "Every 3 days",
/// "Every week", "Every 2 weeks", "Monthly", "Every 3 months", "Yearly",
/// "Every 2 years" (whole years of months without days).
String cadencePhrase(Frequency f) {
  final n = f.interval;
  return switch (f.rule) {
    FreqRule.once => 'Once',
    FreqRule.daily => n == 1 ? 'Every day' : 'Every $n days',
    FreqRule.weekly => 'Every week',
    FreqRule.everyNWeeks => 'Every $n weeks',
    FreqRule.monthly => 'Monthly',
    FreqRule.everyNMonths when f.days.isEmpty && n % 12 == 0 =>
      n == 12 ? 'Yearly' : 'Every ${n ~/ 12} years',
    FreqRule.everyNMonths => 'Every $n months',
  };
}

/// The live phrase: "Once on 8 Oct 2026", "Every day", "Every week on Mon,
/// Tue", "Every 2 weeks on Mon, Wed", "Monthly on the 1st and 15th",
/// "Every 3 months on the 31st (last day when short)". [compact] (the
/// Events list) says just "Once" for a one-off and drops the short-month
/// note.
String describeFrequency(
  Frequency f,
  DateTime start, {
  bool compact = false,
}) {
  if (f.rule == FreqRule.once) {
    return compact ? 'Once' : 'Once on ${shortDate(start)}';
  }
  final base = cadencePhrase(f);
  if (f.days.isEmpty) return base;
  if (f.rule.weekFamily) {
    return '$base on ${[
      for (final d in f.days) weekdayShort[d - 1]
    ].join(', ')}';
  }
  final days = 'the ${joinAnd([for (final d in f.days) ordinalDay(d)])}';
  final short = !compact && f.days.any((d) => d >= 29);
  return '$base on $days${short ? ' (last day when short)' : ''}';
}
