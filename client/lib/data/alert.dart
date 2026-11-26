/// The stream alert rule, shared by every alert / "in the red" check:
/// a balance is an alert only when strictly below the threshold. A balance
/// equal to it (e.g. a new stream at 0 with a 0 threshold) is not.
bool belowAlert<T extends Comparable<Object>>(T balance, T threshold) =>
    balance.compareTo(threshold) < 0;

/// Whether a stream's current balance should be shown in the alert colour.
///
/// Red only when the balance has crossed the alert threshold. Expected-negative
/// debt streams (loans, mortgage) stay neutral: their default \$0 threshold
/// would always fire, and a loan running below zero is not itself an alert.
bool streamBalanceIsAlert({
  required bool hasLoan,
  required num? balance,
  required num threshold,
}) {
  if (hasLoan || balance == null) return false;
  return belowAlert(balance, threshold);
}
