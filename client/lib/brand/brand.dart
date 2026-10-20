import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'landing_intro.dart';

export 'landing_intro.dart' show BrandAnchor, LandingIntro;

/// Budgie brand assets (Designer's SVGs in assets/brand/).
///
/// Geometry comes from the brand README: icon viewBox 528, coin box 132
/// units at (198, 35), slot y 156–172; navbar lockup 1053×282 with the icon
/// scaled ×0.53409 and the wordmark at (327.5, 33.5), ×1.11809.
class Brand {
  Brand._();

  static const icon = 'assets/brand/budgie-icon-rounded.svg';
  static const iconNoCoin = 'assets/brand/budgie-icon-rounded-nocoin.svg';
  static const coin = 'assets/brand/budgie-coin.svg';
  static const wordmarkWhite = 'assets/brand/budgie-wordmark-white.svg';
  static const wordmarkNavy = 'assets/brand/budgie-wordmark-navy.svg';
  static const taglineWhite = 'assets/brand/budgie-tagline-white.svg';

  static const all = [
    icon,
    iconNoCoin,
    coin,
    wordmarkWhite,
    wordmarkNavy,
    taglineWhite,
  ];

  // Palette.
  static const navy = Color(0xFF0A2C5E);
  static const green = Color(0xFF55B74F);
  static const sky = Color(0xFF7EC9FE);
  static const yellow = Color(0xFFFFDA2C);
  static const gold = Color(0xFFEFAE1A);

  /// Coin box within the icon, as fractions of the icon size.
  static const coinLeft = 198 / 528;
  static const coinTop = 35 / 528;
  static const coinSize = 132 / 528;

  /// Slot centre line: the coin is clipped below it while it drops in.
  static const slotY = 164 / 528;

  /// Parse the SVGs once at startup so the first header / intro frame
  /// doesn't pop in.
  static void precache() {
    for (final a in all) {
      final loader = SvgAssetLoader(a);
      svg.cache.putIfAbsent(
        loader.cacheKey(null),
        () => loader.loadBytes(null),
      );
    }
  }
}

/// The rounded app-tile icon (bird + coin).
class BudgieIcon extends StatelessWidget {
  const BudgieIcon({super.key, required this.size, this.noCoin = false});

  final double size;
  final bool noCoin;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    noCoin ? Brand.iconNoCoin : Brand.icon,
    width: size,
    height: size,
    excludeFromSemantics: true,
  );
}

/// The coin layer alone (the intro drops it into the slot).
class BudgieCoin extends StatelessWidget {
  const BudgieCoin({super.key});

  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset(Brand.coin, excludeFromSemantics: true);
}

/// Navbar lockup: icon + "Budgie" wordmark, no tagline, laid out exactly
/// like budgie-navbar-*.svg. The icon is a [BrandAnchor] so the landing
/// intro can glide into it. [onLight] uses the navy wordmark.
class BudgieNavbarLockup extends StatelessWidget {
  const BudgieNavbarLockup({super.key, this.height = 30, this.onLight = false});

  final double height;
  final bool onLight;

  static const aspect = 1053 / 282;

  @override
  Widget build(BuildContext context) {
    final u = height / 282;
    return Semantics(
      label: 'Budgie',
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        key: const ValueKey('brand-navbar'),
        width: height * aspect,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 0,
              width: height,
              height: height,
              child: BrandAnchor(child: BudgieIcon(size: height)),
            ),
            Positioned(
              left: 327.54 * u,
              top: 33.53 * u,
              width: 740.4 * u,
              height: 217.9 * u,
              child: SvgPicture.asset(
                onLight ? Brand.wordmarkNavy : Brand.wordmarkWhite,
                fit: BoxFit.fill,
                excludeFromSemantics: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stacked lockup (icon over wordmark over tagline) for the sign-in screen,
/// proportioned like lockup/budgie-stacked-*.png. White text (dark UI).
class BudgieStackedLockup extends StatelessWidget {
  const BudgieStackedLockup({super.key, this.width = 220, this.tagline = true});

  final double width;
  final bool tagline;

  @override
  Widget build(BuildContext context) {
    final w = width;
    return Semantics(
      label: tagline ? 'Budgie: tweet your budget right' : 'Budgie',
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        key: const ValueKey('brand-stacked'),
        width: w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandAnchor(child: BudgieIcon(size: w * 0.707)),
            SizedBox(height: w * 0.06),
            SvgPicture.asset(
              Brand.wordmarkWhite,
              width: w * 0.96,
              height: w * 0.96 * 194.9 / 662.2,
              excludeFromSemantics: true,
            ),
            if (tagline) ...[
              SizedBox(height: w * 0.035),
              SvgPicture.asset(
                Brand.taglineWhite,
                width: w * 0.914,
                height: w * 0.914 * 44.4 / 602.9,
                excludeFromSemantics: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
