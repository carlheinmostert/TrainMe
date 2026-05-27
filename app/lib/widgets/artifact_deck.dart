// =============================================================================
// ArtifactDeck — Wave 6 (artifact-system, 2026-05-27)
// =============================================================================
//
// Fanned card deck mounted above the Studio exercise list. Surfaces every
// `plan_artifacts` row for the current session as a stack of cards in a
// playful fan: the front card breathes, the back cards sit at increasing
// rotations and offsets. Tap a back card to rotate it to the front; tap
// the front card to "play" the artifact (open the in-app preview for
// `plan_url`, a WebView at `/h/{planId}` for `handout`, a SnackBar stub
// for everything else).
//
// Behaviour locked from the brief:
//
//   * Only renders cards for actual `plan_artifacts` rows. No static
//     placeholders. If only `plan_url` is published, only one card
//     renders.
//   * Breathing pulse on the front card: 3.6s ease-in-out infinite,
//     scale 1.0 → 1.012 → 1.0, translateY 0 → -2px → 0.
//   * Tap-back animates that card to position 0 (the front). Others
//     reflow to their new positions over 720ms with a snappy spring.
//   * Tap-front fires a "play-burst" beat (1.1s spring-out to scale
//     1.08 with a coral halo) THEN invokes the per-kind action.
//   * Brand-skin aware: if the practice has an active brand skin, the
//     front card's coral chrome reads from the practice brand color
//     instead of the homefit default. Falls back silently to coral on
//     any failure (per `feedback_no_silent_fallbacks` — defaulting
//     coral is the documented behaviour for missing-brand state, not
//     a silent degradation of a paid feature).
//
// Replaces [ArtifactStatusRow] in Studio. The compact pill row is
// still exported for any non-Studio surfaces that mount it.
//
// Mockup parameters (transferred verbatim from the brief):
//   pos1 (front)  — translate(0,0),     rotate(0deg),  scale(1.00), opacity 1.00
//   pos2 (back-1) — translate(14,-22),  rotate(4deg),  scale(0.96), opacity 0.92
//   pos3 (back-2) — translate(28,-40),  rotate(8deg),  scale(0.92), opacity 0.78
//   pos4 (back-3) — translate(42,-56),  rotate(12deg), scale(0.88), opacity 0.60
//
// Cards past position 4 are not rendered (keeps the visual budget bounded;
// future kinds beyond 4 would clip the layout anyway).
// =============================================================================

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// Spring curve for card reflow transitions. Matches the mockup's
/// `cubic-bezier(0.34, 1.18, 0.64, 1)` — snappy with a mild overshoot.
const Cubic _kDeckSpring = Cubic(0.34, 1.18, 0.64, 1);

/// Duration for card reflow transitions.
const Duration _kDeckTransition = Duration(milliseconds: 720);

/// Per-position offsets / rotations. Index 0 is the front of the deck.
const List<_DeckPose> _kPoses = [
  _DeckPose(dx: 0, dy: 0, rotationDeg: 0, scale: 1.00, opacity: 1.00),
  _DeckPose(dx: 14, dy: -22, rotationDeg: 4, scale: 0.96, opacity: 0.92),
  _DeckPose(dx: 28, dy: -40, rotationDeg: 8, scale: 0.92, opacity: 0.78),
  _DeckPose(dx: 42, dy: -56, rotationDeg: 12, scale: 0.88, opacity: 0.60),
];

/// Single card pose tuple. The dy is negative for the back cards because
/// the deck fans UP — the front card sits at the visual bottom of the
/// stack and back cards lean over its top.
@immutable
class _DeckPose {
  final double dx;
  final double dy;
  final double rotationDeg;
  final double scale;
  final double opacity;

  const _DeckPose({
    required this.dx,
    required this.dy,
    required this.rotationDeg,
    required this.scale,
    required this.opacity,
  });

  double get rotationRadians => rotationDeg * math.pi / 180.0;
}

class ArtifactDeck extends StatefulWidget {
  /// `plan_artifacts` rows for this plan. Drives which cards render.
  /// Order is preserved — first row becomes the front card on cold open.
  final List<PlanArtifactStatus> statuses;

  /// Practice brand color (`practices.brand_color`) when the practice
  /// has an active brand-skin subscription. Null = use homefit coral.
  /// Per ADR-0029 — only resolved by the parent; the deck does NOT call
  /// `getBrandSkinState` itself (the parent already mounts the lapse
  /// banner and can share the resolved color).
  final Color? brandAccent;

  /// Called when the practitioner taps the `plan_url` front card.
  /// Wired to the existing in-app preview route from Studio.
  final VoidCallback? onPlayPlanUrl;

  /// Called when the practitioner taps the `handout` front card.
  /// Wired to the WebView at `/h/{planId}`.
  final VoidCallback? onPlayHandout;

  /// Called when the practitioner taps any other front card (poster,
  /// reel, ai_reel, calendar). Studio shows a "Coming soon" SnackBar.
  final ValueChanged<String>? onPlayOther;

  const ArtifactDeck({
    super.key,
    required this.statuses,
    this.brandAccent,
    this.onPlayPlanUrl,
    this.onPlayHandout,
    this.onPlayOther,
  });

  @override
  State<ArtifactDeck> createState() => _ArtifactDeckState();
}

class _ArtifactDeckState extends State<ArtifactDeck>
    with TickerProviderStateMixin {
  /// Visual order of the cards. First entry is the front of the deck.
  /// Re-ordered on tap-back so the tapped card lifts to position 0.
  List<PlanArtifactStatus> _order = const [];

  /// Continuous breathing animation for the front card. 3.6s ease loop.
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  /// Single-shot "play-burst" pop on tap-front. 1.1s spring-out.
  late final AnimationController _burstController;

  @override
  void initState() {
    super.initState();
    _order = _filterStatuses(widget.statuses);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat(reverse: true);
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );
    _burstController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didUpdateWidget(ArtifactDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the underlying status set changed (e.g. a new publish landed
    // and `_refreshArtifactStatuses` repainted), rebuild the order list
    // preserving the current front card if it's still present. This
    // keeps the practitioner's "I tapped to the front, then republished"
    // gesture stable — the card they were looking at stays on top.
    final next = _filterStatuses(widget.statuses);
    if (!_sameKinds(next, oldWidget.statuses)) {
      if (_order.isNotEmpty && next.any((s) => s.kind == _order[0].kind)) {
        final front = _order[0].kind;
        final reshuffled = [
          ...next.where((s) => s.kind == front),
          ...next.where((s) => s.kind != front),
        ];
        _order = reshuffled;
      } else {
        _order = next;
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _burstController.dispose();
    super.dispose();
  }

  /// Drop any status row whose `isPublished` flag is false. The deck
  /// surfaces ONLY actual artifacts — no "not yet" placeholder cards.
  /// Unknown kinds are kept; the per-card theme falls back to a generic
  /// "Coming" chrome so a future server kind isn't silently hidden.
  List<PlanArtifactStatus> _filterStatuses(List<PlanArtifactStatus> raw) {
    final out = <PlanArtifactStatus>[];
    for (final s in raw) {
      if (!s.isPublished) continue;
      out.add(s);
    }
    return out;
  }

  /// Cheap shallow comparison — drives whether [didUpdateWidget] rewires
  /// the order list. Only the kinds matter; status/credit changes are
  /// in-place updates the parent rebuild already picks up via props.
  bool _sameKinds(List<PlanArtifactStatus> a, List<PlanArtifactStatus> b) {
    if (a.length != b.length) return false;
    final aKinds = a.map((s) => s.kind).toSet();
    final bKinds = b.map((s) => s.kind).toSet();
    return aKinds.length == bKinds.length && aKinds.containsAll(bKinds);
  }

  Color get _accent => widget.brandAccent ?? AppColors.primary;

  void _onTapBack(PlanArtifactStatus tapped) {
    if (_order.isEmpty || _order[0].kind == tapped.kind) return;
    setState(() {
      _order = [
        tapped,
        ..._order.where((s) => s.kind != tapped.kind),
      ];
    });
  }

  void _onTapFront(PlanArtifactStatus front) {
    // Play-burst beat first, THEN invoke the action. The burst is
    // short (1.1s) and unblocking — the user sees the card pop +
    // halo while the navigation push (~one frame) lines up.
    if (!_burstController.isAnimating) {
      _burstController.forward(from: 0.0);
    }
    // Fire the action immediately; the burst plays over it. Navigation
    // happens synchronously so the burst will finish on the way back.
    switch (front.kind) {
      case ArtifactKind.planUrl:
        widget.onPlayPlanUrl?.call();
        break;
      case ArtifactKind.handout:
        widget.onPlayHandout?.call();
        break;
      default:
        widget.onPlayOther?.call(front.kind);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_order.isEmpty) return const SizedBox.shrink();

    // Visible budget: 4 cards. Anything past that fans outside the
    // header zone and clips against the AppBar / list.
    final visible = _order.take(_kPoses.length).toList(growable: false);

    // The deck zone height locks 130pt — enough vertical room for the
    // topmost back card's offset (-56) plus the front card's height
    // (~70) plus 4pt of breath. Less clips back cards' rotation; more
    // wastes list real estate.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        height: 130,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            // Build BACK→FRONT so the front card paints last (sits on
            // top visually). Tap targets stack correctly because front
            // is painted last → wins hit testing in the centre.
            for (var i = visible.length - 1; i >= 0; i--)
              _DeckCard(
                key: ValueKey('deck_${visible[i].kind}'),
                status: visible[i],
                pose: _kPoses[i],
                isFront: i == 0,
                accent: _accent,
                pulseAnimation: _pulseAnimation,
                burstController: _burstController,
                onTap: () {
                  if (i == 0) {
                    _onTapFront(visible[i]);
                  } else {
                    _onTapBack(visible[i]);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Single artifact card. Animates between poses when its visual index
/// changes (the parent rebuilds with a new order list).
class _DeckCard extends StatelessWidget {
  final PlanArtifactStatus status;
  final _DeckPose pose;
  final bool isFront;
  final Color accent;
  final Animation<double> pulseAnimation;
  final AnimationController burstController;
  final VoidCallback onTap;

  const _DeckCard({
    super.key,
    required this.status,
    required this.pose,
    required this.isFront,
    required this.accent,
    required this.pulseAnimation,
    required this.burstController,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Each pose component rides the spring curve in lockstep. The
    // TweenAnimationBuilder remembers the previous tween from the
    // last build, so when the parent passes a new pose (because the
    // card's visual index changed), the in-flight tween picks up the
    // new end value and animates over [_kDeckTransition].
    return AnimatedBuilder(
      animation: Listenable.merge([pulseAnimation, burstController]),
      builder: (context, _) {
        // Breathing (front only): 1.0 → 1.012 → 1.0. Translate y by -2 at peak.
        final pulseT = isFront ? pulseAnimation.value : 0.0;
        final pulseScale = 1.0 + 0.012 * pulseT;
        final pulseDy = -2.0 * pulseT;
        // Burst (front only): scale ramps to 1.08 with halo.
        final burstT = isFront ? burstController.value : 0.0;
        final burstActive = burstT > 0.0 && burstT < 1.0;
        final burstScale = burstActive ? 1.0 + 0.08 * _burstPeak(burstT) : 1.0;
        final haloOpacity = burstActive ? _burstHalo(burstT) : 0.0;

        return _AnimatedPoseTransform(
          dx: pose.dx,
          dy: pose.dy + pulseDy,
          rotation: pose.rotationRadians,
          scale: pose.scale * pulseScale * burstScale,
          opacity: pose.opacity,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (haloOpacity > 0)
                IgnorePointer(
                  child: Container(
                    width: 220,
                    height: 80,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color:
                              accent.withValues(alpha: 0.35 * haloOpacity),
                          blurRadius: 50,
                          spreadRadius: 0,
                          offset: const Offset(0, 30),
                        ),
                        BoxShadow(
                          color:
                              accent.withValues(alpha: 0.08 * haloOpacity),
                          blurRadius: 0,
                          spreadRadius: 8,
                        ),
                      ],
                    ),
                  ),
                ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: onTap,
                  child: _cardBody(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Spring-out peak: rises sharply to ~1.0 at t≈0.45, then eases back to 0.
  double _burstPeak(double t) {
    if (t < 0.45) {
      final p = t / 0.45;
      return 1.0 - (1.0 - p) * (1.0 - p);
    }
    final p = (t - 0.45) / 0.55;
    final eased = 1.0 - p * p;
    return eased;
  }

  /// Halo opacity envelope: holds peak for ~30% of the burst then fades.
  double _burstHalo(double t) {
    if (t < 0.15) return t / 0.15;
    if (t < 0.45) return 1.0;
    return (1.0 - t) / 0.55;
  }

  Widget _cardBody() {
    final theme = _ArtifactCardTheme.forKind(status.kind, accent: accent);
    final paid = status.wasPaid;
    final isUnknown = theme.isUnknown;
    final ringColor =
        isFront ? accent.withValues(alpha: 0.45) : AppColors.surfaceBorder;
    final pillBg = paid
        ? accent.withValues(alpha: 0.16)
        : AppColors.rest.withValues(alpha: 0.16);
    final pillFg = paid ? accent : AppColors.rest;
    final pillText = paid ? 'Published' : 'Live';
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceBase,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ringColor, width: isFront ? 1.4 : 1),
        boxShadow: isFront
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ]
            : const [],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: theme.glyphBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(theme.glyph, size: 16, color: theme.glyphFg),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  theme.label,
                  style: const TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.textOnDark,
                    letterSpacing: -0.1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isUnknown ? AppColors.surfaceRaised : pillBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  isUnknown ? 'Coming' : pillText,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w600,
                    fontSize: 9.5,
                    color: isUnknown
                        ? AppColors.textSecondaryOnDark
                        : pillFg,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            theme.subtitle,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11.5,
              color: AppColors.textSecondaryOnDark.withValues(alpha: 0.85),
              height: 1.35,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Composite of TweenAnimationBuilders that ride one shared spring
/// curve. Wrapping the dx/dy/rotation/scale/opacity in a single helper
/// keeps the build tree readable; nesting five tween builders inline
/// is much harder to follow.
class _AnimatedPoseTransform extends StatelessWidget {
  final double dx;
  final double dy;
  final double rotation;
  final double scale;
  final double opacity;
  final Widget child;

  const _AnimatedPoseTransform({
    required this.dx,
    required this.dy,
    required this.rotation,
    required this.scale,
    required this.opacity,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Animate the composite via a single 0..1 driver. Each component
    // reads its target value from props; the implicit tween caches the
    // previous build's value and animates over [_kDeckTransition].
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: dx, end: dx),
      duration: _kDeckTransition,
      curve: _kDeckSpring,
      builder: (context, animDx, _) {
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: dy, end: dy),
          duration: _kDeckTransition,
          curve: _kDeckSpring,
          builder: (context, animDy, _) {
            return TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: rotation, end: rotation),
              duration: _kDeckTransition,
              curve: _kDeckSpring,
              builder: (context, animRot, _) {
                return TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: scale, end: scale),
                  duration: _kDeckTransition,
                  curve: _kDeckSpring,
                  builder: (context, animScale, _) {
                    return TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: opacity, end: opacity),
                      duration: _kDeckTransition,
                      curve: _kDeckSpring,
                      builder: (context, animOpacity, _) {
                        return Transform.translate(
                          offset: Offset(animDx, animDy),
                          child: Transform.rotate(
                            angle: animRot,
                            child: Transform.scale(
                              scale: animScale,
                              child: Opacity(
                                opacity: animOpacity,
                                child: child,
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Per-kind visual chrome. Centralises labels/glyphs/copy so the deck
/// renders consistently for every known kind, plus a generic fallback
/// for forward-compat.
@immutable
class _ArtifactCardTheme {
  final String label;
  final String subtitle;
  final IconData glyph;
  final Color glyphFg;
  final Color glyphBg;
  final bool isUnknown;

  const _ArtifactCardTheme({
    required this.label,
    required this.subtitle,
    required this.glyph,
    required this.glyphFg,
    required this.glyphBg,
    this.isUnknown = false,
  });

  factory _ArtifactCardTheme.forKind(String kind, {required Color accent}) {
    switch (kind) {
      case ArtifactKind.handout:
        return _ArtifactCardTheme(
          label: 'Workout handout',
          subtitle: 'Printable page — exercises, reps, hold, notes.',
          glyph: Icons.description_outlined,
          glyphFg: AppColors.primaryLight,
          glyphBg: AppColors.primary.withValues(alpha: 0.14),
        );
      case ArtifactKind.planUrl:
        return _ArtifactCardTheme(
          label: 'Workout player',
          subtitle: 'Shareable link — clients press play and follow along.',
          glyph: Icons.play_arrow_rounded,
          glyphFg: accent,
          glyphBg: accent.withValues(alpha: 0.14),
        );
      case ArtifactKind.poster:
        return _ArtifactCardTheme(
          label: 'Poster',
          subtitle: 'Single shareable image — WhatsApp unfurl, social.',
          glyph: Icons.image_outlined,
          glyphFg: AppColors.textSecondaryOnDark,
          glyphBg: AppColors.surfaceRaised,
        );
      case ArtifactKind.reel:
        return _ArtifactCardTheme(
          label: 'Reel',
          subtitle: 'Stitched vertical highlight — share on TikTok / Reels.',
          glyph: Icons.grid_view_rounded,
          glyphFg: AppColors.textSecondaryOnDark,
          glyphBg: AppColors.surfaceRaised,
        );
      case ArtifactKind.aiReel:
        return _ArtifactCardTheme(
          label: 'AI reel',
          subtitle: 'AI-stylised demo cut. Coming in a future release.',
          glyph: Icons.auto_awesome,
          glyphFg: AppColors.textSecondaryOnDark,
          glyphBg: AppColors.surfaceRaised,
        );
      case ArtifactKind.calendar:
        return _ArtifactCardTheme(
          label: 'Calendar',
          subtitle:
              'Scheduled drops to the client. Coming in a future release.',
          glyph: Icons.event_outlined,
          glyphFg: AppColors.textSecondaryOnDark,
          glyphBg: AppColors.surfaceRaised,
        );
      default:
        // Forward-compat: a future server kind without a registered
        // spec on this client. Render with the raw `kind` string so it's
        // visible (not silently dropped — `feedback_no_silent_fallbacks`).
        return _ArtifactCardTheme(
          label: kind,
          subtitle: 'New artifact kind. Update the app to interact.',
          glyph: Icons.help_outline,
          glyphFg: AppColors.textSecondaryOnDark,
          glyphBg: AppColors.surfaceRaised,
          isUnknown: true,
        );
    }
  }
}
