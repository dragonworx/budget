import 'dart:async';

import 'package:flutter/material.dart';

import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart'
    as page;
import '../theme/app_theme.dart';
import 'brand.dart';

enum IntroPhase {
  /// Not playing this load (tests, or already played / skipped).
  off,

  /// Will play when the boot loader finishes; anchors stay hidden.
  armed,
  playing,
}

/// The once-per-load landing animation: the Budgie icon shows large in the
/// centre, the coin drops into the slot, then the logo glides (scale +
/// translate, easeInOutCubic) into its idle spot: the [BrandAnchor] on
/// screen (header lockup, timeline header icon or sign-in lockup).
///
/// Plays once per page load (a static flag: in-app navigation never
/// replays it), starting as the HTML boot loader fades. Reduced motion
/// (OS setting or [MediaQuery.disableAnimations]) skips straight to the end
/// state. The backdrop only blocks input until the glide starts (~0.9s); a
/// tap skips ahead.
class LandingIntro {
  LandingIntro._();

  static final ValueNotifier<IntroPhase> phase = ValueNotifier(IntroPhase.off);
  static Timer? _safety;

  // Timeline, in ms from play().
  static const hold = 350; // icon alone while the HTML loader fades
  static const dropEnd = 850; // coin lands in the slot
  static const glideStart = 950;
  static const total = 1800; // glide: 850ms

  /// Called once at startup (web). Anchors hide until the intro ends.
  static void arm() {
    if (phase.value != IntroPhase.off || _played) return;
    phase.value = IntroPhase.armed;
    // Never leave the logo hidden if the loader somehow never finishes.
    _safety = Timer(const Duration(seconds: 25), finish);
  }

  static bool _played = false;

  /// Start (boot loader finished). No-op unless armed.
  static void play() {
    if (phase.value != IntroPhase.armed) return;
    _played = true;
    phase.value = IntroPhase.playing;
  }

  /// Jump to the end state.
  static void finish() {
    _safety?.cancel();
    _safety = null;
    _played = true;
    phase.value = IntroPhase.off;
  }

  /// Tests: back to the initial state.
  @visibleForTesting
  static void reset() {
    _safety?.cancel();
    _safety = null;
    _played = false;
    phase.value = IntroPhase.off;
  }

  static bool get hidesAnchors => phase.value != IntroPhase.off;
}

/// The logo's idle spot: hidden while the intro runs, the intro glides into
/// its rect. The most recently mounted, visible (ticker-enabled) anchor wins.
class BrandAnchor extends StatefulWidget {
  const BrandAnchor({super.key, required this.child});

  final Widget child;

  static final List<_BrandAnchorState> _mounted = [];

  /// Global rect of the current target anchor, if any is laid out.
  static Rect? currentRect() {
    for (final s in _mounted.reversed) {
      final r = s._rect();
      if (r != null) return r;
    }
    return null;
  }

  @override
  State<BrandAnchor> createState() => _BrandAnchorState();
}

class _BrandAnchorState extends State<BrandAnchor> {
  @override
  void initState() {
    super.initState();
    BrandAnchor._mounted.add(this);
  }

  @override
  void dispose() {
    BrandAnchor._mounted.remove(this);
    super.dispose();
  }

  Rect? _rect() {
    if (!mounted || !TickerMode.valuesOf(context).enabled) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: LandingIntro.phase,
    builder: (context, _, child) =>
        Opacity(opacity: LandingIntro.hidesAnchors ? 0 : 1, child: child),
    child: widget.child,
  );
}

/// Hosts the intro above the whole app (MaterialApp.builder).
class LandingIntroOverlay extends StatefulWidget {
  const LandingIntroOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<LandingIntroOverlay> createState() => _LandingIntroOverlayState();
}

class _LandingIntroOverlayState extends State<LandingIntroOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: LandingIntro.total),
  );

  @override
  void initState() {
    super.initState();
    LandingIntro.phase.addListener(_onPhase);
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) LandingIntro.finish();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPhase());
  }

  @override
  void dispose() {
    LandingIntro.phase.removeListener(_onPhase);
    _c.dispose();
    super.dispose();
  }

  void _onPhase() {
    if (!mounted) return;
    final p = LandingIntro.phase.value;
    if (p == IntroPhase.playing && !_c.isAnimating && _c.value == 0) {
      final reduce =
          (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
          page.prefersReducedMotion;
      if (reduce) {
        LandingIntro.finish();
        return;
      }
      _c.forward();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = LandingIntro.phase.value;
    if (p == IntroPhase.off) {
      if (_c.isAnimating) _c.stop();
      return widget.child;
    }
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        Positioned.fill(
          child: p == IntroPhase.armed
              // Under the HTML loader: keep the page covered so the first
              // revealed frame is the intro, not the bare header.
              ? const ColoredBox(color: AppTheme.bg)
              : AnimatedBuilder(animation: _c, builder: _frame),
        ),
      ],
    );
  }

  Widget _frame(BuildContext context, Widget? _) {
    final size = MediaQuery.sizeOf(context);
    final ms = _c.value * LandingIntro.total;
    final s = (size.shortestSide * 0.42).clamp(120.0, 240.0);
    final from = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: s,
      height: s,
    );

    double seg(num a, num b) => ((ms - a) / (b - a)).clamp(0.0, 1.0);

    // Glide: towards the live anchor rect (re-read each frame, so a header
    // that moves still lands exactly). No anchor: shrink and fade in place.
    final g = Curves.easeInOutCubic.transform(
      seg(LandingIntro.glideStart, LandingIntro.total),
    );
    final target =
        BrandAnchor.currentRect() ??
        Rect.fromCenter(center: from.center, width: s * 0.6, height: s * 0.6);
    // Icon pops in under the fading HTML loader.
    final pop = 0.9 + 0.1 * Curves.easeOutBack.transform(seg(0, 300));
    final start = Rect.fromCenter(
      center: from.center,
      width: s * pop,
      height: s * pop,
    );
    final rect = Rect.lerp(start, target, g)!;
    final scale = rect.width / s;
    final noAnchorFade = BrandAnchor.currentRect() == null ? 1 - g : 1.0;

    // Coin: falls from above (easeIn), dips into the slot, settles.
    final d = seg(LandingIntro.hold, LandingIntro.dropEnd);
    const rest = Brand.coinTop;
    const dip = rest + 0.045;
    final double coinTop;
    if (d < 0.7) {
      coinTop =
          -0.55 +
          (dip + 0.55) *
              Curves.easeInCubic.transform((d / 0.7).clamp(0.0, 1.0));
    } else {
      coinTop =
          dip +
          (rest - dip) *
              Curves.easeOut.transform(((d - 0.7) / 0.3).clamp(0.0, 1.0));
    }
    final coinOpacity = seg(LandingIntro.hold, LandingIntro.hold + 120);

    // Backdrop fades during the first part of the glide.
    final backdrop =
        1 - Curves.easeOut.transform(seg(LandingIntro.glideStart, 1550));

    final blocking = ms < LandingIntro.glideStart;
    final logo = SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          BudgieIcon(size: s, noCoin: true),
          // Everything above the slot's centre line: the coin "enters" it.
          Positioned(
            left: 0,
            top: -s,
            width: s,
            height: s + s * Brand.slotY,
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: s * Brand.coinLeft,
                    top: s + s * coinTop,
                    width: s * Brand.coinSize,
                    height: s * Brand.coinSize,
                    child: Opacity(
                      opacity: coinOpacity,
                      child: const BudgieCoin(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Below the slot the coin stays hidden; at rest its last few
          // units (y 164–167) sit inside the slot, as in the full icon.
        ],
      ),
    );

    return GestureDetector(
      key: const ValueKey('landing-intro'),
      behavior: blocking ? HitTestBehavior.opaque : HitTestBehavior.translucent,
      onTap: blocking ? LandingIntro.finish : null,
      child: IgnorePointer(
        ignoring: !blocking,
        child: Stack(
          children: [
            if (backdrop > 0)
              Positioned.fill(
                child: ColoredBox(
                  color: AppTheme.bg.withValues(alpha: backdrop),
                ),
              ),
            Positioned(
              left: 0,
              top: 0,
              child: Opacity(
                opacity: noAnchorFade.toDouble(),
                child: Transform(
                  transform: Matrix4.identity()
                    ..translateByDouble(rect.left, rect.top, 0, 1)
                    ..scaleByDouble(scale, scale, 1, 1),
                  child: logo,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
