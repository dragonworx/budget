import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../repo/event_repo.dart';
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

      final clearInterval =
          body.containsKey('interval') && body['interval'] == null;
      final clearUnit = body.containsKey('unit') && body['unit'] == null;
      final clearEndDate =
          body.containsKey('endDate') && body['endDate'] == null;
      final clearCount = body.containsKey('occurrenceCount') &&
          body['occurrenceCount'] == null;

      final event = await txOf(conn).runTx((tx) async {
        final events = EventRepo(tx);
        var updated = (await events.update(
          id,
          name: optionalString(body, 'name'),
          direction: body.containsKey('direction')
              ? Direction.parse(requireString(body, 'direction'))
              : null,
          amount:
              body.containsKey('amount') ? parseDecimal(body['amount']) : null,
          startDate: body.containsKey('startDate')
              ? parseDate(requireString(body, 'startDate'))
              : null,
          recurrenceMode: recurrenceMode,
          interval: optionalInt(body, 'interval'),
          unit: unit,
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
        return (await events.get(id))!;
      });
      return jsonOk(event.toJson());
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
      if (await events.get(id) == null) {
        return jsonError(404, 'event not found');
      }
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
      if (await events.get(id) == null) {
        return jsonError(404, 'event not found');
      }
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
    if (await events.get(id) == null) {
      return jsonError(404, 'event not found');
    }
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
      if (await events.get(id) == null) {
        return jsonError(404, 'event not found');
      }
      final body = await readJsonObject(request);
      final date = parseDate(requireString(body, 'date'));
      final unit = body['unit'] == null
          ? null
          : RecurrenceUnit.parse(body['unit'].toString());
      final r = await txOf(conn).runTx((tx) => EventRepo(tx).splitAt(
            id,
            date,
            name: requireString(body, 'name'),
            direction: Direction.parse(requireString(body, 'direction')),
            amount: parseDecimal(body['amount']),
            interval: optionalInt(body, 'interval'),
            unit: unit,
            enabled: optionalBool(body, 'enabled'),
          ));
      return jsonOk({
        ...r.original.toJson(),
        'original': r.original.toJson(),
        'created': r.created?.toJson(),
      });
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
  });

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
  final recurrenceMode =
      RecurrenceMode.parse(optionalString(body, 'recurrenceMode') ?? 'once');
  final endMode = EndMode.parse(optionalString(body, 'endMode') ?? 'never');
  final unitRaw = optionalString(body, 'unit');

  return ParsedEventBody(
    name: optionalString(body, 'name') ?? '',
    direction: Direction.parse(requireString(body, 'direction')),
    amount: parseDecimal(body['amount']),
    startDate: parseDate(requireString(body, 'startDate')),
    recurrenceMode: recurrenceMode,
    interval: optionalInt(body, 'interval'),
    unit: unitRaw == null ? null : RecurrenceUnit.parse(unitRaw),
    endMode: endMode,
    endDate: optionalString(body, 'endDate') == null
        ? null
        : parseDate(body['endDate'].toString()),
    occurrenceCount: optionalInt(body, 'occurrenceCount'),
    enabled: optionalBool(body, 'enabled') ?? true,
  );
}
