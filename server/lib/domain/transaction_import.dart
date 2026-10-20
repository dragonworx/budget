import 'dart:convert';

import 'package:decimal/decimal.dart';

import 'enums.dart';

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

/// A validated `TransactionImport`, ready to insert.
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

/// Decodes the raw paste: a JSON array of `TransactionImport`, a single
/// object, optionally wrapped in a ```json fence. Also accepts an object of
/// the form `{"transactions": [...]}`.
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
  if (decoded is Map && decoded['transactions'] is List) {
    return decoded['transactions'] as List;
  }
  if (decoded is Map) return [decoded];
  throw ImportValidationException(
      [ImportIssue(null, null, 'Expected a JSON array of transactions')]);
}

DateTime? _date(Object? v) {
  if (v is! String || !_isoDate.hasMatch(v)) return null;
  final p = v.split('-').map(int.parse).toList();
  final d = DateTime.utc(p[0], p[1], p[2]);
  // Reject rollovers like 2026-02-30.
  if (d.year != p[0] || d.month != p[1] || d.day != p[2]) return null;
  return d;
}

/// Validates every item, collecting all issues. Throws
/// [ImportValidationException] if any item is invalid.
List<ImportItem> parseImport(String raw) {
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
      'startDate',
      'recurrence',
      'end',
      'enabled',
      'skippedDates',
    };
    // Older files may carry project / account fields (projects are gone,
    // accounts are now pools): ignored.
    const legacy = {'projectId', 'projectName', 'accountId', 'accountName'};
    for (final k in m.keys) {
      if (!known.contains(k) && !legacy.contains(k)) bad(k, 'unknown field');
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

    final startDate = _date(m['startDate']);
    if (startDate == null) {
      bad(
          'startDate',
          m['startDate'] == null
              ? 'is required (YYYY-MM-DD)'
              : 'must be a valid YYYY-MM-DD date');
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
        case 'until_date':
          endMode = EndMode.untilDate;
          endDate = _date(end['endDate']);
          if (endDate == null) {
            bad('end.endDate', 'must be a valid YYYY-MM-DD date');
          } else if (startDate != null && endDate.isBefore(startDate)) {
            bad('end.endDate', 'is before startDate');
          }
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
          bad('end.mode', 'must be "never", "until_date" or "count"');
      }
      // A one-off has no recurrence end; store it as never.
      if (mode == RecurrenceMode.once) {
        endMode = EndMode.never;
        endDate = null;
        count = null;
      }
    }

    final enabledRaw = m['enabled'];
    if (enabledRaw != null && enabledRaw is! bool) {
      bad('enabled', 'must be true or false');
    }

    final skipped = <DateTime>[];
    final sk = m['skippedDates'];
    if (sk != null) {
      if (sk is! List) {
        bad('skippedDates', 'must be an array of YYYY-MM-DD dates');
      } else {
        for (var j = 0; j < sk.length; j++) {
          final d = _date(sk[j]);
          if (d == null) {
            bad('skippedDates[$j]', 'must be a valid YYYY-MM-DD date');
          } else if (!skipped.contains(d)) {
            skipped.add(d);
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
      ));
    }
  }
  if (issues.isNotEmpty) throw ImportValidationException(issues);
  return items;
}
