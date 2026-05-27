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
// Visual behavior (matches `docs/design/mockups/2026-05-27-artifact-card-expansion.html`,
// with the 2026-05-27 afternoon iteration applied):
//
//   - Rest, artifacts present     — peek card behind (4px right, 5px down);
//                                   two stacked coral action buttons at the
//                                   right end of the card-body row.
//   - Rest, no artifacts          — no peek; only the Studio button renders
//                                   in the action stack. (The artifacts
//                                   button is hidden when there's nothing
//                                   to expand.)
//   - Expanded                    — peek lifts + fades; siblings push down;
//                                   artifact cards slide down from behind
//                                   the session card with depth-proportional
//                                   travel + 140ms stagger (deal-of-cards);
//                                   coral 3px rail draws inside the 13dp
//                                   gutter on the left of the artifact stack.
//
// Tap zones:
//   - Card BODY → existing behaviour (open Studio for this session).
//   - Studio action button (top) → same enterStudio action; stops propagation.
//   - Artifacts action button (bottom, when has artifacts) → toggle expanded.
//   - Artifact card → kind-specific action (preview / handout / coming soon).
//
// Animation timings (per spec, 2026-05-27 afternoon iteration — slowed for
// "deal of cards" rhythm):
//   - Sibling push-down       : 200ms ease-out (was 140ms).
//   - Peek lift + fade        : 380ms snappy spring (was 220ms).
//   - Container grow          : 540ms snappy spring (driven by AnimatedSize).
//   - Artifact card slide     : 820ms each, cubic-bezier(.2,.85,.25,1.18).
//   - Per-card stagger        : 140ms per card (cards land at 80 / 220 /
//                               360 / 500 / 640ms after expand starts).
//   - Coral rail draw         : 640ms snappy spring + 60ms head-start delay.
//   - Action-button chevron   : 280ms snappy spring (0deg -> 180deg).
//
// Per-card depth-proportional starting translateY values (reinforces the
// "deck of cards underneath" mental model — deeper cards travel farther):
//   - Card 1: -180% (above target by 1.8x card-height)
//   - Card 2: -280%
//   - Card 3: -380%
//   - Card 4: -480%
//   - Cards 5+: -480% (cap)
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

/// Slightly heavier spring used for the deal-of-cards card slide so the
/// long travel reads as a "shuffle" rather than a snap. Matches the
/// mockup's `cubic-bezier(.2, .85, .25, 1.18)`.
const Cubic _kDealSpring = Cubic(0.2, 0.85, 0.25, 1.18);

/// Container grow on expand — 540ms snappy spring (was 360ms in the
/// initial PR #549 implementation). Drives the AnimatedSize child swap so
/// the height tween matches the slowed deal-of-cards rhythm. The legacy
/// sibling-push-down constant (200ms ease-out per the iteration spec) is
/// subsumed by this single AnimatedSize duration — the height-grow tween
/// IS the visible sibling reflow, and decoupling the two adds no value
/// while complicating reasoning about timing.
const Duration _kContainerGrowDuration = Duration(milliseconds: 540);

/// Chevron rotation 0 -> 180deg. Stays even under reduced-motion (140ms
/// then) because it's a directional indicator.
const Duration _kChevronDuration = Duration(milliseconds: 280);
const Duration _kChevronReducedMotionDuration = Duration(milliseconds: 140);

/// Peek lift + fade. 380ms snappy spring (was 220ms) at full motion;
/// 0ms reduced.
const Duration _kPeekDuration = Duration(milliseconds: 380);

/// Per-artifact card slide. 820ms each (was 320ms) on the deal-of-cards
/// spring. Per-card stagger of 140ms with an 80ms initial delay (card
/// N lands at 80 + 140*(N-1) ms after the row enters .expanded).
const Duration _kArtifactDuration = Duration(milliseconds: 820);
const Duration _kArtifactDelayStep = Duration(milliseconds: 140);
const Duration _kArtifactInitialDelay = Duration(milliseconds: 80);

/// Coral rail draw — 640ms snappy spring (was 380ms) with a 60ms initial
/// delay so siblings push down before the rail draws (was 30ms).
const Duration _kRailDuration = Duration(milliseconds: 640);
const Duration _kRailDelay = Duration(milliseconds: 60);

/// Pixel size of the peek offset (4px right, 5px down per spec).
const double _kPeekOffsetX = 4.0;
const double _kPeekOffsetY = 5.0;

/// Width of the coral hairline rail (3px per spec).
const double _kRailWidth = 3.0;

/// Gutter inset for artifact cards. Artifact cards sit inset 10dp from
/// the session card's left edge; the rail lives in the resulting 13dp
/// gutter (10dp visible space + 3dp rail width = 13dp total). The card
/// chrome no longer obscures the rail.
const double _kArtifactGutterInset = 10.0;
const double _kArtifactInnerLeftPad = _kArtifactGutterInset + _kRailWidth;

/// Per-card depth-proportional starting offset as a fraction of card
/// height. Card 1 starts 1.8x card-height above; deeper cards travel
/// further. Mirrors the mockup's `translateY(-180%)` / `-280%` / etc.
/// Cards beyond index 3 are clamped at -480% (the deepest visual cue).
const List<double> _kCardDepthOffsets = <double>[-1.8, -2.8, -3.8, -4.8];

/// Approximate artifact-card height used to translate the depth-fraction
/// constants into pixel-space translations. The actual cards are 12pt
/// vertical padding + 44pt glyph = ~68pt; we use 68 here so the
/// `cardDepthOffset * cardHeight` math reads truly in CSS-percent-of-self
/// terms (CSS uses height-of-element; Flutter Transform.translate uses
/// pixels). Tuning this affects only how far the card peeks out from
/// behind the session card before settling.
const double _kCardHeightForDepth = 68.0;

/// Wrap a [SessionCard] with the artifact-stack expansion affordance.
///
/// Every session card mounts a two-button action stack in the trailing
/// slot — Studio on top (always visible) and Artifacts on bottom (only
/// when the row has published artifacts). When [artifactStatuses] is
/// non-null AND contains at least one published row, the card also
/// paints a peek behind it. Tapping the Artifacts button toggles the
/// expanded state (the parent owns the canonical "which session id is
/// expanded" and passes it back via [expanded] + [onToggleExpanded]).
///
/// Sessions with zero artifacts paint without the peek and without the
/// Artifacts button — only the Studio button rides in the trailing
/// slot, plus a normal-looking SessionCard body.
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

  /// Toggle callback fired when the practitioner taps the Artifacts
  /// action button. Parent re-assigns its `_expandedSessionId`.
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

    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations == true;
    final peekDuration = reduceMotion ? Duration.zero : _kPeekDuration;
    final chevronDuration =
        reduceMotion ? _kChevronReducedMotionDuration : _kChevronDuration;
    final containerDuration =
        reduceMotion ? Duration.zero : _kContainerGrowDuration;

    // Two stacked action buttons replace the chevron-only hit zone. The
    // Studio button is always visible (every session can be opened in
    // Studio); the Artifacts button only renders when there are
    // published artifacts to expand.
    final actionStack = _ActionStack(
      expanded: expanded,
      hasArtifacts: hasArtifacts,
      chevronDuration: chevronDuration,
      onStudio: onOpen,
      onToggleArtifacts: hasArtifacts ? onToggleExpanded : null,
    );

    // When the session has no artifacts the card is paint-clean: no peek
    // card behind, no Stack wrapper, no accordion. Only the Studio button
    // action stack rides in the trailing slot. This preserves the spec
    // promise: unpublished sessions look exactly as today PLUS the new
    // explicit Studio affordance.
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
        trailingOverride: actionStack,
      );
    }

    // Visual stack:
    //   z=0 peek card (drawn behind, offset 4x5 down/right)
    //   z=1 SessionCard with the stacked action buttons in the trailing slot
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
            trailingOverride: actionStack,
          ),
        ),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        cardWithPeek,
        // AnimatedSize handles the sibling push-down (200ms) + container
        // grow (540ms when in motion). The longer of the two wins as the
        // single AnimatedSize duration — the cards' own slide animation
        // (820ms each, staggered) runs INSIDE this container and is
        // clipped behind the session card via the rail-rail Stack's
        // overflow until they land.
        ClipRect(
          child: AnimatedSize(
            duration: containerDuration,
            curve: _kSnappySpring,
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

/// Two stacked action buttons replacing the legacy chevron-only hit zone.
/// Mounts in the SessionCard's trailingOverride slot.
///
/// Top button — Studio entry (pencil + chevron-right). Always visible,
/// fires the same `enterStudio` action as a tap on the card body. The
/// button is an additional explicit affordance, not a replacement — the
/// card body still taps to open Studio.
///
/// Bottom button — Artifacts expand (stacked-cards + chevron-down).
/// Visible only when the row has at least one published artifact. The
/// chevron-down glyph rotates 180° on the expanded state.
///
/// Each button is ~36pt visible; the parent stack uses a small negative
/// margin so the COMBINED hit area extends into the card-body padding,
/// keeping each button at Apple HIG's 44pt minimum tap target.
class _ActionStack extends StatelessWidget {
  final bool expanded;
  final bool hasArtifacts;
  final Duration chevronDuration;
  final VoidCallback onStudio;
  // Null when [hasArtifacts] is false (button is hidden in that case).
  final VoidCallback? onToggleArtifacts;

  const _ActionStack({
    required this.expanded,
    required this.hasArtifacts,
    required this.chevronDuration,
    required this.onStudio,
    required this.onToggleArtifacts,
  });

  @override
  Widget build(BuildContext context) {
    // Negative margin extends the stack's vertical hit area into the
    // card padding so each ~36pt visible button reaches the 44pt HIG
    // minimum. Mirrors the mockup's `margin: -8px -6px -8px 0`.
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Studio button — always visible. Pencil + chevron-right
          // (forward navigation).
          _ActionButton(
            tooltip: 'Open in Studio',
            icon: Icons.edit_outlined,
            // U+203A — single right-pointing angle quotation mark.
            arrowGlyph: '›',
            arrowRotation: 0.0,
            arrowRotationDuration: chevronDuration,
            onTap: () {
              HapticFeedback.selectionClick();
              onStudio();
            },
          ),
          if (hasArtifacts) ...[
            const SizedBox(height: 4),
            // Artifacts button — toggles expanded. Stacked-cards glyph
            // + chevron-down that rotates 180° on .expanded.
            _ActionButton(
              tooltip: expanded ? 'Hide published artifacts' : 'Show published artifacts',
              icon: _stackedCardsIcon,
              // U+25BE — black down-pointing small triangle.
              arrowGlyph: '▾',
              arrowRotation: expanded ? 1.0 : 0.0,
              arrowRotationDuration: chevronDuration,
              onTap: () {
                HapticFeedback.selectionClick();
                onToggleArtifacts!();
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Material icon used for the Artifacts button. `layers` is closest to
/// the mockup's overlapping-rounded-rect "stacked cards" SVG without
/// shipping a custom icon font.
const IconData _stackedCardsIcon = Icons.layers_outlined;

/// One coral pill-shaped action button — icon on the left, directional
/// arrow glyph on the right. Coral tinted bg + border, coral fg. Hover
/// brightens the background; active scales to 0.96.
class _ActionButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final String arrowGlyph;
  // 0.0 = no rotation; 1.0 = 180° rotation. Tweened over
  // [arrowRotationDuration]. Used for the down-chevron flip on the
  // Artifacts button; the Studio button always passes 0.0.
  final double arrowRotation;
  final Duration arrowRotationDuration;
  final VoidCallback onTap;

  const _ActionButton({
    required this.tooltip,
    required this.icon,
    required this.arrowGlyph,
    required this.arrowRotation,
    required this.arrowRotationDuration,
    required this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scale = _pressed ? 0.96 : 1.0;
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: Material(
          color: AppColors.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            // GestureDetector + Material InkWell consume the tap before
            // it bubbles to the SessionCard's outer InkWell (which would
            // navigate to Studio). The stopPropagation behaviour comes
            // for free from Flutter's gesture arena.
            onTap: widget.onTap,
            onHighlightChanged: (h) {
              if (mounted) setState(() => _pressed = h);
            },
            splashColor: AppColors.primary.withValues(alpha: 0.22),
            highlightColor: AppColors.primary.withValues(alpha: 0.18),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.45),
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.icon,
                    size: 16,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 5),
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0.0, end: widget.arrowRotation),
                    duration: widget.arrowRotationDuration,
                    curve: _kSnappySpring,
                    builder: (context, t, _) {
                      return Transform.rotate(
                        // 0 -> pi rotates the down-arrow to up.
                        angle: t * 3.14159265,
                        child: Text(
                          widget.arrowGlyph,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            height: 1.0,
                            color: AppColors.primary,
                          ),
                        ),
                      );
                    },
                  ),
                ],
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
    // The artifact stack lives in a Stack with two zones:
    //   - The rail sits in the 13dp gutter at x=0..3 (10dp visible gap
    //     + 3dp rail width).
    //   - The cards live to the right of the rail, inset by the gutter.
    // We clip the stack's overflow so the per-card "deal of cards" slide
    // (cards starting positioned above their final resting place) is
    // clipped behind the session card until they land.
    return Padding(
      // Pad-top: 10px breathing room from the session card.
      // Pad-bottom: 4px so the expanded stack doesn't run flush into
      //              the next session card.
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // z=0 — coral rail. scaleY 0 -> 1 from top, with a slight
            // initial delay so siblings push down before the rail draws.
            // Sits in the 10dp gutter at x=0; cards are inset to the
            // right via _kArtifactInnerLeftPad so the rail is never
            // obscured.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _RailAnimator(
                reduceMotion: reduceMotion,
              ),
            ),
            // z=1 — vertical artifact card list with per-card stagger.
            // Inset from the left by [_kArtifactInnerLeftPad] (13dp =
            // 10dp gutter + 3dp rail width) per the 2026-05-27 iteration.
            Padding(
              padding: const EdgeInsets.only(left: _kArtifactInnerLeftPad),
              child: Column(
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
            ),
          ],
        ),
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

  /// Per-card starting offset multiplier (fraction of card height).
  /// Card 0 = -1.8, card 1 = -2.8, card 2 = -3.8, card 3+ = -4.8.
  /// Mirrors the mockup's deeper-cards-travel-farther rule.
  double get _startOffsetFraction {
    final clamped = widget.index.clamp(0, _kCardDepthOffsets.length - 1);
    return _kCardDepthOffsets[clamped];
  }

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
      // Stagger: 80ms + 140ms * index. Use Future.delayed to gate the
      // forward call so cards land sequentially with the deal-of-cards
      // rhythm.
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
        // Deal-of-cards spring — heavier overshoot so the long travel
        // reads as a "shuffle" landing rather than a snap.
        final eased = _kDealSpring.transform(_controller.value);
        // Start from -180% / -280% / -380% / -480% (depth-proportional
        // fraction of card height), settle to 0.
        final startOffsetPx = _startOffsetFraction * _kCardHeightForDepth;
        final dy = startOffsetPx * (1 - eased);
        return Opacity(
          // Opacity ramp ends a bit before the full settle so the card
          // is fully visible during the latter half of the landing.
          opacity: eased.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, dy),
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
          // Cards now sit inset 10dp from the session card's left edge
          // with the rail in the gutter behind them; the card's own
          // left padding drops back to a normal value (rail is no
          // longer obscured by card chrome).
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
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

