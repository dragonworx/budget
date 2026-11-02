import 'package:flutter/material.dart';

import '../../data/models.dart';

/// The four event types the Events list filters by and the editor offers,
/// in this order, with these labels and icons (the editor adds Loan where
/// loans are allowed).
enum EventType { credit, debit, transfer, sync }

extension EventTypeLook on EventType {
  String get label => switch (this) {
    EventType.credit => 'Credit',
    EventType.debit => 'Debit',
    EventType.transfer => 'Transfer',
    EventType.sync => 'Sync',
  };

  IconData get icon => switch (this) {
    EventType.credit => Icons.south_west_rounded,
    EventType.debit => Icons.north_east_rounded,
    EventType.transfer => Icons.swap_horiz_rounded,
    EventType.sync => Icons.sync,
  };
}

/// Every type: the Events list's default filter.
const Set<EventType> allEventTypes = {
  EventType.credit,
  EventType.debit,
  EventType.transfer,
  EventType.sync,
};

/// [t]'s type. A loan has no type of its own here: it counts as Credit or
/// Debit by its direction (as it did under Money in / Money out).
EventType eventTypeOf(BudgetEvent t) {
  if (t.isSync) return EventType.sync;
  if (t.isTransfer) return EventType.transfer;
  return t.direction == EventDirection.credit
      ? EventType.credit
      : EventType.debit;
}
