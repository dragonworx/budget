import 'dart:convert';

import 'package:decimal/decimal.dart';

import 'enums.dart';

// Import format (see the /transaction skill, named before the rename): every date is a whole number
// of calendar days relative to a date root — the day the user selected on
// the timeline, sent as `?root=YYYY-MM-DD`. `startOffset`, `end.endOffset`
// (mode "until_offset") and `skippedOffsets` resolve to root + n days with
// date-only arithmetic, so DST and month/year lengths never shift a date.
// Absolute dates (startDate, endDate, skippedDates, mode "until_date") are
// rejected with a pointer to the offset field to use instead.

/// Largest accepted |offset| (about 100 years either way).
const maxImportOffset = 36600;

/// [root] + [days] calendar days, as a UTC midnight date.
DateTime resolveOffset(DateTime root, int days) =>
    DateTime.utc(root.year, root.month, root.day + days);

/// Parses a `root` query value (YYYY-MM-DD) or returns null.
DateTime? parseImportRoot(String? v) => _date(v);

/// One validation problem in an import payload.
class ImportIssue {
  ImportIssue(this.index, this.field, this.message);

  /// Array index of the offending item, or null for payload-level problems.
  final int? index;
  final String? field;
  final String message;

  Map<String, dynamic> toJson() => {
        'index': index,
        'field': field,
        'message': message,
      };

  @override
  String toString() {
    final at = index == null ? '' : '[$index]';
    final f = field == null ? '' : '${at.isEmpty ? '' : '.'}$field';
    final where = '$at$f';
    return where.isEmpty ? message : '$where: $message';
  }
}

/// Thrown when any item is invalid; nothing is imported.
class ImportValidationException implements Exception {
  ImportValidationException(this.issues);
  final List<ImportIssue> issues;
  @override
  String toString() => issues.join('; ');
}

/// A validated `EventImport`, ready to insert.
class ImportItem {
  ImportItem({
    required this.index,
    this.id,
    required this.name,
    required this.direction,
    required this.amount,
    required this.startDate,
    required this.recurrenceMode,
    this.interval,
    this.unit,
    required this.endMode,
    this.endDate,
    this.occurrenceCount,
    required this.enabled,
    required this.skippedDates,
    this.startOffset = 0,
    this.endOffset,
    this.skippedOffsets = const [],
  });

  final int index;
  final String? id;
  final String name;
  final Direction direction;
  final Decimal amount;
  final DateTime startDate;
  final RecurrenceMode recurrenceMode;
  final int? interval;
  final RecurrenceUnit? unit;
  final EndMode endMode;
  final DateTime? endDate;
  final int? occurrenceCount;
  final bool enabled;
  final List<DateTime> skippedDates;
  final int startOffset;
  final int? endOffset;
  final List<int> skippedOffsets;

  Map<String, dynamic> toJson() => {
        'index': index,
        'id': id,
        'name': name,
        'direction': direction.name,
        'amount': amount.toString(),
        'startDate': _fmt(startDate),
        'recurrenceMode': recurrenceMode.name,
        'interval': interval,
        'unit': unit?.name,
        'endMode': endMode.apiName,
        'endDate': endDate == null ? null : _fmt(endDate!),
        'occurrenceCount': occurrenceCount,
        'enabled': enabled,
        'skippedDates': skippedDates.map(_fmt).toList(),
        'startOffset': startOffset,
        'endOffset': endOffset,
        'skippedOffsets': skippedOffsets,
      };
}

String _fmt(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final _fence = RegExp(r'^\s*```[a-zA-Z0-9_-]*\s*\n?([\s\S]*?)\n?\s*```\s*$');
final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Strips a surrounding Markdown code fence (```json ... ```), if any.
String stripCodeFence(String raw) {
  final m = _fence.firstMatch(raw);
  return m == null ? raw.trim() : m.group(1)!.trim();
}

/// Decodes the raw paste: a JSON array of `EventImport`, a single
/// object, optionally wrapped in a ```json fence. Also accepts an object of
/// the form `{"events": [...]}`.
List<Object?> decodeImportPayload(String raw) {
  final text = stripCodeFence(raw);
  if (text.isEmpty) {
    throw ImportValidationException(
        [ImportIssue(null, null, 'Nothing to import: paste a JSON array')]);
  }
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw ImportValidationException(
        [ImportIssue(null, null, 'Invalid JSON: ${e.message}')]);
  }
  // A JSON string whose content is the paste (what a JSON client sends).
  if (decoded is String) return decodeImportPayload(decoded);
  if (decoded is List) return decoded;
  if (decoded is Map && decoded['events'] is List) {
    return decoded['events'] as List;
  }
  // Legacy wrapper key from before the Pools/Transactions rename.
  if (decoded is Map && decoded['transactions'] is List) {
    return decoded['transactions'] as List;
  }
  if (decoded is Map) return [decoded];
  throw ImportValidationException(
      [ImportIssue(null, null, 'Expected a JSON array of events')]);
}

DateTime? _date(Object? v) {
  if (v is! String || !_isoDate.hasMatch(v)) return null;
  final p = v.split('-').map(int.parse).toList();
  final d = DateTime.utc(p[0], p[1], p[2]);
  // Reject rollovers like 2026-02-30.
  if (d.year != p[0] || d.month != p[1] || d.day != p[2]) return null;
  return d;
}

/// A whole-number day offset: an int, or an integral finite double (3.0).
/// Strings ("3"), fractions (1.5), NaN and other types are rejected.
int? _offset(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite && v == v.roundToDouble()) return v.toInt();
  return null;
}

String _offsetProblem(Object? v) => v is String
    ? 'must be a whole number of days, not a string ("$v")'
    : 'must be a whole number of days (e.g. 0, 14, -3)';

/// Validates every item, collecting all issues, resolving day offsets
/// against [root] (the selected timeline day). Throws
/// [ImportValidationException] if any item is invalid.
List<ImportItem> parseImport(String raw, {required DateTime root}) {
  root = DateTime.utc(root.year, root.month, root.day);
  final list = decodeImportPayload(raw);
  if (list.isEmpty) {
    throw ImportValidationException(
        [ImportIssue(null, null, 'The array is empty')]);
  }
  final issues = <ImportIssue>[];
  final items = <ImportItem>[];
  final seenIds = <String, int>{};

  for (var i = 0; i < list.length; i++) {
    final raw = list[i];
    final before = issues.length;
    void bad(String? field, String msg) =>
        issues.add(ImportIssue(i, field, msg));
    if (raw is! Map) {
      bad(null, 'must be an object');
      continue;
    }
    final m = raw.cast<String, Object?>();

    const known = {
      'id',
      'name',
      'direction',
      'amount',
      'startOffset',
      'recurrence',
      'end',
      'enabled',
      'skippedOffsets',
    };
    // Absolute dates from the old format: rejected with a pointer to the
    // offset field that replaces them.
    const absolute = {
      'startDate': 'startOffset',
      'endDate': 'end: {"mode":"until_offset","endOffset":N}',
      'skippedDates': 'skippedOffsets',
    };
    // Older files may carry project / account fields (projects are gone,
    // accounts are now streams): ignored.
    const legacy = {'projectId', 'projectName', 'accountId', 'accountName'};
    for (final k in m.keys) {
      final use = absolute[k];
      if (use != null) {
        bad(
            k,
            'absolute dates are not accepted; use $use '
            '(whole days from the selected day)');
      } else if (!known.contains(k) && !legacy.contains(k)) {
        bad(k, 'unknown field');
      }
    }

    String? id;
    if (m['id'] != null) {
      if (m['id'] is! String || !_uuid.hasMatch(m['id'] as String)) {
        bad('id', 'must be a UUID string');
      } else {
        id = (m['id'] as String).toLowerCase();
        final dup = seenIds[id];
        if (dup != null) bad('id', 'duplicate of item [$dup]');
        seenIds[id] = i;
      }
    }

    final nameRaw = m['name'];
    if (nameRaw != null && nameRaw is! String) bad('name', 'must be a string');
    final name = nameRaw is String ? nameRaw.trim() : '';

    Direction? direction;
    final dirRaw = m['direction'];
    if (dirRaw == 'credit' || dirRaw == 'debit') {
      direction = Direction.parse(dirRaw as String);
    } else {
      bad(
          'direction',
          dirRaw == null
              ? 'is required ("credit" or "debit")'
              : 'must be "credit" or "debit"');
    }

    Decimal? amount;
    final amtRaw = m['amount'];
    if (amtRaw is num || amtRaw is String) {
      amount = Decimal.tryParse(amtRaw.toString().trim());
      if (amount == null) {
        bad('amount', 'must be a number or numeric string');
      } else if (amount < Decimal.zero) {
        bad('amount', 'must be >= 0 (use direction for sign)');
        amount = null;
      }
    } else {
      bad(
          'amount',
          amtRaw == null
              ? 'is required'
              : 'must be a number or numeric string');
    }

    DateTime? startDate;
    final startOffset = _offset(m['startOffset']);
    if (startOffset == null) {
      if (!m.containsKey('startDate')) {
        bad(
            'startOffset',
            m['startOffset'] == null
                ? 'is required (whole days from the selected day; 0 = that day)'
                : _offsetProblem(m['startOffset']));
      }
    } else if (startOffset.abs() > maxImportOffset) {
      bad('startOffset', 'is too far from the selected day');
    } else {
      startDate = resolveOffset(root, startOffset);
    }

    RecurrenceMode? mode;
    int? interval;
    RecurrenceUnit? unit;
    final rec = m['recurrence'];
    if (rec is! Map) {
      bad('recurrence', rec == null ? 'is required' : 'must be an object');
    } else if (rec['mode'] == 'once') {
      mode = RecurrenceMode.once;
    } else if (rec['mode'] == 'every') {
      mode = RecurrenceMode.every;
      final iv = rec['interval'];
      if (iv is int && iv >= 1) {
        interval = iv;
      } else if (iv is num && iv == iv.roundToDouble() && iv >= 1) {
        interval = iv.toInt();
      } else {
        bad('recurrence.interval', 'must be an integer >= 1');
      }
      final u = rec['unit'];
      if (u is String && RecurrenceUnit.values.any((e) => e.name == u)) {
        unit = RecurrenceUnit.parse(u);
      } else {
        bad('recurrence.unit', 'must be one of days, weeks, months, years');
      }
    } else {
      bad('recurrence.mode', 'must be "once" or "every"');
    }

    var endMode = EndMode.never;
    DateTime? endDate;
    int? endOffset;
    int? count;
    final end = m['end'];
    if (end == null) {
      if (mode == RecurrenceMode.every) {
        bad('end', 'is required when recurrence.mode is "every"');
      }
    } else if (end is! Map) {
      bad('end', 'must be an object');
    } else {
      switch (end['mode']) {
        case 'never':
          endMode = EndMode.never;
        case 'until_offset':
          endMode = EndMode.untilDate;
          endOffset = _offset(end['endOffset']);
          if (endOffset == null) {
            bad(
                'end.endOffset',
                end['endOffset'] == null
                    ? 'is required for mode "until_offset"'
                    : _offsetProblem(end['endOffset']));
          } else if (endOffset.abs() > maxImportOffset) {
            bad('end.endOffset', 'is too far from the selected day');
            endOffset = null;
          } else {
            endDate = resolveOffset(root, endOffset);
            if (startOffset != null && endOffset < startOffset) {
              bad('end.endOffset', 'is before startOffset');
            }
          }
        case 'until_date':
          bad(
              'end.mode',
              '"until_date" (an absolute date) is not accepted; use '
                  '{"mode":"until_offset","endOffset":N} (whole days from the '
                  'selected day)');
        case 'count':
          endMode = EndMode.count;
          final c = end['occurrences'];
          if (c is int && c >= 1) {
            count = c;
          } else if (c is num && c == c.roundToDouble() && c >= 1) {
            count = c.toInt();
          } else {
            bad('end.occurrences', 'must be an integer >= 1');
          }
        default:
          bad('end.mode', 'must be "never", "until_offset" or "count"');
      }
      if (end.containsKey('endDate')) {
        bad(
            'end.endDate',
            'absolute dates are not accepted; use end.endOffset '
                '(whole days from the selected day)');
      }
      // A one-off has no recurrence end; store it as never.
      if (mode == RecurrenceMode.once) {
        endMode = EndMode.never;
        endDate = null;
        endOffset = null;
        count = null;
      }
    }

    final enabledRaw = m['enabled'];
    if (enabledRaw != null && enabledRaw is! bool) {
      bad('enabled', 'must be true or false');
    }

    final skipped = <DateTime>[];
    final skippedOffsets = <int>[];
    final sk = m['skippedOffsets'];
    if (sk != null) {
      if (sk is! List) {
        bad('skippedOffsets', 'must be an array of whole day offsets');
      } else {
        for (var j = 0; j < sk.length; j++) {
          final n = _offset(sk[j]);
          if (n == null) {
            bad('skippedOffsets[$j]', _offsetProblem(sk[j]));
          } else if (n.abs() > maxImportOffset) {
            bad('skippedOffsets[$j]', 'is too far from the selected day');
          } else if (!skippedOffsets.contains(n)) {
            skippedOffsets.add(n);
            skipped.add(resolveOffset(root, n));
          }
        }
      }
    }

    if (issues.length == before) {
      items.add(ImportItem(
        index: i,
        id: id,
        name: name,
        direction: direction!,
        amount: amount!,
        startDate: startDate!,
        recurrenceMode: mode!,
        interval: interval,
        unit: unit,
        endMode: endMode,
        endDate: endDate,
        occurrenceCount: count,
        enabled: enabledRaw as bool? ?? true,
        skippedDates: skipped,
        startOffset: startOffset!,
        endOffset: endOffset,
        skippedOffsets: skippedOffsets,
      ));
    }
  }
  if (issues.isNotEmpty) throw ImportValidationException(issues);
  return items;
}
