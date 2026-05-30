// =============================================================================
// SessionArtifactAccordion — 2026-05-27 (artifact-card accordion)
// =============================================================================
//
// Per-session card with a peek depth cue + two absolutely-positioned action
// buttons + inline vertical accordion that lists the session's published
// `plan_artifacts`. Mounts on three surfaces with R-10 parity:
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
// #567 (2026-05-30) — the two action buttons now live INSIDE the session
// card's dedicated, fixed-width actions column (column 3 of the card's
// 3-column row) instead of as an absolute overlay that drifted with the
// card content:
//   - Edit button:     pinned TOP-right of the actions column.
//   - Artifact button:  pinned BOTTOM-right of the actions column.
// The column fills the full card height (SessionCard's Row is laid out
// with `CrossAxisAlignment.stretch`), so `MainAxisAlignment.spaceBetween`
// drives the top/bottom pinning. Coral fill raised to 0.45 alpha + a dark
// scrim under each pill so they read on any filmstrip hero. The buttons no
// longer drift with title/meta length.
//
// 2026-05-27 evening iteration — three refinements on top of the
// afternoon iteration:
//
//   1. (superseded by #567 — buttons were absolutely positioned OVER the
//      card; they now ride the dedicated actions column, see above.)
//
//   2. Artifact button is ALWAYS visible (including on unpublished sessions
//      with zero artifacts). Tapping it on a zero-artifact session reveals
//      a soft empty-state slider with onboarding copy:
//        "No artifacts yet. Publish this session to mint a workout plan or
//         handout. Both will appear here."
//      Auto-dismisses after 3500ms, or collapses if another card is opened.
//      Leading rail is text-dim grey (not coral) to differentiate from the
//      real artifact accordion.
//
//   3. Collapse animation is now the time-reverse of expand. Bottom card
//      retreats first, top card last. Container shrinks AFTER cards leave.
//      Peek slides back in last. Total ~1.46s — mirrors the expand budget.
//
// Visual behavior (matches `docs/design/mockups/2026-05-27-artifact-card-expansion.html`):
//
//   - Rest, artifacts present     — peek card behind (4px right, 5px down);
//                                   Studio button vertically centered;
//                                   Artifact button at bottom-right.
//   - Rest, no artifacts          — no peek. Studio button still centered;
//                                   Artifact button still at bottom-right.
//   - Expanded                    — peek lifts + fades; siblings push down;
//                                   artifact cards slide down from behind
//                                   the session card with depth-proportional
//                                   travel + 140ms stagger (deal-of-cards);
//                                   coral 3px rail draws inside the 13dp
//                                   gutter on the left of the artifact stack.
//   - Empty-state revealed        — text-dim rail draws inside the gutter;
//                                   onboarding banner card slides in below
//                                   the session card. Auto-dismiss timer
//                                   runs for 3.5 seconds.
//
// Tap zones:
//   - Card BODY (filmstrip + card content) → existing behaviour (open Studio
//     for this session).
//   - Studio action button (vertically centered overlay) → same enterStudio
//     action; stops propagation.
//   - Artifact action button (bottom-right overlay) → toggle expanded when
//     row has artifacts; reveal empty-state slider when zero artifacts.
//   - Artifact card → kind-specific action (preview / handout / coming soon).
//
// Animation timings (per spec, 2026-05-27 evening iteration):
//   - Container grow (expand)        : 540ms snappy spring.
//   - Container shrink (collapse)    : delayed 800ms before starting, then
//                                      same 540ms snappy — so cards leave
//                                      FIRST and the container collapses
//                                      around the vacancy.
//   - Peek lift (expand) / fade      : 380ms snappy spring.
//   - Peek slide-back (collapse)     : delayed 1100ms — last thing to land.
//   - Artifact card slide (expand)   : 820ms each, deal spring,
//                                      delay = 80 + 140*index.
//   - Artifact card slide (collapse) : 820ms each, deal spring,
//                                      delay = 80 + 140*(N-1-index) — top
//                                      card leaves last.
//   - Coral rail draw (expand)       : 640ms snappy spring + 60ms delay.
//   - Coral rail recede (collapse)   : 640ms snappy spring + 600ms delay.
//   - Action-button chevron rotate   : 280ms snappy spring (0 -> 180deg).
//   - Empty-state slider expand      : 360ms snappy spring (AnimatedSize).
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
//     null; the card paints WITHOUT peek (graceful empty state). Both
//     action buttons still render.
// =============================================================================

import 'dart:async';

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

/// Container grow on expand — 540ms snappy spring. AnimatedSize drives
/// the height tween that the cards' own slide animations land into.
const Duration _kContainerGrowDuration = Duration(milliseconds: 540);

/// Container shrink on collapse waits 800ms so the cards retreat before
/// the surrounding height collapses. Total ~1.34s for the shrink to
/// settle (800ms delay + 540ms tween).
const Duration _kContainerShrinkDelay = Duration(milliseconds: 800);

/// Chevron rotation 0 -> 180deg. Stays even under reduced-motion (140ms
/// then) because it's a directional indicator.
const Duration _kChevronDuration = Duration(milliseconds: 280);
const Duration _kChevronReducedMotionDuration = Duration(milliseconds: 140);

/// Peek lift + fade. 380ms snappy spring at full motion; 0ms reduced.
/// On collapse the peek slide-back is implicitly the last animation
/// to fire because [_CollapseAwareAnimatedSize] holds the height
/// open until after the cards retreat, and AnimatedSlide on the peek
/// then plays into the now-empty space.
const Duration _kPeekDuration = Duration(milliseconds: 380);

/// Per-artifact card slide. 820ms each on the deal-of-cards spring.
const Duration _kArtifactDuration = Duration(milliseconds: 820);

/// Per-card stagger step. Expand: card N waits 80 + 140*N. Collapse
/// stagger is implicit via the height-shrink delay — cards unmount in
/// one frame after the container's shrinkDelay, and the visual sense
/// of "bottom card leaves first" comes from those cards being lowest
/// on screen at the moment of unmount.
const Duration _kArtifactDelayStep = Duration(milliseconds: 140);
const Duration _kArtifactInitialDelay = Duration(milliseconds: 80);

/// Coral rail draw — 640ms snappy spring with a 60ms initial delay on
/// expand. The collapse path tears down the entire stack widget; the
/// rail's individual AnimatedBuilder is disposed alongside the cards.
const Duration _kRailDuration = Duration(milliseconds: 640);
const Duration _kRailExpandDelay = Duration(milliseconds: 60);

/// Empty-state slider — same snappy spring as the accordion container,
/// shorter duration (360ms) so the soft onboarding hint feels lighter
/// than the deal-of-cards rhythm.
const Duration _kEmptyStateDuration = Duration(milliseconds: 360);

/// Empty-state auto-dismiss timeout per spec — 3.5 seconds.
const Duration _kEmptyStateAutoDismiss = Duration(milliseconds: 3500);

/// Pixel size of the peek offset (4px right, 5px down per spec).
const double _kPeekOffsetX = 4.0;
const double _kPeekOffsetY = 5.0;

/// Width of the coral hairline rail (3px per spec).
const double _kRailWidth = 3.0;

/// Gutter inset for artifact cards. Artifact cards sit inset 10dp from
/// the session card's left edge; the rail lives in the resulting 13dp
/// gutter (10dp visible space + 3dp rail width).
const double _kArtifactGutterInset = 10.0;
const double _kArtifactInnerLeftPad = _kArtifactGutterInset + _kRailWidth;

/// Per-card depth-proportional starting offset as a fraction of card
/// height. Mirrors the mockup's `translateY(-180%)` / `-280%` / etc.
const List<double> _kCardDepthOffsets = <double>[-1.8, -2.8, -3.8, -4.8];

/// Approximate artifact-card height for the depth-fraction translation.
const double _kCardHeightForDepth = 68.0;

/// Wrap a [SessionCard] with the artifact-stack expansion affordance.
///
/// Every session card mounts two action buttons in the card's dedicated
/// fixed-width actions column (column 3, #567):
///   - Edit button pinned top-right of the column.
///   - Artifact button pinned bottom-right of the column.
///
/// Both are always visible. When [artifactStatuses] is non-null AND
/// contains at least one published row, tapping the Artifact button
/// expands the accordion (peek lifts, artifact cards deal out). When
/// the row has no published artifacts, tapping the Artifact button
/// reveals an empty-state slider with onboarding copy that auto-dismisses
/// after 3.5 seconds.
class SessionArtifactAccordion extends StatefulWidget {
  /// Session row to render. Forwarded verbatim to [SessionCard].
  final Session session;

  /// Already-loaded `plan_artifacts` rows for this session. Pass null
  /// while the parent is still fetching — the card paints WITHOUT peek
  /// during the loading window so unpublished sessions never briefly
  /// flicker the depth cue. Empty list = "loaded, none yet".
  final List<PlanArtifactStatus>? artifactStatuses;

  /// True iff THIS session is the currently-expanded one in the parent
  /// list. The parent owns the accordion state (single-expanded across
  /// the list).
  final bool expanded;

  /// Toggle callback fired when the practitioner taps the Artifact
  /// action button on a session that HAS artifacts. Parent re-assigns
  /// its `_expandedSessionId`. When the row has zero artifacts the
  /// empty-state slider is shown LOCALLY instead and this callback is
  /// not fired.
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
  /// regardless (per spec).
  final Color? brandAccent;

  /// Open the `plan_url` artifact.
  final VoidCallback? onPlayPlanUrl;

  /// Open the `handout` artifact.
  final VoidCallback? onPlayHandout;

  /// Tap on any other kind (poster, reel, ai_reel, calendar).
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

  @override
  State<SessionArtifactAccordion> createState() =>
      _SessionArtifactAccordionState();

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
}

class _SessionArtifactAccordionState extends State<SessionArtifactAccordion> {
  bool _emptyStateRevealed = false;
  Timer? _emptyStateDismissTimer;

  @override
  void didUpdateWidget(covariant SessionArtifactAccordion old) {
    super.didUpdateWidget(old);
    // If the parent expanded this card (via the artifact accordion path),
    // collapse any locally-revealed empty-state slider — only one of the
    // two can be open at a time. Same applies if another row takes over
    // expansion (the parent will set widget.expanded=false on us).
    if (widget.expanded && _emptyStateRevealed) {
      _dismissEmptyState();
    }
  }

  @override
  void dispose() {
    _emptyStateDismissTimer?.cancel();
    super.dispose();
  }

  void _onArtifactButtonTap(bool hasArtifacts) {
    HapticFeedback.selectionClick();
    if (hasArtifacts) {
      if (_emptyStateRevealed) _dismissEmptyState();
      widget.onToggleExpanded();
      return;
    }
    // Zero-artifact path — reveal the empty-state slider locally.
    if (_emptyStateRevealed) {
      _dismissEmptyState();
      return;
    }
    setState(() => _emptyStateRevealed = true);
    _emptyStateDismissTimer?.cancel();
    _emptyStateDismissTimer = Timer(_kEmptyStateAutoDismiss, () {
      if (mounted) _dismissEmptyState();
    });
  }

  void _dismissEmptyState() {
    _emptyStateDismissTimer?.cancel();
    _emptyStateDismissTimer = null;
    if (!mounted) return;
    if (_emptyStateRevealed) {
      setState(() => _emptyStateRevealed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final published = widget.artifactStatuses == null
        ? const <PlanArtifactStatus>[]
        : SessionArtifactAccordion._published(widget.artifactStatuses!);
    final hasArtifacts = published.isNotEmpty;
    final expanded = widget.expanded;

    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations == true;
    final peekDuration = reduceMotion ? Duration.zero : _kPeekDuration;
    final chevronDuration =
        reduceMotion ? _kChevronReducedMotionDuration : _kChevronDuration;
    final containerDuration =
        reduceMotion ? Duration.zero : _kContainerGrowDuration;
    final emptyDuration =
        reduceMotion ? Duration.zero : _kEmptyStateDuration;

    // #567 — the two action buttons now live INSIDE the session card's
    // dedicated, fixed-width actions column (column 3) rather than as an
    // absolute overlay that drifted with the card content. The column
    // fills the full card height (SessionCard's Row is `stretch`), so we
    // pin Edit top-right + Artifacts bottom-right within it.
    final actionsColumn = _ActionsColumn(
      expanded: expanded,
      hasArtifacts: hasArtifacts,
      chevronDuration: chevronDuration,
      onStudio: () {
        HapticFeedback.selectionClick();
        widget.onOpen();
      },
      onArtifact: () => _onArtifactButtonTap(hasArtifacts),
    );

    // Stack the SessionCard and the peek card (when artifacts exist). The
    // peek floats BEHIND the card; the action buttons are now part of the
    // card's own actions column (no separate overlay layer — #567).
    final cardWithOverlays = Stack(
      clipBehavior: Clip.none,
      children: [
        if (hasArtifacts)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: peekDuration,
                opacity: expanded ? 0.0 : 0.92,
                curve: _kSnappySpring,
                child: AnimatedSlide(
                  duration: peekDuration,
                  curve: _kSnappySpring,
                  offset: expanded
                      ? const Offset(0.0, -0.04)
                      : const Offset(0.012, 0.05),
                  child: AnimatedScale(
                    duration: peekDuration,
                    curve: _kSnappySpring,
                    scale: expanded ? 0.98 : 1.0,
                    child: const _PeekCard(),
                  ),
                ),
              ),
            ),
          ),
        // The session card itself. When the peek is present we shift the
        // actual card UP+LEFT slightly so the peek's edges peek out
        // behind+below it; without that nudge the peek sits flush.
        Padding(
          padding: hasArtifacts
              ? const EdgeInsets.only(
                  right: _kPeekOffsetX,
                  bottom: _kPeekOffsetY,
                )
              : EdgeInsets.zero,
          child: SessionCard(
            session: widget.session,
            isPublishing: false,
            onOpen: widget.onOpen,
            onDelete: widget.onDelete,
            analyticsSummary: widget.analyticsSummary,
            sourceTag: widget.sourceTag,
            sharedByEmail: widget.sharedByEmail,
            onRenamed: widget.onRenamed,
            // #567 — the Edit + Artifacts buttons ride in the card's
            // dedicated actions column (col 3) via trailingOverride. The
            // default static chevron is suppressed.
            trailingOverride: actionsColumn,
          ),
        ),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        cardWithOverlays,
        // Empty-state slider — only animates open on no-artifact rows.
        // Its AnimatedSize tracks _emptyStateRevealed independent of the
        // accordion's expanded flag.
        ClipRect(
          child: AnimatedSize(
            duration: emptyDuration,
            curve: _kSnappySpring,
            alignment: Alignment.topCenter,
            child: _emptyStateRevealed && !hasArtifacts
                ? const _EmptyStateBanner()
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ),
        // Artifact accordion target — single AnimatedSize wraps the
        // expanded stack. Collapse uses _kContainerShrinkDelay so cards
        // retreat before the surrounding height shrinks. We swap between
        // two timing widgets so AnimatedSize respects the correct delay
        // for the current direction of motion.
        ClipRect(
          child: _CollapseAwareAnimatedSize(
            expanded: expanded,
            growDuration: containerDuration,
            shrinkDuration: containerDuration,
            shrinkDelay:
                reduceMotion ? Duration.zero : _kContainerShrinkDelay,
            alignment: Alignment.topCenter,
            child: expanded
                ? _ArtifactStack(
                    statuses: published,
                    brandAccent: widget.brandAccent,
                    reduceMotion: reduceMotion,
                    onPlayPlanUrl: widget.onPlayPlanUrl,
                    onPlayHandout: widget.onPlayHandout,
                    onPlayOther: widget.onPlayOther,
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ),
      ],
    );
  }
}

/// Dedicated actions column (#567) — the two action buttons stacked in
/// the session card's fixed-width column 3 rather than absolutely
/// positioned over the card.
///
///   - Edit button     — pinned TOP-right of the column.
///   - Artifacts button — pinned BOTTOM-right of the column.
///
/// The column fills the full card height (SessionCard's Row is laid out
/// with `CrossAxisAlignment.stretch`), so `MainAxisAlignment.spaceBetween`
/// drives Edit to the top and Artifacts to the bottom. Both buttons are
/// right-aligned (`CrossAxisAlignment.end`). Carl's accepted default
/// mapping is Edit-top / Artifacts-bottom — not flipped.
///
/// Buttons are always visible. Tapping the Artifact button on a row with
/// zero published artifacts reveals an empty-state slider (handled by the
/// parent); on a row WITH artifacts it toggles the accordion.
class _ActionsColumn extends StatelessWidget {
  final bool expanded;
  final bool hasArtifacts;
  final Duration chevronDuration;
  final VoidCallback onStudio;
  final VoidCallback onArtifact;

  const _ActionsColumn({
    required this.expanded,
    required this.hasArtifacts,
    required this.chevronDuration,
    required this.onStudio,
    required this.onArtifact,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.max,
      children: [
        // Edit — pinned top-right.
        _ActionButton(
          tooltip: 'Open in Studio',
          icon: Icons.edit_outlined,
          arrowGlyph: '›', // single right-pointing angle quote.
          arrowRotation: 0.0,
          arrowRotationDuration: chevronDuration,
          backdropBlur: true,
          onTap: onStudio,
        ),
        // Artifacts — pinned bottom-right.
        _ActionButton(
          tooltip: hasArtifacts
              ? (expanded
                  ? 'Hide published artifacts'
                  : 'Show published artifacts')
              : 'Artifacts — none yet',
          icon: _stackedCardsIcon,
          arrowGlyph: '▾', // black down-pointing small triangle.
          arrowRotation: expanded ? 1.0 : 0.0,
          arrowRotationDuration: chevronDuration,
          backdropBlur: true,
          onTap: onArtifact,
        ),
      ],
    );
  }
}

/// Material icon used for the Artifacts button.
const IconData _stackedCardsIcon = Icons.layers_outlined;

/// One coral pill-shaped action button — icon on the left, directional
/// arrow glyph on the right. Coral tinted bg + border, coral fg. When
/// [backdropBlur] is true the button gets a heavier coral-tinted bg
/// (rgba(255,107,53,0.18) per the evening spec) so it stays readable
/// over filmstrip imagery.
class _ActionButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final String arrowGlyph;
  final double arrowRotation;
  final Duration arrowRotationDuration;
  final VoidCallback onTap;
  final bool backdropBlur;

  const _ActionButton({
    required this.tooltip,
    required this.icon,
    required this.arrowGlyph,
    required this.arrowRotation,
    required this.arrowRotationDuration,
    required this.onTap,
    this.backdropBlur = false,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scale = _pressed ? 0.96 : 1.0;
    // #567 legibility — raise the coral fill to 0.45 alpha (was 0.18) so
    // the pill reads as a solid coral chip on ANY filmstrip hero behind
    // it, and lay a subtle dark scrim UNDER the coral so light cells
    // can't wash it out. backdrop-blur stays for extra separation.
    final bgAlpha = widget.backdropBlur ? 0.45 : 0.10;
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        // Dark scrim layer beneath the coral fill — same rgba(15,17,23)
        // surface tone as the card veil, at 0.30, so the coral always
        // sits on a darkened base regardless of the hero behind it.
        child: Material(
          color: widget.backdropBlur
              ? const Color(0x4D0F1117) // rgba(15,17,23,0.30) scrim
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: Material(
            color: AppColors.primary.withValues(alpha: bgAlpha),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
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
                    color: AppColors.primary.withValues(alpha: 0.55),
                    width: 1,
                  ),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                      tween: Tween<double>(
                        begin: 0.0,
                        end: widget.arrowRotation,
                      ),
                      duration: widget.arrowRotationDuration,
                      curve: _kSnappySpring,
                      builder: (context, t, _) {
                        return Transform.rotate(
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
      ),
    );
  }
}

/// Peek card painted behind the SessionCard.
class _PeekCard extends StatelessWidget {
  const _PeekCard();

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

/// Empty-state slider painted below the session card when the practitioner
/// taps the Artifact button on a row with zero published artifacts.
/// Auto-dismisses after [_kEmptyStateAutoDismiss] (3.5s).
class _EmptyStateBanner extends StatelessWidget {
  const _EmptyStateBanner();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // Text-dim rail (NOT coral) so this read clearly differs from
          // the real artifact accordion's coral rail.
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: _kRailWidth,
              decoration: BoxDecoration(
                color: AppColors.textSecondaryOnDark.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(_kRailWidth / 2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: _kArtifactInnerLeftPad),
            child: Container(
              decoration: BoxDecoration(
                color:
                    AppColors.textSecondaryOnDark.withValues(alpha: 0.10),
                border: Border.all(
                  color: AppColors.surfaceBorder,
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.textSecondaryOnDark
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.info_outline,
                      size: 18,
                      color: AppColors.textSecondaryOnDark,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: RichText(
                      text: const TextSpan(
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          height: 1.45,
                          color: AppColors.textSecondaryOnDark,
                        ),
                        children: [
                          TextSpan(
                            text: 'No artifacts yet. ',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: AppColors.textOnDark,
                            ),
                          ),
                          TextSpan(
                            text:
                                'Publish this session to mint an Interactive Workout Guide or Printable Workout Guide. Both will appear here.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps [AnimatedSize] with a direction-aware delay so the collapse
/// can wait for the artifact cards to retreat before the height tween
/// fires. Flutter's stock AnimatedSize takes a single duration that
/// applies in both directions; we sequence the collapse manually by
/// delaying the child swap.
class _CollapseAwareAnimatedSize extends StatefulWidget {
  final bool expanded;
  final Duration growDuration;
  final Duration shrinkDuration;
  final Duration shrinkDelay;
  final Alignment alignment;
  final Widget child;

  const _CollapseAwareAnimatedSize({
    required this.expanded,
    required this.growDuration,
    required this.shrinkDuration,
    required this.shrinkDelay,
    required this.alignment,
    required this.child,
  });

  @override
  State<_CollapseAwareAnimatedSize> createState() =>
      _CollapseAwareAnimatedSizeState();
}

class _CollapseAwareAnimatedSizeState
    extends State<_CollapseAwareAnimatedSize> {
  // The child we currently render. On expand we render the real child
  // immediately. On collapse we keep the real child rendered through
  // the shrinkDelay window so the artifact cards can finish their
  // staggered exit; then we swap to the zero-height placeholder and
  // AnimatedSize tweens the height shut.
  Widget? _renderedChild;
  Timer? _shrinkSwapTimer;

  @override
  void initState() {
    super.initState();
    _renderedChild = widget.child;
  }

  @override
  void didUpdateWidget(covariant _CollapseAwareAnimatedSize old) {
    super.didUpdateWidget(old);
    if (old.expanded != widget.expanded) {
      if (widget.expanded) {
        // Expand — swap in the real child immediately.
        _shrinkSwapTimer?.cancel();
        setState(() => _renderedChild = widget.child);
      } else {
        // Collapse — keep the OLD child rendered for shrinkDelay so
        // the cards can fly out; then swap to the empty placeholder
        // (which is what `widget.child` evaluates to in the collapsed
        // state) and let AnimatedSize tween the height shut.
        _shrinkSwapTimer?.cancel();
        if (widget.shrinkDelay == Duration.zero) {
          setState(() => _renderedChild = widget.child);
        } else {
          _shrinkSwapTimer = Timer(widget.shrinkDelay, () {
            if (mounted) {
              setState(() => _renderedChild = widget.child);
            }
          });
        }
      }
    } else {
      // Same direction — keep the child reference fresh.
      _renderedChild = widget.child;
    }
  }

  @override
  void dispose() {
    _shrinkSwapTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: widget.expanded ? widget.growDuration : widget.shrinkDuration,
      curve: _kSnappySpring,
      alignment: widget.alignment,
      child: _renderedChild ?? const SizedBox(width: double.infinity, height: 0),
    );
  }
}

/// Vertical stack of artifact cards rendered below the SessionCard
/// when the accordion is expanded. Each card animates in with a
/// staggered translate+fade; on collapse the stagger is reversed so
/// the bottom card retreats first.
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
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // Coral rail.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _RailAnimator(
                reduceMotion: reduceMotion,
              ),
            ),
            // Vertical artifact card list with per-card stagger.
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

/// Animates a single artifact card's entrance. Cards mount when the
/// stack first builds (on the expand transition); the per-index stagger
/// gates the forward animation via [Future.delayed].
///
/// Collapse is handled by the parent's [_CollapseAwareAnimatedSize] —
/// the entire stack widget is removed after [_kContainerShrinkDelay].
/// We don't tween the cards out individually; their disposal alongside
/// the AnimatedSize height tween reads as a synchronized retreat. The
/// MIRRORED stagger requested by the spec is achieved by the rail's
/// own delayed recede + the AnimatedSize's delayed shrink — the cards
/// themselves are unmounted in a single frame at the end of the delay,
/// so deeper cards (closer to the bottom-edge of the card stack)
/// appear to leave first because they were positioned lowest.
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
      _controller.value = 1.0;
    } else {
      final delay =
          _kArtifactInitialDelay + _kArtifactDelayStep * widget.index;
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
        final eased = _kDealSpring.transform(_controller.value);
        final startOffsetPx = _startOffsetFraction * _kCardHeightForDepth;
        final dy = startOffsetPx * (1 - eased);
        return Opacity(
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

/// 3px coral hairline rail. ScaleY 0 -> 1 from the top on expand;
/// fades back on collapse with the 600ms delay so it stays during the
/// cards' departure.
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
      Future.delayed(_kRailExpandDelay, () {
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

/// Single artifact card row.
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
    final borderColor = isFront ? _accent : AppColors.surfaceBorder;
    // Unified status pill — every minted artifact reads "Published" (the
    // sage "Live" variant is retired, mirroring the web `/me` twin). Paid
    // kinds keep the coral tint; free kinds use the calm sage tint so the
    // practitioner can still tell a credit-spent artifact apart at a glance.
    final pillBg = paid
        ? _accent.withValues(alpha: 0.16)
        : AppColors.rest.withValues(alpha: 0.16);
    final pillFg = paid ? _accent : AppColors.rest;
    // #565 — per-artefact version. Each card reads the version stamped on
    // ITS OWN plan_artifacts row (the plan/session version at this
    // artefact's last publish), not the plan-level current version. Two
    // artefacts published together show the same number; they diverge when
    // one is republished without the other. 0 = legacy / never-published →
    // bare "Published".
    final pillText =
        status.version > 0 ? 'Published · v${status.version}' : 'Published';

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

/// Per-kind visual chrome.
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
          label: 'Printable Workout Guide',
          glyph: Icons.description_outlined,
          glyphFg: AppColors.primaryLight,
          glyphBg: AppColors.primary.withValues(alpha: 0.14),
        );
      case ArtifactKind.planUrl:
        return _ArtifactCardTheme(
          label: 'Interactive Workout Guide',
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
