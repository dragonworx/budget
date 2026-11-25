import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/ui.dart';

/// Gestures and keyboard shortcuts for the timeline. Opened from the
/// avatar menu's Help item (and any leftover keyboard entry points).
Future<void> showShortcutsHelp(BuildContext context) {
  Widget row(List<String> keys, String what) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        SizedBox(
          width: 170,
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [for (final k in keys) KeyCap(k)],
          ),
        ),
        Expanded(child: Text(what)),
      ],
    ),
  );
  Widget head(String t) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      t.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1,
        fontWeight: FontWeight.w700,
        color: AppTheme.textFaint,
      ),
    ),
  );
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Timeline shortcuts'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              head('Navigate'),
              row(['Drag'], 'Pan time and balance (on the chart)'),
              row(['Pinch'], 'Zoom time (touch, or trackpad at the cursor)'),
              row(['Double-tap'], 'Zoom in there and centre its balance'),
              row(['←', '→'], 'Pan time'),
              row(['↑', '↓'], 'Pan balance'),
              row(['Scroll'], 'Pan balance (sideways or Shift: time)'),
              row(['⌘ / ⌥ / Ctrl', 'Scroll'], 'Zoom at the cursor'),
              row(['+', '−'], 'Smaller / larger view unit'),
              row(['View', 'Go to date…'], 'Show a day from the left edge'),
              row(['[', ']'], 'Back / forward one unit'),
              row(['?'], 'Show this sheet'),
              head('Fit'),
              row(['F'], 'Fit balance to what is in view'),
              row(['A'], 'Fit all data'),
              row(['H'], 'Fit all data horizontally'),
              head('Events'),
              row(
                ['Tap', 'Click'],
                'Tap or click an event line for actions (new event, '
                'trim or edit from that day)',
              ),
              row(['Net chip'], 'That day’s events'),
              row(['Hover day', '+'], 'Add a one-off on that day'),
              row(['Drag dates'], 'Drag along the date axis, release to add'),
              row(['Tap dates'], 'Add a one-off on that day'),
              row(
                ['Tap dates', '✂'],
                'End every event on that day (events starting later are '
                'deleted; one Undo)',
              ),
              row(['Ctrl', 'Enter'], 'Save in the editor'),
              row(['Esc'], 'Cancel a date drag / close the editor'),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}
