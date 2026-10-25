import 'dart:convert';

import '../../boot/page_stub.dart'
    if (dart.library.js_interop) '../../boot/page_web.dart'
    as page;
import 'chart_geometry.dart';
import 'view_units.dart';

/// Left edge limits as day coordinates: 1900-01-01 .. 2200-01-01 (the
/// server clamps to the same).
const double minSavedStartDay = -25567;
const double maxSavedStartDay = 84006;

/// Largest balance magnitude a saved range may reach.
const double maxSavedBalance = 1e13;

/// One member's last timeline view of a stream: the left edge (a calendar
/// day coordinate, see [dayCoord]), the span, the unit, and the visible
/// balance range (null: not fitted yet, use the default).
class SavedView {
  const SavedView({
    required this.start,
    required this.days,
    this.unit,
    this.yMin,
    this.yMax,
  });

  final double start;
  final double days;
  final ViewUnit? unit;
  final double? yMin;
  final double? yMax;

  DateTime get startDate => dateFromDayCoord(start);

  BalanceExtents? get yRange =>
      yMin == null || yMax == null ? null : BalanceExtents(yMin!, yMax!);

  /// Validated and clamped; null when unusable.
  static SavedView? fromJson(Object? json) {
    if (json is! Map) return null;
    double? n(Object? v) =>
        v is num && v.toDouble().isFinite ? v.toDouble() : null;
    final start = n(json['start']);
    final days = n(json['days']);
    if (start == null || days == null) return null;
    final unitName = json['unit'];
    final unit = ViewUnit.values.where((u) => u.name == unitName).firstOrNull;
    var lo = n(json['yMin']);
    var hi = n(json['yMax']);
    if (lo != null && hi != null) {
      lo = lo.clamp(-maxSavedBalance, maxSavedBalance).toDouble();
      hi = hi.clamp(-maxSavedBalance, maxSavedBalance).toDouble();
    }
    if (lo == null || hi == null || !(lo < hi)) lo = hi = null;
    return SavedView(
      start: start.clamp(minSavedStartDay, maxSavedStartDay).toDouble(),
      days: days.clamp(minVisibleDays, maxVisibleDays).toDouble(),
      unit: unit,
      yMin: lo,
      yMax: hi,
    );
  }

  Map<String, Object?> toJson() => {
    'start': start,
    'days': days,
    'unit': unit?.name,
    'yMin': yMin,
    'yMax': yMax,
  };

  bool sameAs(SavedView? o) =>
      o != null &&
      (start - o.start).abs() < 1e-7 &&
      (days - o.days).abs() < 1e-7 &&
      unit == o.unit &&
      yMin == o.yMin &&
      yMax == o.yMax;

  @override
  String toString() => 'SavedView(${toJson()})';
}

/// This browser's copy of each saved view (local storage), per signed-in
/// user per stream: restores instantly, before the server copy arrives.
class SavedViewStore {
  const SavedViewStore();

  static String key(String userId, String streamId) =>
      'budget_view:$userId:$streamId';

  SavedView? load(String userId, String streamId) {
    final raw = page.localGet(key(userId, streamId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return SavedView.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  void save(String userId, String streamId, SavedView view) =>
      page.localSet(key(userId, streamId), jsonEncode(view.toJson()));
}
