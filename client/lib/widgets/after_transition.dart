import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Runs a callback after the current route (or a wrapping
/// [AnimatedSwitcher]) has finished opening.
///
/// Used so a newly opened form can take focus once the panel or dialog
/// has settled, without a fixed delay. Cancel in [State.dispose] if the
/// widget may go away mid-transition.
class TransitionWait {
  VoidCallback? _cancel;

  void cancel() {
    _cancel?.call();
    _cancel = null;
  }

  /// Runs [then] after the opening animation completes. Already-finished
  /// (or missing) animations run [then] shortly after the next frames.
  /// [then] is skipped if [context] is unmounted, or if [cancel] was
  /// called first.
  ///
  /// Polls ancestor animations each frame so a wrapping
  /// [AnimatedSwitcher] that is only inserted with this widget is still
  /// seen, and so a route whose animation is still [AnimationStatus.dismissed]
  /// on the first frame (it has not started yet) is not treated as
  /// finished. A few idle frames after the last running animation let a
  /// departing button restore its own focus first.
  ///
  /// Each follow-up frame is explicitly scheduled: once the open
  /// animation's ticker has stopped, a post-frame callback alone would
  /// never run (no frame is pending).
  void schedule(BuildContext context, VoidCallback then) {
    cancel();
    var ran = false;
    var cancelled = false;
    var idleFrames = 0;
    void run() {
      if (ran || cancelled) return;
      ran = true;
      _cancel = null;
      if (context.mounted) then();
    }

    void later(FrameCallback cb) {
      WidgetsBinding.instance.addPostFrameCallback(cb);
      SchedulerBinding.instance.scheduleFrame();
    }

    void tick(Duration _) {
      if (ran || cancelled) return;
      if (!context.mounted) {
        ran = true;
        return;
      }
      final anim = openingAnimation(context);
      if (anim != null &&
          (anim.status == AnimationStatus.forward ||
              anim.status == AnimationStatus.reverse)) {
        idleFrames = 0;
        later(tick);
        return;
      }
      // The fade may not be in the tree yet, or the route animation may
      // still be dismissed before it starts. Wait a few frames, then
      // treat the open as settled.
      idleFrames++;
      if (idleFrames < 4) {
        later(tick);
        return;
      }
      later((_) => run());
    }

    later(tick);
    _cancel = () => cancelled = true;
  }
}

/// The animation that is still opening [context], if any: the modal
/// route first, otherwise a wrapping [FadeTransition] (the Events
/// list's in-panel [AnimatedSwitcher]).
Animation<double>? openingAnimation(BuildContext context) {
  bool running(Animation<double>? a) =>
      a != null &&
      (a.status == AnimationStatus.forward ||
          a.status == AnimationStatus.reverse);

  final routeAnim = ModalRoute.of(context)?.animation;
  if (running(routeAnim)) return routeAnim;

  Animation<double>? found;
  context.visitAncestorElements((el) {
    final w = el.widget;
    if (w is FadeTransition && running(w.opacity)) {
      found = w.opacity;
      return false;
    }
    return true;
  });
  return found;
}
