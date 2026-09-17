import 'dart:async';

import 'package:flutter/material.dart';

import '../app_version.dart';

/// Brief launch splash: logo, title, tagline, and version.
///
/// Shown as a non-blocking overlay on top of the real app for about a
/// second. The app underneath connects and loads while the splash plays,
/// so the splash never delays anything — it is a branding beat, not a gate.
///
/// Production `main()` passes [showSplash: true]; widget tests construct
/// [TalaryApp] without it, so the 1s timer never exists in tests (a pending
/// timer would fail `pumpAndSettle`).
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({super.key, required this.child});
  final Widget child;

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay> {
  // Total splash beat: hold the card opaque ~3s (enough to read the brand
  // line comfortably), then fade it out over 400ms and drop it from the tree.
  static const _hold = Duration(milliseconds: 3000);
  static const _fade = Duration(milliseconds: 400);

  bool _fading = false; // opacity → 0
  bool _gone = false; // removed from the tree
  Timer? _fadeTimer;
  Timer? _dropTimer;

  @override
  void initState() {
    super.initState();
    _fadeTimer = Timer(_hold, () {
      if (mounted) setState(() => _fading = true);
    });
    _dropTimer = Timer(_hold + _fade, () {
      if (mounted) setState(() => _gone = true);
    });
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    _dropTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The overlay sits ABOVE the MaterialApp in the tree, so it must supply
    // its own Directionality for the Stack's alignment resolution.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          widget.child,
          if (!_gone)
            // A single animated layer: full-bleed brand background plus the
            // centered card. IgnorePointer makes the beat transparent to
            // input — a tap on the real app during the splash is never
            // swallowed; the timer drops the layer after the fade.
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: _fading ? 0 : 1,
                duration: _fade,
                curve: Curves.easeOut,
                child: Container(
                  color: const Color(0xFF1B3F40),
                  child: const _SplashCard(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SplashCard extends StatelessWidget {
  const _SplashCard();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The launcher icon already carries the brand's dark-teal field,
            // so on a matching splash background it reads as seamless.
            const SizedBox(
              width: 96,
              height: 96,
              child: Image(
                key: Key('talaria.splash.asset'),
                image: AssetImage('assets/logo.png'),
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'Talaria',
              style: TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              kAppTagline,
              style: TextStyle(
                color: Color(0xCCFFFFFF),
                fontSize: 14,
                letterSpacing: 0.2,
              ),
            ),
            // Brand line: the name and theme in one quiet sentence. A hairline
            // rule separates the product tagline from the namesake so the two
            // read as distinct, deliberate statements rather than a wall of text.
            const SizedBox(height: 18),
            Container(
              width: 40,
              height: 1.5,
              color: const Color(0xFFC9A227).withValues(alpha: 0.6),
            ),
            const SizedBox(height: 18),
            const Text(
              'The Winged Sandals of Hermes - Swift Passage, Wherever You Are.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xB3FFFFFF),
                fontSize: 13,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 28),
            Text(
              kAppVersionLabel,
              style: TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
