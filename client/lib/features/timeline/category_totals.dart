import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/app_theme.dart';
import 'clusters.dart';
import 'day_totals.dart';
import 'lod.dart';
import 'stack_lanes.dart';
import 'zoom_level.dart';

const interestBucketId = '__loan_interest__';
const uncategorisedBucketId = '__uncategorised__';
const otherBucketId = '__other__';

const loanInterestName = 'Loan interest';
const uncategorisedName = 'Uncategorised';
const otherName = 'Other';

/// Neutral colour for the Other collapse.
const otherColor = AppTheme.textFaint;

/// Muted colour for occurrences with no category.
const uncategorisedColor = AppTheme.textMuted;

/// Distinct colour for the Loan interest bucket.
const loanInterestColor = AppTheme.violet;

/// One category (or special bucket) in a range, with in / out in integer
/// cents so tests can compare exactly.
class CategoryBucket {
  const CategoryBucket({
    required this.id,
    required this.name,
    required this.color,
    required this.inCents,
    required this.outCents,
    required this.count,
    this.parentName,
    this.groupedCount = 0,
  });

  /// Leaf [Category.id], or a special id ([interestBucketId],
  /// [uncategorisedBucketId], [otherBucketId]).
  final String id;
  final String name;
  final Color color;

  /// Credits, ≥ 0.
  final int inCents;

  /// Debits, ≤ 0.
  final int outCents;
  final int count;

  /// Parent folder name when the leaf has one.
  final String? parentName;

  /// For Other: how many categories were collapsed.
  final int groupedCount;

  String? get path => parentName == null ? null : '$parentName / $name';

  int centsOn({required bool moneyOut}) => moneyOut ? outCents : inCents;

  CategoryBucket plus(int signedCents) {
    final inC = signedCents >= 0 ? inCents + signedCents : inCents;
    final outC = signedCents < 0 ? outCents + signedCents : outCents;
    return CategoryBucket(
      id: id,
      name: name,
      color: color,
      inCents: inC,
      outCents: outC,
      count: count + 1,
      parentName: parentName,
      groupedCount: groupedCount,
    );
  }
}

/// Category totals over a date range (or all supplied occurrences).
class CategoryTotals {
  const CategoryTotals({
    required this.buckets,
    required this.inCents,
    required this.outCents,
  });

  static const empty = CategoryTotals(buckets: [], inCents: 0, outCents: 0);

  /// Raw per-category buckets (no Other collapse), zeros omitted.
  final List<CategoryBucket> buckets;
  final int inCents;
  final int outCents;
  int get netCents => inCents + outCents;

  bool get isEmpty => inCents == 0 && outCents == 0;

  /// Active-side slices: largest first, Other last. [moneyOut] is the
  /// debit side.
  List<CategoryBucket> side({required bool moneyOut}) {
    final raw =
        [
          for (final b in buckets)
            if (b.centsOn(moneyOut: moneyOut) != 0) b,
        ]..sort((a, b) {
          final c = b
              .centsOn(moneyOut: moneyOut)
              .abs()
              .compareTo(a.centsOn(moneyOut: moneyOut).abs());
          return c != 0 ? c : a.name.compareTo(b.name);
        });
    final total = moneyOut ? outCents.abs() : inCents;
    if (total == 0 || raw.isEmpty) return const [];

    final kept = <CategoryBucket>[];
    var otherCents = 0;
    var otherCount = 0;
    var otherGroups = 0;
    for (var i = 0; i < raw.length; i++) {
      final b = raw[i];
      final abs = b.centsOn(moneyOut: moneyOut).abs();
      final small = abs * 100 < total * 2; // strictly < 2%
      if (small || i >= 8) {
        otherCents += b.centsOn(moneyOut: moneyOut);
        otherCount += b.count;
        otherGroups++;
      } else {
        kept.add(b);
      }
    }
    if (otherGroups > 0 && otherCents != 0) {
      kept.add(
        CategoryBucket(
          id: otherBucketId,
          name: otherName,
          color: otherColor,
          inCents: moneyOut ? 0 : otherCents,
          outCents: moneyOut ? otherCents : 0,
          count: otherCount,
          groupedCount: otherGroups,
        ),
      );
    }
    return kept;
  }
}

/// Client-side category totals from [occurrences] (typically
/// `BalanceSeries.occurrences`, never sync pins).
CategoryTotals summarizeCategories({
  required Iterable<Occurrence> occurrences,
  required DateTime? start,
  required DateTime? end,
  required Map<String, BudgetEvent> events,
  required List<Category> categories,
  bool Function(String eventId)? activeOf,
}) {
  final cats = {for (final c in categories) c.id: c};
  final from = start == null ? null : dateOnly(start);
  final to = end == null ? null : dateOnly(end);
  final acc = <String, CategoryBucket>{};
  var inCents = 0;
  var outCents = 0;

  for (final o in occurrences) {
    if (o.isSync) continue;
    if (!countsInDayTotals(o)) continue;
    final t = events[o.eventId];
    if (t == null) continue;
    final active = activeOf?.call(o.eventId) ?? t.active;
    if (!active) continue;
    final day = dateOnly(o.date);
    if (from != null && day.isBefore(from)) continue;
    if (to != null && day.isAfter(to)) continue;

    final cents = decimalCents(o.signedDelta);
    if (cents == 0) continue;
    if (cents > 0) {
      inCents += cents;
    } else {
      outCents += cents;
    }

    late final CategoryBucket seed;
    if (isInterest(o)) {
      seed = const CategoryBucket(
        id: interestBucketId,
        name: loanInterestName,
        color: loanInterestColor,
        inCents: 0,
        outCents: 0,
        count: 0,
      );
    } else {
      final id = t.categoryId;
      if (id == null || id.isEmpty) {
        seed = const CategoryBucket(
          id: uncategorisedBucketId,
          name: uncategorisedName,
          color: uncategorisedColor,
          inCents: 0,
          outCents: 0,
          count: 0,
        );
      } else {
        final c = cats[id];
        final parent = c?.parentId == null ? null : cats[c!.parentId!];
        seed = CategoryBucket(
          id: id,
          name: c?.name ?? t.name,
          color: colorFromHex(c?.color) ?? uncategorisedColor,
          inCents: 0,
          outCents: 0,
          count: 0,
          parentName: parent?.name,
        );
      }
    }
    acc[seed.id] = (acc[seed.id] ?? seed).plus(cents);
  }

  final buckets = acc.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  return CategoryTotals(buckets: buckets, inCents: inCents, outCents: outCents);
}
