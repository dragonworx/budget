import 'dart:math' as math;

import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Largest "every N" the N families offer.
const int maxRuleInterval = 99;

/// The picker's label for [rule].
String ruleLabel(FreqRule rule) => switch (rule) {
  FreqRule.once => 'Once',
  FreqRule.daily => 'Daily',
  FreqRule.weekly => 'Weekly',
  FreqRule.everyNWeeks => 'Every N weeks',
  FreqRule.monthly => 'Monthly',
  FreqRule.everyNMonths => 'Every N months',
};

/// One frequency picker: Once · Daily · Weekly · Every N weeks · Monthly ·
/// Every N months, as inline choice chips (no menu or dialog). The N
/// families (and a legacy daily N > 1) show an inline [− N +] stepper.
///
/// Keys: `<prefix>-freq`, `-freq-<apiName>`, `-interval`, `-interval-minus`,
/// `-interval-plus`.
class FrequencyPicker extends StatelessWidget {
  const FrequencyPicker({
    super.key,
    required this.rule,
    required this.interval,
    required this.onRuleChanged,
    required this.onIntervalChanged,
    this.showDailyInterval = false,
    this.keyPrefix = 'editor',
    this.enabled = true,
  });

  final FreqRule rule;

  /// The N text (digits) for the N families.
  final TextEditingController interval;
  final ValueChanged<FreqRule> onRuleChanged;
  final VoidCallback onIntervalChanged;

  /// A saved "every N days" (N > 1) keeps an editable N under Daily.
  final bool showDailyInterval;
  final String keyPrefix;
  final bool enabled;

  bool get _stepper =>
      rule == FreqRule.everyNWeeks ||
      rule == FreqRule.everyNMonths ||
      (rule == FreqRule.daily && showDailyInterval);

  int get _min => rule == FreqRule.daily ? 1 : 2;

  int get _n => int.tryParse(interval.text.trim()) ?? _min;

  void _set(int n) {
    interval.text = '${n.clamp(_min, maxRuleInterval)}';
    onIntervalChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = keyPrefix;
    final unit = switch (rule) {
      FreqRule.daily => _n == 1 ? 'day' : 'days',
      FreqRule.everyNWeeks => 'weeks',
      _ => 'months',
    };
    Widget step(IconData icon, String tip, VoidCallback? onPressed, String k) =>
        IconButton(
          key: ValueKey('$p-interval-$k'),
          tooltip: tip,
          onPressed: enabled ? onPressed : null,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
          icon: Icon(icon, size: 20),
        );
    return Column(
      key: ValueKey('$p-freq'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final r in FreqRule.values)
              ChoiceChip(
                key: ValueKey('$p-freq-${r.apiName}'),
                label: Text(ruleLabel(r)),
                selected: r == rule,
                showCheckmark: false,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: !enabled
                    ? null
                    : (_) {
                        if (r != rule) onRuleChanged(r);
                      },
              ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !_stepper
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Text('Every', style: theme.textTheme.bodyMedium),
                      const SizedBox(width: 4),
                      step(
                        Icons.remove_rounded,
                        'Fewer',
                        _n <= _min ? null : () => _set(_n - 1),
                        'minus',
                      ),
                      SizedBox(
                        width: 48,
                        child: TextFormField(
                          key: ValueKey('$p-interval'),
                          controller: interval,
                          enabled: enabled,
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(2),
                          ],
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 12),
                          ),
                          onChanged: (_) => onIntervalChanged(),
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                          validator: (value) {
                            final v = int.tryParse((value ?? '').trim());
                            return v == null || v < _min || v > maxRuleInterval
                                ? '$_min–$maxRuleInterval'
                                : null;
                          },
                        ),
                      ),
                      step(
                        Icons.add_rounded,
                        'More',
                        _n >= maxRuleInterval ? null : () => _set(_n + 1),
                        'plus',
                      ),
                      const SizedBox(width: 6),
                      Text(unit, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// The rule's day chips: a Mon–Sun row ([monthDays] false) or a 1–31 grid
/// (seven a row). Tap a chip to toggle it; press and drag to paint: the
/// first chip's state after its toggle applies to every chip the pointer
/// passes (sampled between pointer events, so a fast drag skips none,
/// across grid rows too). The press claims the gesture, so the editor
/// does not scroll while painting. Works with mouse, touch and pen.
///
/// Keys: `<prefix>-days`, `-day-<n>` (1–7 Mon–Sun, or 1–31).
class DayChips extends StatefulWidget {
  const DayChips({
    super.key,
    required this.monthDays,
    required this.selected,
    required this.onChanged,
    this.keyPrefix = 'editor',
    this.enabled = true,
  });

  final bool monthDays;
  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;
  final String keyPrefix;
  final bool enabled;

  /// Touch target: 44px on phones (narrow or touch-first), 36px otherwise.
  static double targetFor(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final platform = Theme.of(context).platform;
    final touch =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    return width < 600 || touch ? 44 : 36;
  }

  @override
  State<DayChips> createState() => _DayChipsState();
}

class _DayChipsState extends State<DayChips> {
  final Map<int, GlobalKey> _keys = {};

  /// The paint in progress: the value it sets, and the last position.
  bool? _paint;
  Offset? _at;
  Set<int> _working = {};

  List<int> get _all => [
    for (var i = 1; i <= (widget.monthDays ? 31 : 7); i++) i,
  ];

  GlobalKey _key(int d) => _keys.putIfAbsent(d, () => GlobalKey());

  int? _chipAt(Offset global) {
    for (final d in _all) {
      final box = _keys[d]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final local = box.globalToLocal(global);
      if ((Offset.zero & box.size).contains(local)) return d;
    }
    return null;
  }

  void _apply(int d) {
    final v = _paint;
    if (v == null) {
      // The first chip touched: toggle it; its new state paints the rest.
      _paint = !_working.contains(d);
    }
    final next = _paint!;
    if (_working.contains(d) == next) return;
    setState(() {
      _working = {..._working};
      next ? _working.add(d) : _working.remove(d);
    });
    widget.onChanged({..._working});
  }

  void _down(PointerDownEvent e) {
    if (!widget.enabled) return;
    _working = {...widget.selected};
    _paint = null;
    _at = e.position;
    final d = _chipAt(e.position);
    if (d != null) _apply(d);
  }

  void _move(PointerMoveEvent e) {
    final from = _at;
    _at = e.position;
    if (from == null) return;
    // Sample every 4px between pointer events: no chip is skipped.
    final delta = e.position - from;
    final n = math.max(1, (delta.distance / 4).ceil());
    for (var i = 1; i <= n; i++) {
      final d = _chipAt(from + delta * (i / n));
      if (d != null) _apply(d);
    }
  }

  void _end() {
    _paint = null;
    _at = null;
  }

  /// Keyboard / screen-reader toggle (a whole tap).
  void _toggle(int d) {
    if (!widget.enabled) return;
    final next = {...widget.selected};
    next.contains(d) ? next.remove(d) : next.add(d);
    _working = next;
    widget.onChanged(next);
  }

  Widget _chip(BuildContext context, int d, double size) {
    final on = widget.selected.contains(d);
    final scheme = Theme.of(context).colorScheme;
    final label = widget.monthDays ? '$d' : weekdayShort[d - 1];
    return Semantics(
      key: ValueKey('${widget.keyPrefix}-day-$d'),
      button: true,
      toggled: on,
      label: widget.monthDays ? ordinalDay(d) : label,
      onTap: widget.enabled ? () => _toggle(d) : null,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: AnimatedContainer(
          key: _key(d),
          duration: const Duration(milliseconds: 120),
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? AppTheme.accent : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(size / 2),
            border: Border.all(
              color: on ? AppTheme.accent : AppTheme.textFaint,
              width: 1,
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: widget.monthDays ? 13 : 13,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              color: on ? Colors.black : null,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = DayChips.targetFor(context);
    final all = _all;
    final rows = <List<int>>[
      for (var i = 0; i < all.length; i += 7)
        all.sublist(i, math.min(i + 7, all.length)),
    ];
    return RawGestureDetector(
      key: ValueKey('${widget.keyPrefix}-days'),
      behavior: HitTestBehavior.opaque,
      gestures: {
        _ChipPaintRecognizer:
            GestureRecognizerFactoryWithHandlers<_ChipPaintRecognizer>(
              _ChipPaintRecognizer.new,
              (r) => r
                ..onDown = _down
                ..onMove = _move
                ..onEnd = _end,
            ),
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows)
            Row(
              children: [
                for (var c = 0; c < 7; c++)
                  Expanded(
                    child: c < row.length
                        ? _chip(context, row[c], size)
                        : SizedBox(height: size + 4),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Claims every press on the chips at once (so no scroll or tap
/// recogniser competes) and reports the pointer until it lifts.
class _ChipPaintRecognizer extends OneSequenceGestureRecognizer {
  ValueChanged<PointerDownEvent>? onDown;
  ValueChanged<PointerMoveEvent>? onMove;
  VoidCallback? onEnd;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
    onDown?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      onMove?.call(event);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      onEnd?.call();
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'day chip paint';
}
