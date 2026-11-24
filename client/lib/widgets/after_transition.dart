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
  /// (or missing) animations run [then] on the next frame. [then] is
  /// skipped if [context] is unmounted, or if [cancel] was called first.
  void schedule(BuildContext context, VoidCallback then) {
    cancel();
    var ran = false;
    void run() {
      if (ran) return;
      ran = true;
      _cancel = null;
      if (context.mounted) then();
    }

    final anim = openingAnimation(context);
    if (anim == null ||
        anim.status == AnimationStatus.completed ||
        anim.status == AnimationStatus.dismissed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => run());
      _cancel = () => ran = true;
      return;
    }

    late final AnimationStatusListener listener;
    listener = (status) {
      if (status != AnimationStatus.completed) return;
      anim.removeStatusListener(listener);
      run();
    };
    anim.addStatusListener(listener);
    _cancel = () {
      anim.removeStatusListener(listener);
      ran = true;
    };
    // Completed between the status check and the subscribe.
    if (anim.status == AnimationStatus.completed) {
      anim.removeStatusListener(listener);
      _cancel = null;
      run();
    }
  }
}

/// The animation that is still opening [context], if any: the modal
/// route first, otherwise a wrapping [FadeTransition] (the Events
/// list's in-panel [AnimatedSwitcher]).
Animation<double>? openingAnimation(BuildContext context) {
  bool running(Animation<double>? a) =>
      a != null &&
      a.status != AnimationStatus.completed &&
      a.status != AnimationStatus.dismissed;

  final routeAnim = ModalRoute.of(context)?.animation;
  if (running(routeAnim)) return routeAnim;
  final fade = context.findAncestorWidgetOfExactType<FadeTransition>();
  if (running(fade?.opacity)) return fade!.opacity;
  return null;
}
