import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/models.dart';
import '../engine/balance_engine.dart';
import '../engine/balance_insights.dart';
import '../repo/stream_repo.dart';
import '../repo/event_repo.dart';
import 'json_helpers.dart';
import 'events.dart' show parseEventBody;
import 'loan_fields.dart';
import '../domain/enums.dart' show EventKind;

/// Longest span (~200 years, seed included) a balance, projection, goal or
/// insights request may walk; pickers allow 1970..2100 and the widest view
/// is 20 years. Unbounded ranges let any viewer make the server compute
/// and encode millions of daily points (year 1..9999 took ~12 s).
const maxBalanceRangeDays = 73050;

/// Throws a [FormatException] (400) when [to] is before [from] or the span
/// exceeds [maxBalanceRangeDays]. The engine walks from the stream's [seed]
/// (opening balances), so the span is measured from the earlier of the two.
void checkBalanceRange(DateTime from, DateTime to, {DateTime? seed}) {
  if (to.isBefore(from)) throw FormatException('to must not be before from');
  final start = seed != null && seed.isBefore(from) ? seed : from;
  if (to.difference(start).inDays > maxBalanceRangeDays) {
    throw FormatException(
        'range too long: at most $maxBalanceRangeDays days per request');
  }
}

/// Registers `GET /<id>/balance` on [router].
void attachBalanceRoutes(Router router, Session conn) {
  final streams = StreamRepo(conn);
  final events = EventRepo(conn);

  router.get('/<id>/balance', (Request request, String id) async {
    try {
      final stream = await streams.get(id);
      if (stream == null) return jsonError(404, 'stream not found');

      final params = request.url.queryParameters;
      final fromRaw = params['from'];
      final toRaw = params['to'];
      if (fromRaw == null || toRaw == null) {
        return jsonError(
            400, 'from and to query params are required (YYYY-MM-DD)');
      }
      final from = parseDate(fromRaw);
      final to = parseDate(toRaw);
      checkBalanceRange(from, to, seed: stream.seedDate);

      final eventList = await events.listByStream(id);
      final skipped = await events.skipsForStream(id);

      final series = BalanceEngine.compute(
        seedBalance: stream.seedBalance,
        seedDate: stream.seedDate,
        events: eventList,
        eventOrder: stream.eventOrder,
        from: from,
        to: to,
        skipped: skipped,
      );

      return jsonOk({
        'points': series.points.map((p) => p.toJson()).toList(),
        'occurrences': series.occurrences.map((o) => o.toJson()).toList(),
      });
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });

  /// `POST /<id>/project`: the balance as if [events] (unsaved, same
  /// shape as a create body) were added. Nothing is stored.
  router.post('/<id>/project', (Request request, String id) async {
    try {
      final stream = await streams.get(id);
      if (stream == null) return jsonError(404, 'stream not found');
      final body = await readJsonObject(request);
      final from = parseDate(requireString(body, 'from'));
      final to = parseDate(requireString(body, 'to'));
      checkBalanceRange(from, to, seed: stream.seedDate);
      final raw = body['events'];
      if (raw is! List) {
        return jsonError(400, 'events must be an array');
      }
      final extra = <BudgetEvent>[];
      // Saved events an item stands in for (`replacesEventId`, e.g. the
      // loan being edited in a live preview): left out of the walk.
      final replaced = <String>{};
      for (var i = 0; i < raw.length; i++) {
        final item = raw[i];
        if (item is! Map<String, dynamic>) {
          return jsonError(400, 'events[$i] must be an object');
        }
        final rep = item['replacesEventId'];
        if (rep != null) {
          if (rep is! String) {
            return jsonError(400, 'events[$i].replacesEventId must be an id');
          }
          replaced.add(rep);
        }
        final body = {...item}..remove('replacesEventId');
        final kind = parseCreateKind(body);
        final p = parseEventBody(body);
        final terms = kind.terms(p);
        extra.add(BudgetEvent(
          kind: kind.kind,
          loan: terms,
          id: 'preview-$i',
          streamId: id,
          name: p.name,
          direction: p.direction,
          amount: p.amount,
          startDate: p.startDate,
          recurrenceMode: p.recurrenceMode,
          interval: p.interval,
          unit: p.unit,
          days: p.days,
          endMode: p.endMode,
          endDate: p.endDate,
          occurrenceCount: p.occurrenceCount,
          enabled: true,
          createdAt: DateTime.now().toUtc(),
        ));
      }
      final existing = [
        for (final e in await events.listByStream(id))
          if (!replaced.contains(e.id)) e,
      ];
      final loans = [...existing, ...extra].where((e) => e.isLoan).length;
      if (loans > 1 && extra.any((e) => e.kind == EventKind.loan)) {
        return jsonError(409, streamHasLoan);
      }
      final series = BalanceEngine.compute(
        seedBalance: stream.seedBalance,
        seedDate: stream.seedDate,
        events: [...existing, ...extra],
        eventOrder: stream.eventOrder,
        from: from,
        to: to,
        skipped: await events.skipsForStream(id),
      );
      return jsonOk({
        'points': series.points.map((p) => p.toJson()).toList(),
      });
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });

  /// `GET /<id>/insights?from=YYYY-MM-DD&days=365&horizonDays=1825`:
  /// lowest closing balance over `days` from `from`, and the first dates
  /// below the alert threshold and below zero within `horizonDays`.
  router.get('/<id>/insights', (Request request, String id) async {
    try {
      final stream = await streams.get(id);
      if (stream == null) return jsonError(404, 'stream not found');
      final q = request.url.queryParameters;
      final from =
          q['from'] == null ? DateTime.now().toUtc() : parseDate(q['from']!);
      final days = int.tryParse(q['days'] ?? '') ?? 365;
      final horizon = int.tryParse(q['horizonDays'] ?? '') ?? 1825;
      if (days < 1 || horizon < 1 || days > 36500 || horizon > 36500) {
        return jsonError(400, 'days and horizonDays must be 1..36500');
      }
      final start = DateTime.utc(from.year, from.month, from.day);
      final end = start.add(Duration(days: horizon > days ? horizon : days));
      checkBalanceRange(start, end, seed: stream.seedDate);
      final series = BalanceEngine.compute(
        seedBalance: stream.seedBalance,
        seedDate: stream.seedDate,
        events: await events.listByStream(id),
        eventOrder: stream.eventOrder,
        from: start,
        to: end,
        skipped: await events.skipsForStream(id),
      );
      final insights = BalanceInsights.of(
        series.points,
        threshold: stream.lossThreshold.toDouble(),
        lowestThrough: start.add(Duration(days: days - 1)),
      );
      return jsonOk({
        'from': formatDate(start),
        'days': days,
        'horizonDays': horizon,
        'threshold': stream.lossThreshold.toString(),
        ...insights.toJson(),
        // A loan stream runs below zero by design: no alert / zero dates.
        if (stream.hasLoan) ...{
          'alertDate': null,
          'zeroDate': null,
          'loan': true,
        },
      });
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });
}
