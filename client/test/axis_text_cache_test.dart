import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2031, 3, 1);

void main() {
  testWidgets('axis labels are laid out once and reused while panning; '
      'the cache is bounded and drops everything on a font change', (
    tester,
  ) async {
    const size = Size(390, 600);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final points = [
      for (var i = -60; i < 400; i++)
        BalancePoint(
          date: DateTime(2031, 3, 1 + i),
          closingBalance: Decimal.fromInt(1000 + i),
        ),
    ];
    var viewStart = _start;
    final labels = <String>[];
    debugAxisLabel = (row, text, rect) => labels.add('$row:$text');
    addTearDown(() => debugAxisLabel = null);
    Widget build() => MaterialApp(
      home: Scaffold(
        body: SizedBox.fromSize(
          size: size,
          child: BalanceChart(
            series: BalanceSeries(points: points),
            seedDate: _start.subtract(const Duration(days: 60)),
            viewStart: viewStart,
            visibleDays: 14,
            onViewportChanged: (_, _) {},
            onCreateOnDay: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(build());
    await tester.pump(const Duration(seconds: 1));
    final first = debugAxisTextCacheLength;
    expect(first, greaterThan(5));
    final firstLabels = [...labels];
    // Pan back and forth over the same days: no new layouts once warm.
    for (var round = 0; round < 2; round++) {
      for (var i = 0; i <= 20; i++) {
        viewStart = _start.add(Duration(hours: i * 6));
        await tester.pumpWidget(build());
      }
    }
    final warm = debugAxisTextCacheLength;
    for (var i = 0; i <= 20; i++) {
      viewStart = _start.add(Duration(hours: i * 6));
      await tester.pumpWidget(build());
    }
    expect(debugAxisTextCacheLength, warm, reason: 'same labels reused');
    // Same labels painted as on the first frame when back at the start.
    labels.clear();
    viewStart = _start;
    await tester.pumpWidget(build());
    expect(labels.toSet(), firstLabels.toSet());
    // Long pans stay bounded.
    for (var i = 0; i < 300; i++) {
      viewStart = _start.add(Duration(days: i));
      await tester.pumpWidget(build());
    }
    expect(debugAxisTextCacheLength, lessThanOrEqualTo(1500));
    // A font change (e.g. a web font finished loading) clears the cache.
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'flutter/system',
          const JSONMessageCodec().encodeMessage({'type': 'fontsChange'}),
          (_) {},
        );
    expect(debugAxisTextCacheLength, 0);
    viewStart = _start;
    await tester.pumpWidget(build());
    expect(debugAxisTextCacheLength, greaterThan(0));
  });
}
