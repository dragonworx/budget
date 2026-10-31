import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../repo/category_repo.dart';
import '../repo/event_repo.dart';
import 'categories.dart';
import 'loan_fields.dart';
import 'offset_link.dart';
import '../repo/stream_repo.dart';
import 'json_helpers.dart';

Router eventsRouter(Session conn) {
  final events = EventRepo(conn);
  final router = Router();

  router.get('/<id>', (Request request, String id) async {
    final event = await events.get(id);
    if (event == null) return jsonError(404, 'event not found');
    return jsonOk(event.toJson());
  });

  router.patch('/<id>', (Request request, String id) async {
    try {
      final body = await readJsonObject(request);
      final existing = await events.get(id);
      if (existing == null) return jsonError(404, 'event not found');
      final loanTerms = parsePatchLoan(body, existing);
      final loanStream = await StreamRepo(conn).get(existing.streamId);
      if (loanStream == null) return jsonError(404, 'event not found');
      final offsetIds = await checkOffsetLink(
        conn: conn,
        request: request,
        loanStream: loanStream,
        body: body,
        kindIsLoan: existing.isLoan,
        terms: loanTerms ?? existing.loan,
        existing: existing,
      );

      RecurrenceMode? recurrenceMode;
      if (body.containsKey('recurrenceMode')) {
        recurrenceMode =
            RecurrenceMode.parse(requireString(body, 'recurrenceMode'));
      }
      EndMode? endMode;
      if (body.containsKey('endMode')) {
        endMode = EndMode.parse(requireString(body, 'endMode'));
      }
      RecurrenceUnit? unit;
      if (body.containsKey('unit')) {
        final u = body['unit'];
        unit = u == null ? null : RecurrenceUnit.parse(u.toString());
      }

      var interval = optionalInt(body, 'interval');
      var clearInterval =
          body.containsKey('interval') && body['interval'] == null;
      var clearUnit = body.containsKey('unit') && body['unit'] == null;
      final f = parseFrequencyFields(body);
      if (f.frequency != null) {
        final fr = f.frequency!;
        recurrenceMode =
            fr.repeats ? RecurrenceMode.every : RecurrenceMode.once;
        interval = fr.legacyInterval;
        unit = fr.repeats ? RecurrenceUnit.parse(fr.legacyUnit!) : null;
        clearInterval = clearUnit = !fr.repeats;
      }
      final clearEndDate =
          body.containsKey('endDate') && body['endDate'] == null;
      final clearCount = body.containsKey('occurrenceCount') &&
          body['occurrenceCount'] == null;

      final event = await txOf(conn).runTx((tx) async {
        final events = EventRepo(tx);
        final name = await resolveEventCategory(tx, existing.streamId, body,
            legacyName: optionalString(body, 'name'));
        var updated = (await events.update(
          id,
          name: name,
          direction: body.containsKey('direction')
              ? Direction.parse(requireString(body, 'direction'))
              : null,
          amount:
              body.containsKey('amount') ? parseDecimal(body['amount']) : null,
          startDate: body.containsKey('startDate')
              ? parseDate(requireString(body, 'startDate'))
              : null,
          recurrenceMode: recurrenceMode,
          interval: interval,
          unit: unit,
          days: f.days,
          endMode: endMode,
          endDate: body.containsKey('endDate') && body['endDate'] != null
              ? parseDate(body['endDate'].toString())
              : null,
          occurrenceCount: optionalInt(body, 'occurrenceCount'),
          enabled: optionalBool(body, 'enabled'),
          clearInterval: clearInterval,
          clearUnit: clearUnit,
          clearEndDate: clearEndDate,
          clearOccurrenceCount: clearCount,
          color: parseEventColor(body['color']),
          clearColor: body.containsKey('color') &&
              parseEventColor(body['color']) == null,
          loan: loanTerms,
          offsetStreamIds: offsetIds,
        ))!;
        // Transfers: retarget / link / unlink, then mirror onto the peer.
        if (body.containsKey('transferToStreamId')) {
          final to = body['transferToStreamId']?.toString();
          if (to == null) {
            if (updated.transfer != null) await events.unlink(updated);
          } else if (updated.transfer?.peerId != null) {
            await events.movePeer(updated, to);
          } else {
            await events.linkNewPeer(updated, to);
          }
          updated = (await events.get(id))!;
        }
        // A schedule change can orphan overrides: drop those that no
        // longer sit on an occurrence.
        await events.pruneOverrides(id);
        await events.syncPeer(updated);
        // Legacy `color`: an event's colour is its category's now, so it
        // recolours the category (and the transfer side's).
        final legacyColor = parseEventColor(body['color']);
        if (legacyColor != null) {
          await tx.execute(
            Sql.named('''
              UPDATE categories SET color = @c WHERE id IN (
                SELECT category_id FROM events WHERE id = ANY (@ids::uuid[]))
            '''),
            parameters: {
              'c': legacyColor,
              'ids': [
                id,
                if (updated.transfer?.peerId != null) updated.transfer!.peerId!
              ],
            },
          );
        }
        return (await events.get(id))!;
      });
      return jsonOk(event.toJson());
    } on OffsetLinkError catch (e) {
      return jsonError(e.status, e.message);
    } on CategoryNameException catch (e) {
      return categoryNameError(e);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  router.delete('/<id>', (Request request, String id) async {
    final ok = await txOf(conn).runTx((tx) => EventRepo(tx).delete(id));
    if (!ok) return jsonError(404, 'event not found');
    return Response(204);
  });

  router.put('/<id>/skips/<date>',
      (Request request, String id, String date) async {
    try {
      final event = await events.get(id);
      if (event == null) return jsonError(404, 'event not found');
      if (event.isLoan) return jsonError(400, loanNotSupported);
      final body = await readJsonObject(request);
      final skipped = body['skipped'];
      if (skipped is! bool) {
        return jsonError(400, 'skipped must be a boolean');
      }
      final d = parseDate(date);
      await txOf(conn).runTx((tx) async {
        final repo = EventRepo(tx);
        await repo.setSkip(id, d, skipped);
        final peerId = event.transfer?.peerId;
        if (peerId != null) await repo.setSkip(peerId, d, skipped);
      });
      return jsonOk({
        'eventId': id,
        'date': formatDate(d),
        'skipped': skipped,
      });
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  // Once-off override of one occurrence's amount / direction.
  router.put('/<id>/overrides/<date>',
      (Request request, String id, String date) async {
    try {
      final target = await events.get(id);
      if (target == null) return jsonError(404, 'event not found');
      if (target.isLoan) return jsonError(400, loanNotSupported);
      final body = await readJsonObject(request);
      final amount = parseDecimal(body['amount']);
      final direction = Direction.parse(requireString(body, 'direction'));
      final d = parseDate(date);
      final t = await txOf(conn).runTx((tx) => EventRepo(tx)
          .setOverride(id, d, direction: direction, amount: amount));
      return jsonOk(t.toJson());
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  // Clear one override (restores the natural series value).
  router.delete('/<id>/overrides/<date>',
      (Request request, String id, String date) async {
    try {
      final target = await events.get(id);
      if (target == null) return jsonError(404, 'event not found');
      if (target.isLoan) return jsonError(400, loanNotSupported);
      final d = parseDate(date);
      final t = await txOf(conn).runTx((tx) async {
        final repo = EventRepo(tx);
        await repo.clearOverrides(id, date: d);
        return (await repo.get(id))!;
      });
      return jsonOk(t.toJson());
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  // Clear every override of the series.
  router.delete('/<id>/overrides', (Request request, String id) async {
    final target = await events.get(id);
    if (target == null) return jsonError(404, 'event not found');
    if (target.isLoan) return jsonError(400, loanNotSupported);
    final (t, removed) = await txOf(conn).runTx((tx) async {
      final repo = EventRepo(tx);
      final n = await repo.clearOverrides(id);
      return ((await repo.get(id))!, n);
    });
    return jsonOk({...t.toJson(), 'cleared': removed});
  });

  // "From now on": split the series at an occurrence, atomically.
  router.post('/<id>/split', (Request request, String id) async {
    try {
      final existing = await events.get(id);
      if (existing == null) {
        return jsonError(404, 'event not found');
      }
      if (existing.isLoan) return jsonError(400, loanNotSupported);
      final body = await readJsonObject(request);
      final date = parseDate(requireString(body, 'date'));
      var unit = body['unit'] == null
          ? null
          : RecurrenceUnit.parse(body['unit'].toString());
      var interval = optionalInt(body, 'interval');
      final f = parseFrequencyFields(body);
      if (f.frequency != null) {
        if (!f.frequency!.repeats) {
          throw const FormatException('a split series must repeat');
        }
        interval = f.frequency!.legacyInterval;
        unit = RecurrenceUnit.parse(f.frequency!.legacyUnit!);
      }
      final r = await txOf(conn).runTx((tx) async => EventRepo(tx).splitAt(
            id,
            date,
            name: await resolveEventCategory(tx, existing.streamId, body,
                    legacyName: optionalString(body, 'name')) ??
                existing.name,
            direction: Direction.parse(requireString(body, 'direction')),
            amount: parseDecimal(body['amount']),
            interval: interval,
            unit: unit,
            days: f.days,
            enabled: optionalBool(body, 'enabled'),
            color: parseEventColor(body['color']),
            clearColor: body.containsKey('color') &&
                parseEventColor(body['color']) == null,
          ));
      return jsonOk({
        ...r.original.toJson(),
        'original': r.original.toJson(),
        'created': r.created?.toJson(),
      });
    } on CategoryNameException catch (e) {
      return categoryNameError(e);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  return router;
}

class ParsedEventBody {
  ParsedEventBody({
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
    this.color,
    this.days = const [],
  });

  final String? color;
  final List<int> days;
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
}

ParsedEventBody parseEventBody(Map<String, dynamic> body) {
  var recurrenceMode =
      RecurrenceMode.parse(optionalString(body, 'recurrenceMode') ?? 'once');
  final endMode = EndMode.parse(optionalString(body, 'endMode') ?? 'never');
  var unitRaw = optionalString(body, 'unit');
  var interval = optionalInt(body, 'interval');
  final f = parseFrequencyFields(body);
  if (f.frequency != null) {
    final fr = f.frequency!;
    recurrenceMode = fr.repeats ? RecurrenceMode.every : RecurrenceMode.once;
    interval = fr.legacyInterval;
    unitRaw = fr.legacyUnit;
  } else if (f.days != null && f.days!.isNotEmpty) {
    // Legacy cadence plus days: validated as one rule.
    Frequency.fromLegacy(
      once: recurrenceMode == RecurrenceMode.once,
      interval: interval,
      unit: unitRaw,
      days: f.days!,
    );
  }

  return ParsedEventBody(
    days: f.days ?? const [],
    name: optionalString(body, 'name') ?? '',
    direction: Direction.parse(requireString(body, 'direction')),
    amount: parseDecimal(body['amount']),
    startDate: parseDate(requireString(body, 'startDate')),
    recurrenceMode: recurrenceMode,
    interval: interval,
    unit: unitRaw == null ? null : RecurrenceUnit.parse(unitRaw),
    endMode: endMode,
    endDate: optionalString(body, 'endDate') == null
        ? null
        : parseDate(body['endDate'].toString()),
    occurrenceCount: optionalInt(body, 'occurrenceCount'),
    enabled: optionalBool(body, 'enabled') ?? true,
    color: parseEventColor(body['color']),
  );
}

/// The structured frequency of an event body: `frequency` =
/// `{"rule": "weekly", "interval": 1, "days": [1, 2]}` (it then wins over
/// the legacy recurrenceMode / interval / unit fields), and / or a top
/// level `days` list next to the legacy fields. Days must be whole
/// numbers in range for the rule's family; the stored list is sorted with
/// duplicates removed. Throws [FormatException] (a 400) otherwise.
({Frequency? frequency, List<int>? days}) parseFrequencyFields(
    Map<String, dynamic> body) {
  List<int>? days;
  if (body.containsKey('days')) {
    final raw = body['days'];
    if (raw == null) {
      days = const [];
    } else if (raw is! List || raw.any((d) => d is! int)) {
      throw const FormatException('days must be a list of whole numbers');
    } else {
      days = [for (final d in raw) d as int];
    }
  }
  final raw = body['frequency'];
  if (raw == null) return (frequency: null, days: days);
  if (raw is! Map) {
    throw const FormatException(
        'frequency must be an object {rule, interval, days}');
  }
  final m = raw.cast<String, dynamic>();
  final rd = m['days'];
  if (rd != null && (rd is! List || rd.any((d) => d is! int))) {
    throw const FormatException(
        'frequency.days must be a list of whole numbers');
  }
  if (m['interval'] != null && m['interval'] is! int) {
    throw const FormatException('frequency.interval must be a whole number');
  }
  final f = Frequency.fromJson(m);
  return (frequency: f, days: f.days);
}
