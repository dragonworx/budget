import 'package:postgres/postgres.dart' hide Pool;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/middleware.dart';
import 'json_helpers.dart';

/// Span limits, matching the client's zoom limits (days).
const double minViewDays = 1;
const double maxViewDays = 12785;

/// Left edge limits as day coordinates: 1900-01-01 .. 2200-01-01.
const double minViewStartDay = -25567;
const double maxViewStartDay = 84006;

/// Largest balance magnitude a saved y-range may reach.
const double maxViewBalance = 1e13;

const viewUnits = {
  'day',
  'week',
  'weeks2',
  'weeks3',
  'month',
  'months2',
  'quarter',
  'months6',
  'year',
};

/// A member's saved timeline view of one stream.
class SavedStreamView {
  const SavedStreamView({
    required this.startDay,
    required this.days,
    this.unit,
    this.yMin,
    this.yMax,
    this.updatedAt,
  });

  final double startDay;
  final double days;
  final String? unit;
  final double? yMin;
  final double? yMax;
  final DateTime? updatedAt;

  Map<String, Object?> toJson() => {
        'start': startDay,
        'days': days,
        'unit': unit,
        'yMin': yMin,
        'yMax': yMax,
        if (updatedAt != null)
          'updatedAt': updatedAt!.toUtc().toIso8601String(),
      };
}

double _clamp(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

double? _num(Map<String, dynamic> body, String key, {bool required = false}) {
  final v = body[key];
  if (v == null) {
    if (required) throw FormatException('$key is required');
    return null;
  }
  if (v is! num) throw FormatException('$key must be a number');
  final d = v.toDouble();
  if (!d.isFinite) throw FormatException('$key must be finite');
  return d;
}

/// Validates a saved view; out-of-range values are clamped, malformed ones
/// throw [FormatException] (400).
SavedStreamView parseStreamView(Map<String, dynamic> body) {
  final start = _num(body, 'start', required: true)!;
  final days = _num(body, 'days', required: true)!;
  final unitRaw = body['unit'];
  if (unitRaw != null && (unitRaw is! String || !viewUnits.contains(unitRaw))) {
    throw const FormatException('unknown unit');
  }
  var yMin = _num(body, 'yMin');
  var yMax = _num(body, 'yMax');
  if ((yMin == null) != (yMax == null)) {
    throw const FormatException('yMin and yMax go together');
  }
  if (yMin != null && yMax != null) {
    yMin = _clamp(yMin, -maxViewBalance, maxViewBalance);
    yMax = _clamp(yMax, -maxViewBalance, maxViewBalance);
    if (!(yMin < yMax)) throw const FormatException('yMin must be below yMax');
  }
  return SavedStreamView(
    startDay: _clamp(start, minViewStartDay, maxViewStartDay),
    days: _clamp(days, minViewDays, maxViewDays),
    unit: unitRaw as String?,
    yMin: yMin,
    yMax: yMax,
  );
}

/// `GET|PUT /<id>/view`: the caller's own saved view of the stream (any
/// member, any role). Per user: other members never see or change it, and
/// saves are not audited or broadcast (a preference, not stream data).
void attachStreamViewRoutes(Router router, Session conn) {
  router.get('/<id>/view', (Request request, String id) async {
    final auth = authOf(request);
    if (auth == null) return jsonError(401, 'unauthenticated');
    final rows = await conn.execute(
      Sql.named(
        'SELECT start_day, visible_days, unit, y_min, y_max, updated_at '
        'FROM stream_views WHERE user_id = @u::uuid AND stream_id = @a::uuid',
      ),
      parameters: {'u': auth.user.id, 'a': id},
    );
    if (rows.isEmpty) return jsonOk({'view': null});
    final r = rows.first;
    double? d(Object? v) => (v as num?)?.toDouble();
    return jsonOk({
      'view': SavedStreamView(
        startDay: d(r[0])!,
        days: d(r[1])!,
        unit: r[2] as String?,
        yMin: d(r[3]),
        yMax: d(r[4]),
        updatedAt: r[5] as DateTime?,
      ).toJson(),
    });
  });

  router.put('/<id>/view', (Request request, String id) async {
    final auth = authOf(request);
    if (auth == null) return jsonError(401, 'unauthenticated');
    final SavedStreamView view;
    try {
      view = parseStreamView(await readJsonObject(request));
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
    await conn.execute(
      Sql.named('''
        INSERT INTO stream_views
          (user_id, stream_id, start_day, visible_days, unit, y_min, y_max)
        VALUES (@u::uuid, @a::uuid, @s, @d, @n, @lo, @hi)
        ON CONFLICT (user_id, stream_id) DO UPDATE SET
          start_day = EXCLUDED.start_day,
          visible_days = EXCLUDED.visible_days,
          unit = EXCLUDED.unit,
          y_min = EXCLUDED.y_min,
          y_max = EXCLUDED.y_max,
          updated_at = now()
      '''),
      parameters: {
        'u': auth.user.id,
        'a': id,
        's': view.startDay,
        'd': view.days,
        'n': view.unit,
        'lo': view.yMin,
        'hi': view.yMax,
      },
    );
    return jsonOk({'view': view.toJson()});
  });
}
