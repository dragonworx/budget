import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../timeline/occurrence_info.dart';
import 'event_editor.dart';

/// Snackbar text describing [o] exactly (null when nothing changed).
String? describeOutcome(EditorOutcome? o) {
  if (o == null) return null;
  final name = o.event.name.isEmpty ? 'Untitled' : '“${o.event.name}”';
  String skips() {
    final parts = <String>[];
    if (o.skipped.length == 1 && o.restored.isEmpty) {
      return 'Skipped ${formatOccurrenceDate(o.skipped.first)}';
    }
    if (o.restored.length == 1 && o.skipped.isEmpty) {
      return 'Restored ${formatOccurrenceDate(o.restored.first)}';
    }
    if (o.skipped.isNotEmpty) {
      parts.add(
        'skipped ${o.skipped.length} occurrence${o.skipped.length == 1 ? '' : 's'}',
      );
    }
    if (o.restored.isNotEmpty) {
      parts.add(
        'restored ${o.restored.length} occurrence${o.restored.length == 1 ? '' : 's'}',
      );
    }
    final t = parts.join(' and ');
    return t.isEmpty ? '' : t[0].toUpperCase() + t.substring(1);
  }

  final hasSkips = o.skipped.isNotEmpty || o.restored.isNotEmpty;
  String on() => o.date == null ? '' : formatOccurrenceDate(o.date!);
  return switch (o.action) {
    EditorAction.created => 'Created $name',
    EditorAction.deleted => 'Deleted $name',
    EditorAction.saved =>
      hasSkips ? 'Saved $name · ${skips().toLowerCase()}' : 'Saved $name',
    EditorAction.skipsChanged => '${skips()} · $name',
    EditorAction.overridden => 'Changed $name on ${on()} only',
    EditorAction.overrideCleared => 'Reset $name on ${on()} to the series',
    EditorAction.overridesCleared =>
      'Cleared ${o.previous?.overrides.length ?? 0} once-off '
          'override${o.previous?.overrides.length == 1 ? '' : 's'} · $name',
    EditorAction.split => 'Changed $name from ${on()} on',
    EditorAction.trimmed => 'Trimmed $name · ends ${on()}',
  };
}

/// Shows the outcome snackbar with an Undo that reverses it.
void reportEditorOutcome(
  BuildContext context,
  WidgetRef ref, {
  required String streamId,
  required EditorOutcome? outcome,
  required VoidCallback onChanged,
  List<String>? orderBefore,
}) {
  final text = describeOutcome(outcome);
  if (text == null || outcome == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final notifier = ref.read(eventsProvider(streamId).notifier);
  final o = outcome;

  Future<void> undo() async {
    final id = o.event.id;
    switch (o.action) {
      case EditorAction.created:
        await notifier.delete(id);
      case EditorAction.deleted:
        final again = await notifier.create(
          o.event.copyWith(id: const Uuid().v4()),
        );
        for (final d in o.skippedBefore) {
          await notifier.setSkip(again.id, d, skipped: true);
        }
        // Put it back where it was in the list.
        if (orderBefore != null && orderBefore.contains(id)) {
          await notifier.reorder([
            for (final x in orderBefore) x == id ? again.id : x,
          ]);
        }
      case EditorAction.saved:
        if (o.previous != null) {
          await notifier.updateEvent(o.previous!, force: true);
        }
        continue skips;
      case EditorAction.overridden:
      case EditorAction.overrideCleared:
        // Put the date back as it was (overridden or natural).
        final before = o.previous?.overrideOn(o.date!);
        if (before == null) {
          await notifier.clearOverrides(id, date: o.date);
        } else {
          await notifier.setOverride(
            id,
            o.date!,
            direction: before.direction,
            amount: before.amount,
          );
        }
      case EditorAction.overridesCleared:
        for (final e
            in o.previous?.overrides.entries ??
                const <MapEntry<DateTime, OccurrenceOverride>>[]) {
          await notifier.setOverride(
            id,
            e.key,
            direction: e.value.direction,
            amount: e.value.amount,
          );
        }
      case EditorAction.split:
        // Drop the new series, restore the original whole, then put back
        // the skips / overrides that moved with the split.
        final previous = o.previous!;
        if (o.original != null && o.event.id != previous.id) {
          await notifier.delete(o.event.id);
        }
        await notifier.updateEvent(previous, force: true);
        final from = o.date!;
        for (final d in o.skippedBefore) {
          if (!d.isBefore(from)) {
            await notifier.setSkip(previous.id, d, skipped: true);
          }
        }
        for (final e in previous.overrides.entries) {
          if (!e.key.isBefore(from)) {
            await notifier.setOverride(
              previous.id,
              e.key,
              direction: e.value.direction,
              amount: e.value.amount,
            );
          }
        }
      case EditorAction.trimmed:
        // Back to the old end, then the once-offs the trim dropped.
        final previous = o.previous!;
        await notifier.updateEvent(previous, force: true);
        for (final e in previous.overrides.entries) {
          if (e.key.isAfter(o.date!)) {
            await notifier.setOverride(
              previous.id,
              e.key,
              direction: e.value.direction,
              amount: e.value.amount,
            );
          }
        }
      skips:
      case EditorAction.skipsChanged:
        for (final d in o.skipped) {
          await notifier.setSkip(id, d, skipped: false);
        }
        for (final d in o.restored) {
          await notifier.setSkip(id, d, skipped: true);
        }
    }
    onChanged();
  }

  showUndoBar(messenger, text: text, onUndo: undo);
}

/// The one floating Undo bar: every editor outcome and every trim path
/// (a lane's or dot's Trim From Here, a day popup row's ⋮ Trim, the day
/// pick's ✂ batch, the delete a trim turns into) shows it through here, so
/// they look, last and replace alike. A new bar replaces the current one
/// at once (and drops anything queued behind it): only the latest change
/// offers Undo. It floats above the timeline (the theme's floating
/// SnackBar, clear of the bottom safe area), stays [undoTipDuration], and
/// [onUndo] (null: no Undo button) is followed by "Undone", or "Undo
/// failed: …" when it throws.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showUndoBar(
  ScaffoldMessengerState messenger, {
  required String text,
  Future<void> Function()? onUndo,
}) {
  // The theme's floating bar is 520 wide: narrower screens keep a 12px
  // margin each side (a fixed 520 on a phone runs off both edges).
  final screen = MediaQuery.maybeSizeOf(messenger.context)?.width;
  final width = screen == null ? null : math.min(520.0, screen - 24);
  void replaceWith(SnackBar bar) {
    messenger
      ..clearSnackBars()
      ..removeCurrentSnackBar();
    messenger.showSnackBar(bar);
  }

  Future<void> undo() async {
    try {
      await onUndo!();
      replaceWith(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          width: width,
          content: const Text('Undone'),
        ),
      );
    } catch (error) {
      replaceWith(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          width: width,
          content: Text('Undo failed: ${friendlyError(error)}'),
        ),
      );
    }
  }

  messenger
    ..clearSnackBars()
    ..removeCurrentSnackBar();
  final tip = messenger.showSnackBar(
    SnackBar(
      key: const ValueKey('undo-tip'),
      behavior: SnackBarBehavior.floating,
      width: width,
      content: Text(text),
      duration: undoTipDuration,
      // A SnackBar with an action persists by default (and under
      // accessible navigation): the undo tip always times out.
      persist: false,
      action: onUndo == null
          ? null
          : SnackBarAction(label: 'Undo', onPressed: undo),
    ),
  );
  // Backstop: the messenger's own timer only runs while its route is on
  // top (and starts after the entrance animation), so also hide it 5s after
  // it was shown, whatever is open.
  var closed = false;
  final backstop = Timer(
    undoTipDuration + const Duration(milliseconds: 300),
    () {
      if (!closed) {
        messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.timeout);
      }
    },
  );
  tip.closed.whenComplete(() {
    closed = true;
    backstop.cancel();
  });
  return tip;
}

/// How long the floating Undo tip stays up (Undo works until it hides).
const undoTipDuration = Duration(seconds: 5);
