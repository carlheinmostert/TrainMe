// =============================================================================
// SessionArtifactAccordion — 2026-05-27 (artifact-card accordion)
// =============================================================================
//
// Per-session card with a peek depth cue + tappable expand chevron + inline
// vertical accordion that lists the session's published `plan_artifacts`.
// Mounts on three surfaces with R-10 parity:
//
//   * ClientSessionsScreen (`app/lib/screens/client_sessions_screen.dart`)
//   * My Workouts          (`app/lib/screens/my_workouts_screen.dart`)
//   * Web `/me`            (`web-player/me.{js,css}`)
//
// Supersedes the fanned-deck UI shipped in PR #548. Studio no longer mounts
// the artifact deck above the exercise list — Studio is the editing surface
// again. The browsing surfaces gain a subtle depth cue when artifacts exist
// and an in-place vertical expand.
//
// Visual behavior (matches `docs/design/mockups/2026-05-27-artifact-card-expansion.html`):
//
//   - Rest, artifacts present     — peek card behind (4px right, 5px down);
//                                   coral chevron-down at right of card body.
//   - Rest, no artifacts          — no peek, no chevron. Identical to today.
//   - Expanded                    — peek lifts + fades; siblings push down;
//                                   artifact cards stagger in below the
//                                   session card; coral 3px rail draws on
//                                   the left edge of the stack.
//
// Tap zones:
//   - Card BODY → existing behaviour (open Studio for this session).
//   - Chevron 44pt hit zone → toggle this session's expanded state.
//   - Artifact card → kind-specific action (preview / handout / coming soon).
//
// Animation timings (per spec):
//   - Sibling push-down: 140ms ease-out (driven by AnimatedSize).
//   - Peek lift + fade : 220ms snappy spring.
//   - Artifact stagger : 320ms each, 60ms per card delay.
//   - Coral rail draw  : 380ms snappy spring with 30ms delay.
//   - Chevron rotate   : 280ms snappy spring (0deg -> 180deg).
//
// `MediaQuery.disableAnimations` (mirrors `prefers-reduced-motion: reduce`):
//   - Peek lift, stagger, rail draw collapse to 0ms.
//   - Chevron rotation keeps a short 140ms tween because it's a directional
//     indicator, not decoration.
//
// Data flow:
//   - Parent screen loads `plan_artifacts` per session via the existing
//     `ApiClient.listPlanArtifactStatuses` from PR #548. NO new RPC.
//   - Parent owns "which session id is expanded" so the accordion is
//     mutually exclusive across the list (tap session B -> A collapses).
//   - When the parent has no artifacts loaded yet, [artifactStatuses] is
//     null; the card paints WITHOUT peek or chevron (graceful empty state).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/session.dart';
import '../models/workout_source_tag.dart';
import '../services/api_client.dart'
    show ArtifactKind, PlanArtifactStatus, PlanAnalyticsSummary;
import '../theme.dart';
import 'session_card.dart';

/// Snappy spring curve used across the expand/collapse animation set.
/// Matches the mockup's `cubic-bezier(.2, .9, .25, 1.2)`.
const Cubic _kSnappySpring = Cubic(0.2, 0.9, 0.25, 1.2);

/// Sibling push-down via AnimatedSize. 140ms ease-out per the spec.
const Duration _kPushDuration = Duration(milliseconds: 140);

/// Chevron rotation 0 -> 180deg. Stays even under reduced-motion (140ms
/// then) because it's a directional indicator.
const Duration _kChevronDuration = Duration(milliseconds: 280);
const Duration _kChevronReducedMotionDuration = Duration(milliseconds: 140);

/// Peek lift + fade. 220ms snappy spring at full motion; 0ms reduced.
const Duration _kPeekDuration = Duration(milliseconds: 220);

/// Per-artifact stagger durations.
const Duration _kArtifactDuration = Duration(milliseconds: 320);
const Duration _kArtifactDelayStep = Duration(milliseconds: 60);
const Duration _kArtifactInitialDelay = Duration(milliseconds: 50);

/// Coral rail draw — slight initial delay so the siblings push down first.
const Duration _kRailDuration = Duration(milliseconds: 380);
const Duration _kRailDelay = Duration(milliseconds: 30);

/// Pixel size of the peek offset (4px right, 5px down per spec).
const double _kPeekOffsetX = 4.0;
const double _kPeekOffsetY = 5.0;

/// Min hit-area for the expand chevron (Apple HIG).
const double _kChevronHitSize = 44.0;

/// Width of the coral hairline rail (3px per spec).
const double _kRailWidth = 3.0;

/// Internal left-padding on artifact cards so the rail doesn't obscure
/// content. The rail itself sits flush at x=0; cards have padding-left
/// equal to (rail width + ~17px breathing room) ≈ 20px.
const double _kArtifactContentInsetLeft = 20.0;

/// Wrap a [SessionCard] with the artifact-stack expansion affordance.
///
/// When [artifactStatuses] is non-null AND contains at least one
/// published row, the card paints a peek behind it + a tappable coral
/// chevron on the right. Tapping the chevron toggles the expanded state
/// (the parent owns the canonical "which session id is expanded" and
/// passes it back via [expanded] + [onToggleExpanded]).
///
/// Sessions with zero artifacts paint exactly like today — no peek, no
/// chevron, tap-anywhere opens Studio.
class SessionArtifactAccordion extends StatelessWidget {
  /// Session row to render. Forwarded verbatim to [SessionCard].
  final Session session;

  /// Already-loaded `plan_artifacts` rows for this session. Pass null
  /// while the parent is still fetching — the card paints WITHOUT peek
  /// or chevron during the loading window so unpublished sessions never
  /// briefly flicker the depth cue. Empty list = "loaded, none yet".
  final List<PlanArtifactStatus>? artifactStatuses;

  /// True iff THIS session is the currently-expanded one in the parent
  /// list. The parent owns the accordion state (single-expanded across
  /// the list).
  final bool expanded;

  /// Toggle callback fired when the practitioner taps the chevron's
  /// 44pt hit zone. Parent re-assigns its `_expandedSessionId`.
  final VoidCallback onToggleExpanded;

  /// Existing pass-through for tap on the card body. Routed by the
  /// parent to push the session shell.
  final VoidCallback onOpen;

  /// Soft-delete on swipe (R-01). Forwarded to [SessionCard.onDelete].
  final VoidCallback onDelete;

  /// Optional analytics summary forwarded to [SessionCard].
  final PlanAnalyticsSummary? analyticsSummary;

  /// Optional source-tag forwarded to [SessionCard]. My Workouts opts
  /// in (passes [WorkoutSourceTag.self]); ClientSessions passes null.
  final WorkoutSourceTag? sourceTag;

  /// Optional shared-by email (for inbound-shared sessions).
  final String? sharedByEmail;

  /// Rename forwarded to [SessionCard]. Parent reflects the new title
  /// in its in-memory list to avoid the roundtrip flicker.
  final ValueChanged<Session>? onRenamed;

  /// Optional practice brand color. When non-null AND the practice has
  /// an active brand-skin subscription, the FRONT artifact card uses
  /// this color instead of homefit coral. The rail stays coral
  /// regardless (per spec — the rail is the structural parent-child
  /// indicator). PR #548 owns the brand-skin resolve; the parent screen
  /// passes the resolved color in.
  final Color? brandAccent;

  /// Open the `plan_url` artifact (in-app preview deck on mobile; a
  /// link on web). Mobile callers route this to the existing
  /// `UnifiedPreviewScreen`.
  final VoidCallback? onPlayPlanUrl;

  /// Open the `handout` artifact (full-screen WebView at `/h/{planId}`
  /// on mobile; a link on web).
  final VoidCallback? onPlayHandout;

  /// Tap on any other kind (poster, reel, ai_reel, calendar). Studio
  /// previously fired a "Coming soon" SnackBar via this callback —
  /// preserved per PR #548 contract.
  final ValueChanged<String>? onPlayOther;

  const SessionArtifactAccordion({
    super.key,
    required this.session,
    required this.artifactStatuses,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onOpen,
    required this.onDelete,
    this.analyticsSummary,
    this.sourceTag,
    this.sharedByEmail,
    this.onRenamed,
    this.brandAccent,
    this.onPlayPlanUrl,
    this.onPlayHandout,
    this.onPlayOther,
  });

  /// Drop unpublished rows. The accordion never surfaces "coming"
  /// placeholders — only what's actually been published.
  static List<PlanArtifactStatus> _published(
    List<PlanArtifactStatus> raw,
  ) {
    final out = <PlanArtifactStatus>[];
    for (final s in raw) {
      if (!s.isPublished) continue;
      out.add(s);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final published =
        artifactStatuses == null ? const <PlanArtifactStatus>[] : _published(artifactStatuses!);
    final hasArtifacts = published.isNotEmpty;
    // No artifacts -> render the card exactly as today; no wrapper chrome.
    if (!hasArtifacts) {
      return SessionCard(
        session: session,
        isPublishing: false,
        onOpen: onOpen,
        onDelete: onDelete,
        analyticsSummary: analyticsSummary,
        sourceTag: sourceTag,
        sharedByEmail: sharedByEmail,
        onRenamed: onRenamed,
      );
    }

    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations == true;
    final peekDuration = reduceMotion ? Duration.zero : _kPeekDuration;
    final chevronDuration =
        reduceMotion ? _kChevronReducedMotionDuration : _kChevronDuration;

    final chevron = _ChevronToggle(
      expanded: expanded,
      duration: chevronDuration,
      onTap: onToggleExpanded,
    );

    // Visual stack:
    //   z=0 peek card (drawn behind, offset 4x5 down/right)
    //   z=1 SessionCard with the custom chevron
    //   below SessionCard: AnimatedSize accordion containing the rail +
    //                      artifact cards. Hidden when not expanded.
    final cardWithPeek = Stack(
      clipBehavior: Clip.none,
      children: [
        // The peek translation is in absolute pixels; we use a Padding
        // wrapper so the peek extends OUTSIDE the SessionCard footprint
        // by 4px right (the bottom 5px is contained by inset stacking).
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: peekDuration,
              opacity: expanded ? 0.0 : 0.92,
              curve: _kSnappySpring,
              child: AnimatedSlide(
                duration: peekDuration,
                curve: _kSnappySpring,
                // Rest: offset 4x5 down/right (mockup spec). Expanded:
                // slide UPWARD by 6px so the peek "lifts" out of view.
                offset: expanded
                    ? const Offset(0.0, -0.04)
                    : const Offset(0.012, 0.05),
                child: AnimatedScale(
                  duration: peekDuration,
                  curve: _kSnappySpring,
                  scale: expanded ? 0.98 : 1.0,
                  child: _PeekCard(),
                ),
              ),
            ),
          ),
        ),
        // Card with peek offsets: nudge the actual card UP+LEFT by half
        // the peek vector so the perceived alignment puts the peek
        // BEHIND and slightly below+right of the card. Without this the
        // peek sits flush and you can't see its edges.
        Padding(
          padding: const EdgeInsets.only(
            right: _kPeekOffsetX,
            bottom: _kPeekOffsetY,
          ),
          child: SessionCard(
            session: session,
            isPublishing: false,
            onOpen: onOpen,
            onDelete: onDelete,
            analyticsSummary: analyticsSummary,
            sourceTag: sourceTag,
            sharedByEmail: sharedByEmail,
            onRenamed: onRenamed,
            trailingOverride: chevron,
          ),
        ),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        cardWithPeek,
        // AnimatedSize handles the sibling push-down for free — height
        // animates from 0 to natural over [_kPushDuration].
        ClipRect(
          child: AnimatedSize(
            duration: _kPushDuration,
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: expanded
                ? _ArtifactStack(
                    statuses: published,
                    brandAccent: brandAccent,
                    reduceMotion: reduceMotion,
                    onPlayPlanUrl: onPlayPlanUrl,
                    onPlayHandout: onPlayHandout,
                    onPlayOther: onPlayOther,
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ),
      ],
    );
  }
}

/// 44pt hit-zone for the expand chevron. The visible glyph is 24pt at
/// the centre; the hit zone is the full square. Wired as a Material +
/// InkWell so the press state lights a faint coral tint matching the
/// mockup. The chevron rotates 180deg on the expanded state.
class _ChevronToggle extends StatelessWidget {
  final bool expanded;
  final Duration duration;
  final VoidCallback onTap;

  const _ChevronToggle({
    required this.expanded,
    required this.duration,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: expanded ? 'Collapse artifacts' : 'Expand artifacts',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          // Coral tint on hover/press. iOS doesn't surface hover but
          // the press state still reads through InkWell's splash.
          splashColor: AppColors.primary.withValues(alpha: 0.16),
          highlightColor: AppColors.primary.withValues(alpha: 0.08),
          child: SizedBox(
            width: _kChevronHitSize,
            height: _kChevronHitSize,
            child: Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  begin: 0.0,
                  end: expanded ? 1.0 : 0.0,
                ),
                duration: duration,
                curve: _kSnappySpring,
                builder: (context, t, _) {
                  return Transform.rotate(
                    // 0 -> pi rotates the down-chevron to up.
                    angle: t * 3.14159265,
                    child: const Icon(
                      Icons.keyboard_arrow_down,
                      color: AppColors.primary,
                      size: 24,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Peek card painted behind the SessionCard. One-shade-lighter surface,
/// 14px radius (matches SessionCard's 12px outer + 1px border + 1px
/// hairline → visually 14px), faint top-right shadow.
class _PeekCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: _kPeekOffsetX,
        top: _kPeekOffsetY,
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.surfaceBorder,
            width: 1,
          ),
        ),
      ),
    );
  }
}

/// Vertical stack of artifact cards rendered below the SessionCard
/// when the accordion is expanded. Each card animates in with a
/// staggered translate+fade. A 3px coral rail draws along the left
/// edge (scaleY 0 -> 1).
class _ArtifactStack extends StatelessWidget {
  final List<PlanArtifactStatus> statuses;
  final Color? brandAccent;
  final bool reduceMotion;
  final VoidCallback? onPlayPlanUrl;
  final VoidCallback? onPlayHandout;
  final ValueChanged<String>? onPlayOther;

  const _ArtifactStack({
    required this.statuses,
    required this.brandAccent,
    required this.reduceMotion,
    this.onPlayPlanUrl,
    this.onPlayHandout,
    this.onPlayOther,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Pad-top: 10px breathing room from the session card.
      // Pad-bottom: 4px so the expanded stack doesn't run flush into
      //              the next session card.
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // z=0 — coral rail. scaleY 0 -> 1 from top, with a small
          // initial delay so siblings push down before the rail draws.
          // Reduced-motion: instant (Duration.zero).
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: _RailAnimator(
              reduceMotion: reduceMotion,
            ),
          ),
          // z=1 — vertical artifact card list with per-card stagger.
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < statuses.length; i++) ...[
                _ArtifactCardStagger(
                  index: i,
                  reduceMotion: reduceMotion,
                  child: _ArtifactCard(
                    status: statuses[i],
                    isFront: i == 0,
                    brandAccent: brandAccent,
                    onTap: () => _dispatchPlay(statuses[i]),
                  ),
                ),
                if (i < statuses.length - 1) const SizedBox(height: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }

  void _dispatchPlay(PlanArtifactStatus status) {
    HapticFeedback.selectionClick();
    switch (status.kind) {
      case ArtifactKind.planUrl:
        onPlayPlanUrl?.call();
        break;
      case ArtifactKind.handout:
        onPlayHandout?.call();
        break;
      default:
        onPlayOther?.call(status.kind);
        break;
    }
  }
}

/// Animates a single artifact card's translate+fade entrance with a
/// per-index delay. Hosting this on a `StatefulWidget` lets the
/// animation controller stagger via [Future.delayed]; an explicit
/// implicit-animation tween with `delay:` doesn't exist in Flutter's
/// `AnimatedFoo` family so we drive it manually with a 1-shot
/// controller.
class _ArtifactCardStagger extends StatefulWidget {
  final int index;
  final bool reduceMotion;
  final Widget child;

  const _ArtifactCardStagger({
    required this.index,
    required this.reduceMotion,
    required this.child,
  });

  @override
  State<_ArtifactCardStagger> createState() => _ArtifactCardStaggerState();
}

class _ArtifactCardStaggerState extends State<_ArtifactCardStagger>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.reduceMotion ? Duration.zero : _kArtifactDuration,
    );
    if (widget.reduceMotion) {
      // Instant under reduced-motion.
      _controller.value = 1.0;
    } else {
      // Stagger: 50ms + 60ms * index. Use Future.delayed to gate the
      // forward call so cards land sequentially.
      final delay = _kArtifactInitialDelay + _kArtifactDelayStep * widget.index;
      Future.delayed(delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final eased = Curves.easeOut.transform(_controller.value);
        return Opacity(
          opacity: eased,
          child: Transform.translate(
            // Start at -8px (above target), settle to 0.
            offset: Offset(0, -8 * (1 - eased)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// 3px coral hairline rail. ScaleY 0 -> 1 from the top.
class _RailAnimator extends StatefulWidget {
  final bool reduceMotion;

  const _RailAnimator({required this.reduceMotion});

  @override
  State<_RailAnimator> createState() => _RailAnimatorState();
}

class _RailAnimatorState extends State<_RailAnimator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.reduceMotion ? Duration.zero : _kRailDuration,
    );
    if (widget.reduceMotion) {
      _controller.value = 1.0;
    } else {
      Future.delayed(_kRailDelay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _kSnappySpring.transform(_controller.value);
        return Align(
          alignment: Alignment.topCenter,
          child: FractionallySizedBox(
            heightFactor: t,
            child: Container(
              width: _kRailWidth,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(_kRailWidth / 2),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Single artifact card row. Reuses the kind-glyph / kind-label /
/// kind-pill grammar from PR #548's ArtifactDeck so the visual stays
/// recognisable. Full-width (matches the parent session card's width);
/// the coral rail sits flush at the LEFT edge of the card and the
/// content has extra left-padding so the rail doesn't obscure the
/// thumbnail.
class _ArtifactCard extends StatelessWidget {
  final PlanArtifactStatus status;
  final bool isFront;
  final Color? brandAccent;
  final VoidCallback onTap;

  const _ArtifactCard({
    required this.status,
    required this.isFront,
    required this.brandAccent,
    required this.onTap,
  });

  Color get _accent => brandAccent ?? AppColors.primary;

  @override
  Widget build(BuildContext context) {
    final theme = _ArtifactCardTheme.forKind(status.kind, accent: _accent);
    final paid = status.wasPaid;
    final isUnknown = theme.isUnknown;
    // Front card uses the accent (coral OR brand-skin color); others
    // use the surface border. Per spec: the rail stays coral regardless
    // of brand skin; only the front card's chrome reflects the brand.
    final borderColor = isFront ? _accent : AppColors.surfaceBorder;
    final pillBg = paid
        ? _accent.withValues(alpha: 0.16)
        : AppColors.rest.withValues(alpha: 0.16);
    final pillFg = paid ? _accent : AppColors.rest;
    final pillText = paid ? 'Published' : 'Live';

    return Material(
      color: AppColors.surfaceRaised,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: borderColor,
              width: isFront ? 1.4 : 1,
            ),
            boxShadow: isFront
                ? [
                    BoxShadow(
                      color: _accent.withValues(alpha: 0.18),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : const [],
          ),
          // Extra left padding so the coral rail at x=0 doesn't obscure
          // the thumbnail glyph. Other edges match the spec.
          padding: const EdgeInsets.only(
            left: _kArtifactContentInsetLeft,
            right: 14,
            top: 12,
            bottom: 12,
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.glyphBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(theme.glyph, size: 22, color: theme.glyphFg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      theme.label,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: AppColors.textOnDark,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isUnknown ? AppColors.surfaceRaised : pillBg,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        isUnknown ? 'Coming soon' : pillText,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                          fontSize: 10,
                          color: isUnknown
                              ? AppColors.textSecondaryOnDark
                              : pillFg,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Per-kind visual chrome. Mirrors the same vocabulary PR #548 exposed
/// on the fanned-deck cards so the visual stays familiar (label,
/// glyph, accent). The unknown-kind branch carries forward the
/// `feedback_no_silent_fallbacks` discipline: an unknown server kind
/// stays visible (not hidden) with a "Coming soon" pill.
@immutable
class _ArtifactCardTheme {
  final String label;
  final IconData glyph;
  final Color glyphFg;
  final Color glyphBg;
  final bool isUnknown;

  const _ArtifactCardTheme({
    required this.label,
    required this.glyph,
    required this.glyphFg,
    required this.glyphBg,
    this.isUnknown = false,
  });

  factory _ArtifactCardTheme.forKind(String kind, {required Color accent}) {
    switch (kind) {
      case ArtifactKind.handout:
        return _ArtifactCardTheme(
          label: 'Take-home handout',
          glyph: Icons.description_outlined,
          glyphFg: AppColors.primaryLight,
          glyphBg: AppColors.primary.withValues(alpha: 0.14),
        );
      case ArtifactKind.planUrl:
        return _ArtifactCardTheme(
          label: 'Workout plan',
          glyph: Icons.play_arrow_rounded,
          glyphFg: accent,
          glyphBg: accent.withValues(alpha: 0.14),
        );
      case ArtifactKind.poster:
        return _ArtifactCardTheme(
          label: 'Poster',
          glyph: Icons.image_outlined,
          glyphFg: AppColors.textSecondaryOnDark,
          glyphBg: AppColors.surfaceRaised,
        );
      case ArtifactKind.reel:
        return _ArtifactCardTheme(
          label: 'Reel',
          glyph: Icons.grid_view_rounded,
          glyphFg: AppColors.textSecondaryOnDark,
          glyphBg: AppColors.surfaceRaised,
        );
      case ArtifactKind.aiReel:
        return _ArtifactCardTheme(
          label: 'AI reel',
          glyph: Icons.auto_awesome,
          glyphFg: AppColors.textSecondaryOnDark,
          glyphBg: AppColors.surfaceRaised,
        );
      case ArtifactKind.calendar:
        return _ArtifactCardTheme(
          label: 'Calendar',
          glyph: Icons.event_outlined,
          glyphFg: AppColors.textSecondaryOnDark,
          glyphBg: AppColors.surfaceRaised,
        );
      default:
        return _ArtifactCardTheme(
          label: kind,
          glyph: Icons.help_outline,
          glyphFg: AppColors.textSecondaryOnDark,
          glyphBg: AppColors.surfaceRaised,
          isUnknown: true,
        );
    }
  }
}

