import 'package:decimal/decimal.dart';

/// Offset-account arithmetic (spec 004 §7), the one place it is defined.
abstract final class OffsetMath {
  /// The part of an offset stream's closing balance that reduces the
  /// loan's interest base: `max(0, closing − max(0, threshold))`.
  ///
  /// The alert threshold is the account's "zero" (balances below it show
  /// in red). A negative threshold (an overdraft buffer) counts as zero,
  /// so borrowed money never offsets (Ali, 31 Oct 2026).
  static Decimal usable(Decimal closing, Decimal threshold) {
    final z = thresholdUsed(threshold);
    final u = closing - z;
    return u > Decimal.zero ? u : Decimal.zero;
  }

  /// The threshold the offset applies: `max(0, threshold)`.
  static Decimal thresholdUsed(Decimal threshold) =>
      threshold > Decimal.zero ? threshold : Decimal.zero;
}
