/// The account alert rule, shared by every alert / "in the red" check:
/// a balance is an alert only when strictly below the threshold. A balance
/// equal to it (e.g. a new account at 0 with a 0 threshold) is not.
bool belowAlert<T extends Comparable<Object>>(T balance, T threshold) =>
    balance.compareTo(threshold) < 0;
