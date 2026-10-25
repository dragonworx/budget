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
/// centre with the slogan under it, the coin drops and slips down INTO the
/// slot (masked by the slot: only the part above it shows, so it vanishes
/// inside the bird), then the slogan fades as the logo glides (scale +
/// translate, easeInOutCubic) into its idle spot: the [BrandAnchor] on
/// screen (header lockup, timeline header icon or sign-in lockup). The coin
/// fades back onto the shrinking icon so it lands as the full logo.
///
/// Plays once per page load (a static flag: in-app navigation never
/// replays it), starting as the HTML boot loader fades. Reduced motion
/// (OS setting or [MediaQuery.disableAnimations]) shows the static logo and
/// slogan briefly, then cuts to the app. The backdrop only blocks input
/// until the glide starts (~1.15s); a tap skips ahead.
class LandingIntro {
  LandingIntro._();

  static final ValueNotifier<IntroPhase> phase = ValueNotifier(IntroPhase.off);
  static Timer? _safety;

  // Timeline, in ms from play().
  static const hold = 300; // icon (+ slogan) alone while the HTML loader fades
  static const sinkEnd = 1100; // coin fully inside the slot
  static const glideStart = 1150;
  static const total = 1950; // glide: 800ms
  static const sloganIn = (150, 550);
  static const sloganOut = (glideStart, glideStart + 300);

  /// Reduced motion: the static logo and slogan show this long, no motion.
  static const reducedHold = 600;

  /// The slogan under the logo while the intro plays.
  static const slogan = 'Tweet your budget right';

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

  bool _reduced = false;
  Timer? _reducedTimer;

  @override
  void dispose() {
    LandingIntro.phase.removeListener(_onPhase);
    _reducedTimer?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _onPhase() {
    if (!mounted) return;
    final p = LandingIntro.phase.value;
    if (p == IntroPhase.off) {
      _reducedTimer?.cancel();
      _reduced = false;
    }
    if (p == IntroPhase.playing &&
        !_reduced &&
        !_c.isAnimating &&
        _c.value == 0) {
      final reduce =
          (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
          page.prefersReducedMotion;
      if (reduce) {
        // Static logo + slogan, no motion, then straight to the app.
        _reduced = true;
        _reducedTimer = Timer(
          const Duration(milliseconds: LandingIntro.reducedHold),
          LandingIntro.finish,
        );
        setState(() {});
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
              : _reduced
              ? _static(context)
              : AnimatedBuilder(animation: _c, builder: _frame),
        ),
      ],
    );
  }

  /// Icon size and centred rect of the big logo.
  static Rect _bigRect(Size size) {
    final s = (size.shortestSide * 0.42).clamp(120.0, 240.0);
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: s,
      height: s,
    );
  }

  /// The slogan, centred under the big logo.
  Widget _slogan(BuildContext context, Rect big, double opacity) {
    final base = Theme.of(context).textTheme.titleMedium ?? const TextStyle();
    final fontSize = (big.width * 0.085).clamp(14.0, 20.0);
    return Positioned(
      left: 0,
      right: 0,
      top: big.bottom + big.width * 0.1,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Text.rich(
            key: const ValueKey('landing-slogan'),
            const TextSpan(
              children: [
                TextSpan(text: 'Tweet your '),
                TextSpan(
                  text: 'budget',
                  style: TextStyle(color: Brand.yellow),
                ),
                TextSpan(text: ' right'),
              ],
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            style: base.copyWith(
              color: AppTheme.text,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  /// Reduced motion: the full logo and slogan, still; a tap skips.
  Widget _static(BuildContext context) {
    final big = _bigRect(MediaQuery.sizeOf(context));
    return GestureDetector(
      key: const ValueKey('landing-intro'),
      behavior: HitTestBehavior.opaque,
      onTap: LandingIntro.finish,
      child: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: AppTheme.bg)),
          Positioned.fromRect(
            rect: big,
            child: BudgieIcon(size: big.width),
          ),
          _slogan(context, big, 1),
        ],
      ),
    );
  }

  Widget _frame(BuildContext context, Widget? _) {
    final size = MediaQuery.sizeOf(context);
    final ms = _c.value * LandingIntro.total;
    final from = _bigRect(size);
    final s = from.width;

    double seg(num a, num b) => ((ms - a) / (b - a)).clamp(0.0, 1.0);

    // Glide: towards the live anchor rect (re-read each frame, so a header
    // that moves still lands exactly). No anchor: shrink and fade in place.
    final g = Curves.easeInOutCubic.transform(
      seg(LandingIntro.glideStart, LandingIntro.total),
    );
    final anchor = BrandAnchor.currentRect();
    final target =
        anchor ??
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
    final noAnchorFade = anchor == null ? 1 - g : 1.0;

    // Coin: falls from above the icon, through its resting spot and on down
    // into the slot (slowing as it slips in), until its top passes the
    // slot line and it is gone. Clipped at the slot line all the way.
    final d = seg(LandingIntro.hold, LandingIntro.sinkEnd);
    const above = -0.55;
    const inside = Brand.slotY + 0.01;
    final coinTop =
        above + (inside - above) * const Cubic(0.5, 0, 0.3, 1).transform(d);
    final coinOpacity = seg(LandingIntro.hold, LandingIntro.hold + 120);
    // The full logo (coin on top) is what it lands as: the coin fades back
    // in, at rest, over the second half of the glide.
    final coinBack = anchor == null ? 0.0 : ((g - 0.5) / 0.5).clamp(0.0, 1.0);

    // Backdrop and slogan fade during the first part of the glide.
    final backdrop =
        1 - Curves.easeOut.transform(seg(LandingIntro.glideStart, 1700));
    final slogan =
        Curves.easeOut.transform(
          seg(LandingIntro.sloganIn.$1, LandingIntro.sloganIn.$2),
        ) *
        (1 - seg(LandingIntro.sloganOut.$1, LandingIntro.sloganOut.$2));

    final blocking = ms < LandingIntro.glideStart;
    final logo = SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          BudgieIcon(size: s, noCoin: true),
          // The slot masks the coin: only what is above the slot's centre
          // line shows, so it sinks out of sight into the bird.
          Positioned(
            left: 0,
            top: -s,
            width: s,
            height: s + s * Brand.slotY,
            child: ClipRect(
              key: const ValueKey('landing-slot-mask'),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (d < 1)
                    Positioned(
                      left: s * Brand.coinLeft,
                      top: s + s * coinTop,
                      width: s * Brand.coinSize,
                      height: s * Brand.coinSize,
                      child: Opacity(
                        opacity: coinOpacity,
                        child: const BudgieCoin(key: ValueKey('landing-coin')),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (coinBack > 0)
            Positioned(
              left: s * Brand.coinLeft,
              top: s * Brand.coinTop,
              width: s * Brand.coinSize,
              height: s * Brand.coinSize,
              child: Opacity(opacity: coinBack, child: const BudgieCoin()),
            ),
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
            if (slogan > 0) _slogan(context, from, slogan),
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
