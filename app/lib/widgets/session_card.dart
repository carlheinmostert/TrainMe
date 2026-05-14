import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../models/treatment.dart';
import '../services/api_client.dart' show PlanAnalyticsSummary;
import '../services/conversion_service.dart';
import '../services/exercise_hero_resolver.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../utils/hero_crop_alignment.dart';
import 'conversion_error_log_sheet.dart';

/// Maximum number of filmstrip cells. Carl signed off N=4 — beyond that
/// each cell shrinks below ~80px on iPhone widths and the heroes become
/// unreadable noise.
const int _kFilmstripMaxCells = 4;

/// Hero pick rule (audit F17, 2026-05-13): take the first N video
/// exercises in session order; if zero videos, take up to N photos
/// (was: first photo only, which was the F17 bug). If zero photos
/// either, return empty (caller paints the coral-tinted dark surface
/// that's the card's existing default).
///
/// Mixing — videos take precedence whole; photos only fill cells
/// when there are NO videos in the session (documented mixed-treatment
/// aesthetic: B&W videos OR line photos, never side-by-side).
List<ExerciseCapture> _pickFilmstripHeroes(Session session) {
  final videos = <ExerciseCapture>[];
  for (final ex in session.exercises) {
    if (ex.isRest) continue;
    if (ex.mediaType == MediaType.video) {
      videos.add(ex);
      if (videos.length >= _kFilmstripMaxCells) break;
    }
  }
  if (videos.isNotEmpty) return videos;
  // No videos — fall back to up to N photos (audit F17 fix; was
  // clamped to a single photo by design pre-2026-05-13).
  final photos = <ExerciseCapture>[];
  for (final ex in session.exercises) {
    if (ex.isRest) continue;
    if (ex.mediaType == MediaType.photo) {
      photos.add(ex);
      if (photos.length >= _kFilmstripMaxCells) break;
    }
  }
  return photos;
}

/// Visual session card — one row in a client's session list.
///
/// Tap (anywhere except the editable title) opens the session.
/// Swipe-left soft-deletes via the parent's [onDelete]. Wave 38 adds
/// inline rename: tapping the title cell drops into a TextField with
/// autofocus; Enter (or tap-outside) commits the new name through
/// `SyncService.queueRenameSession` (offline-safe). The badge, lock
/// row, and rest of the card body stay tappable as nav targets.
///
/// Wave 32 layout:
///   [icon+badge]  Title (date) ← dashed underline = editable          ›
///                 v3 · 25 Apr               ← status row
///                 ● Free Edits · 11d 4h left ← lock row (Wave 33 copy)
///                 [coral pill: 2 converting...]   ← active only
///                 [coral pill: N failed]          ← active only
///
/// Failed-conversion retry pill stays — it's a per-exercise concern,
/// not a publish concern, and the parent list is the natural surface.
class SessionCard extends StatefulWidget {
  final Session session;

  /// Kept for legacy wiring + future reinstatement (a ClientSessionsScreen
  /// refresh may still care whether a parallel publish is running on
  /// this session — e.g. to grey out the row). Not currently rendered
  /// as a spinner on the card itself.
  final bool isPublishing;

  final VoidCallback onOpen;
  final VoidCallback onDelete;

  /// Optional notifier for the parent list — the inline rename writes
  /// through `SyncService.queueRenameSession` directly, but the parent
  /// may want to refresh its in-memory list to show the new title
  /// without the next pull-to-refresh.
  final ValueChanged<Session>? onRenamed;

  /// Wave 17 analytics — "Opened N× · X/Y completed · last X" stats.
  /// Pre-Wave-43 this rendered OUTSIDE the card from the parent screen;
  /// 2026-05-04 brings it INSIDE the card boundary so the filmstrip
  /// background frames the whole row. Null while still loading or for
  /// unpublished sessions; the renderer handles both states.
  final PlanAnalyticsSummary? analyticsSummary;

  const SessionCard({
    super.key,
    required this.session,
    required this.isPublishing,
    required this.onOpen,
    required this.onDelete,
    this.onRenamed,
    this.analyticsSummary,
  });

  @override
  State<SessionCard> createState() => _SessionCardState();

  /// Lock-grace window MUST mirror `StudioModeScreen._kLockGraceDays`
  /// (Wave 32 = 14 days). Duplicated here as a const so the card can
  /// derive its lock-state row without importing the screen.
  static const Duration _kLockGrace = Duration(days: 14);

  /// Inside the last [_kUrgentWindow] of grace the lock row paints
  /// coral. Inside the last [_kWarningWindow] it paints amber. Otherwise
  /// sage. Matches the colour grammar Carl spec'd in the brief.
  static const Duration _kUrgentWindow = Duration(hours: 24);
  static const Duration _kWarningWindow = Duration(days: 3);

  /// Display title for the card row.
  ///
  /// Prefers [Session.title] when set (new flow: "Jan Smith · 19 Apr 2026
  /// 17:09"). Falls back to [Session.clientName] so legacy sessions still
  /// read as the date-stamp they were minted with.
  static String _cardTitle(Session session) {
    final t = session.title;
    if (t != null && t.trim().isNotEmpty) return t;
    return session.clientName;
  }

  /// Short publish-status label for the session card. Wave 32 dropped
  /// the "{N} exercises" prefix — that count now lives on the leading
  /// icon's overlaid badge.
  static String _publishLabel(Session session) {
    if (session.version == 0) return 'Draft';
    final v = 'v${session.version}';
    final dt = session.lastPublishedAt;
    if (dt == null) return v;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final date = '${dt.day} ${months[dt.month - 1]}';
    return '$v \u00b7 $date';
  }

  /// Resolve the lock-state row to render — null if the row should be
  /// hidden (draft + never-opened states; only pre-locked / locked /
  /// unlocked surface a row).
  ///
  /// Mirrors `StudioModeScreen._isPlanLocked` rules (Wave 32) so the
  /// list view + the screen agree.
  static _LockState? _resolveLockState(Session session) {
    if (!session.isPublished) return null; // draft: hide
    final firstOpened = session.firstOpenedAt;
    if (firstOpened == null) return null; // published-never-opened: hide
    if (session.unlockCreditPrepaidAt != null) {
      return const _LockState(_LockTone.unlocked, 'Unlocked · republish free');
    }
    final elapsed = DateTime.now().difference(firstOpened);
    final remaining = _kLockGrace - elapsed;
    if (remaining <= Duration.zero) {
      return const _LockState(
        _LockTone.locked,
        'Republish costs 1 credit · tap to unlock',
      );
    }
    final tone = remaining <= _kUrgentWindow
        ? _LockTone.urgent
        : remaining <= _kWarningWindow
            ? _LockTone.warning
            : _LockTone.fresh;
    return _LockState(tone, 'Free Edits · ${_formatRemaining(remaining)} left');
  }

  /// Compact "Xd Yh" / "Xh Ym" / "Xm" formatter for [Duration]. Drops
  /// the trailing unit when it's 0 (e.g. exactly 24h → "1d", exactly
  /// 1h → "1h"). Sub-minute clamps to "1m" so the row never renders
  /// "0m left" — inside that final minute the lock effectively flips,
  /// and "1m left" reads as imminent rather than already-expired.
  static String _formatRemaining(Duration d) {
    if (d.inDays >= 1) {
      final days = d.inDays;
      final hours = d.inHours - days * 24;
      return hours == 0 ? '${days}d' : '${days}d ${hours}h';
    }
    if (d.inHours >= 1) {
      final hours = d.inHours;
      final minutes = d.inMinutes - hours * 60;
      return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
    }
    final minutes = d.inMinutes;
    return minutes <= 0 ? '1m' : '${minutes}m';
  }
}

class _SessionCardState extends State<SessionCard> {
  bool _editing = false;
  bool _saving = false;
  late TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: SessionCard._cardTitle(widget.session));
  }

  @override
  void didUpdateWidget(covariant SessionCard old) {
    super.didUpdateWidget(old);
    // If the underlying session title changes via a remote refresh
    // while we're not editing, re-seed the controller so the next
    // edit starts from the newest value.
    if (!_editing && old.session.title != widget.session.title) {
      _controller.text = SessionCard._cardTitle(widget.session);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _enterEdit() {
    HapticFeedback.selectionClick();
    setState(() {
      _editing = true;
      _controller.text = SessionCard._cardTitle(widget.session);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  Future<void> _commit() async {
    if (_saving) return;
    final trimmed = _controller.text.trim();
    final current = SessionCard._cardTitle(widget.session);
    if (trimmed.isEmpty || trimmed == current) {
      // Empty or unchanged — drop edit mode without firing the RPC.
      setState(() {
        _editing = false;
        _controller.text = current;
      });
      return;
    }
    setState(() => _saving = true);
    try {
      final ok = await SyncService.instance.queueRenameSession(
        planId: widget.session.id,
        newTitle: trimmed,
      );
      if (!mounted) return;
      if (!ok) {
        _showError("Couldn't rename — try again.");
        setState(() {
          _saving = false;
          _editing = false;
          _controller.text = current;
        });
        return;
      }
      // Optimistic — local SQLite already has the new title; let the
      // parent know so its in-memory list refreshes without a roundtrip.
      widget.onRenamed?.call(
        widget.session.copyWith(title: trimmed),
      );
      setState(() {
        _saving = false;
        _editing = false;
      });
    } catch (e) {
      if (!mounted) return;
      _showError("Couldn't rename — try again.");
      setState(() {
        _saving = false;
        _editing = false;
        _controller.text = current;
      });
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final exerciseCount = session.exercises.length;
    final pending = session.pendingConversions;

    final failedConversions = session.exercises
        .where((e) => e.conversionStatus == ConversionStatus.failed)
        .toList(growable: false);
    final hasFailedConversions = failedConversions.isNotEmpty;

    final lockState = SessionCard._resolveLockState(session);

    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      // Wave 38 — disable swipe-to-delete while inline-renaming so a
      // sloppy swipe on the keyboard area doesn't soft-delete the row
      // out from under the practitioner.
      confirmDismiss: (_) async => !_editing,
      onDismissed: (_) => widget.onDelete(),
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.error,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 28),
      ),
      child: Card(
        elevation: 0,
        color: AppColors.surfaceBase,
        margin: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // Wave 38 — when the title is in edit mode, the surrounding
          // card body must NOT navigate; the keyboard tap-outside flow
          // hands focus elsewhere first, but a stray tap still
          // inadvertently popped the user into Studio. Block onTap in
          // edit mode; the editable title's TapRegion handles
          // tap-outside to commit.
          onTap: _editing ? null : widget.onOpen,
          // Filmstrip stack — z=0 heroes, z=1 coral-tinted dark gradient,
          // z=2 existing card content. ConstrainedBox enforces the +30%
          // minimum height (was ~80px effective, now ~104px). The
          // filmstrip Stack layers everything; ListView.builder windowing
          // keeps off-screen cards out of memory and Image.file's
          // cacheWidth caps decode size per cell.
          child: ConstrainedBox(
            // Wave 41 (this PR): card minimum height bumped +30% from
            // the previous effective ~80px (60×60 leading icon + 10px
            // top/bottom padding) to 104px so the filmstrip background
            // has room to read as a deliberate hero, not a chrome trim.
            // Carl explicitly capped at +30% (the mockup proposed +50%).
            constraints: const BoxConstraints(minHeight: 104),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                // z=0 — filmstrip hero cells (or default surface if no media).
                Positioned.fill(
                  child: _SessionFilmstripBackground(session: session),
                ),
                // z=1 — uniform 30% dark veil across every cell. Carl
                // 2026-05-04: the original 0.92→0.55→0.30 left-to-right
                // gradient over-darkened the leftmost cells; user
                // explicitly asked for "all pics at 30%". Text
                // legibility now leans on the per-element shadows on
                // title/subtitle/analytics + the backdrop-blurred pills.
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Color(0x4D0F1117), // rgba(15,17,23,0.30)
                    ),
                  ),
                ),
                // z=2 — existing card content (icon, title, status pills,
                // chevron). Title + subtitle pick up text-shadows so they
                // stay legible across light filmstrip cells.
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      _LeadingCountGlyph(count: exerciseCount),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTitle(session),
                            const SizedBox(height: 2),
                            Text(
                              SessionCard._publishLabel(session),
                              style: TextStyle(
                                color: session.version > 0
                                    ? AppColors.circuit
                                    : AppColors.textOnDark,
                                fontSize: 13,
                                shadows: const [
                                  Shadow(
                                    color: Color(0x99000000),
                                    blurRadius: 4,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                            ),
                            if (lockState != null) ...[
                              const SizedBox(height: 4),
                              _LockStateRow(state: lockState),
                            ],
                            if (pending > 0) ...[
                              const SizedBox(height: 6),
                              _PendingConversionsPill(count: pending),
                            ],
                            if (hasFailedConversions) ...[
                              const SizedBox(height: 6),
                              _FailedConversionsPill(
                                failed: failedConversions,
                              ),
                            ],
                            // Wave 17 analytics — Opened N× · X/Y completed · last X.
                            // Lives INSIDE the card boundary as of 2026-05-04 so
                            // the filmstrip background frames the whole row
                            // (Carl: "below each card we currently have stats,
                            // this should be inside the card boundary").
                            if (widget.session.isPublished) ...[
                              const SizedBox(height: 6),
                              _AnalyticsLine(
                                session: widget.session,
                                summary: widget.analyticsSummary,
                              ),
                            ],
                          ],
                        ),
                      ),
                      // Wave 18 — Publish + Share icons moved to the
                      // Studio toolbar. The card now ends with the
                      // chevron only so the row reads as a pure
                      // navigation affordance.
                      const Icon(
                        Icons.chevron_right,
                        color: AppColors.grey500,
                        size: 22,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(Session session) {
    if (!_editing) {
      // Rest state: dashed underline signalling editability. Tap fires
      // _enterEdit. The GestureDetector is its own hit zone so the
      // surrounding card's onTap (which navigates) doesn't compete.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _enterEdit,
        child: CustomPaint(
          painter: _DashedUnderlinePainter(
            color: AppColors.textSecondaryOnDark,
          ),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              SessionCard._cardTitle(session),
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textOnDark,
                // Filmstrip background can include light cell content.
                // 4px blurred black shadow keeps the title readable
                // even when the right-side gradient stop is only 30%
                // dark.
                shadows: [
                  Shadow(
                    color: Color(0x99000000),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ),
      );
    }

    // Edit mode: TextField with autofocus. Solid coral underline
    // surfaces via the InputDecoration's focused border.
    return Opacity(
      opacity: _saving ? 0.6 : 1.0,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        enabled: !_saving,
        maxLength: 120,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _commit(),
        // tap-outside: auto-commit. Cheaper than persisting "Cancel"
        // chrome on every card row.
        onTapOutside: (_) {
          if (_focusNode.hasFocus) {
            _focusNode.unfocus();
            // Defer to the next frame so the focus event lands first.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _editing && !_saving) _commit();
            });
          }
        },
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
          fontSize: 14,
        ),
        cursorColor: AppColors.primary,
        decoration: const InputDecoration(
          counterText: '',
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 4, horizontal: 0),
          border: UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.primary, width: 1.4),
          ),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.primary, width: 1.4),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.primary, width: 1.4),
          ),
        ),
      ),
    );
  }
}

/// Lock-row tone — drives the leading dot colour + (occasionally) the
/// label colour. Five distinct visual states; none of them open a
/// separate tap surface — the whole card row is the tap target and
/// opens the Studio, which is where the unlock CTA lives.
enum _LockTone { fresh, warning, urgent, locked, unlocked }

class _LockState {
  final _LockTone tone;
  final String label;
  const _LockState(this.tone, this.label);
}

/// Single row showing the publish-lock state. Tiny (8×8) coloured
/// circle + 12pt label. Visual-only; tap target is the whole card.
class _LockStateRow extends StatelessWidget {
  final _LockState state;
  const _LockStateRow({required this.state});

  @override
  Widget build(BuildContext context) {
    final dotColor = _toneColor(state.tone);
    // Locked + unlocked nudge the label colour too — locked reads as
    // "do something", unlocked reads as "you already did".
    final labelColor = state.tone == _LockTone.locked
        ? AppColors.error
        : state.tone == _LockTone.unlocked
            ? AppColors.primary
            : AppColors.textOnDark;
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            state.label,
            style: TextStyle(
              color: labelColor,
              fontSize: 12,
              fontWeight: state.tone == _LockTone.locked
                  ? FontWeight.w600
                  : FontWeight.w400,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  static Color _toneColor(_LockTone tone) {
    switch (tone) {
      case _LockTone.fresh:
        return AppColors.rest; // sage
      case _LockTone.warning:
        return AppColors.warning; // amber
      case _LockTone.urgent:
        return AppColors.primary; // coral
      case _LockTone.locked:
        return AppColors.error; // red
      case _LockTone.unlocked:
        return AppColors.primaryLight; // light coral
    }
  }
}

/// Thin coral-tinted "N converting..." pill. Wave 32 promoted this out
/// of the status-row text so the lock row can read cleanly without
/// pending-conversion noise pushing the publish version off the line.
class _PendingConversionsPill extends StatelessWidget {
  final int count;
  const _PendingConversionsPill({required this.count});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          // Wave 41 — backdrop blur so the pill stays legible on top of
          // the filmstrip hero behind it.
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.primary),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$count converting...',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Coral-tinted retry pill. Extracted unchanged from the retired Home
/// screen impl so the visual language of "N failed" stays consistent.
class _FailedConversionsPill extends StatelessWidget {
  final List<ExerciseCapture> failed;

  const _FailedConversionsPill({required this.failed});

  @override
  Widget build(BuildContext context) {
    final count = failed.length;
    return Align(
      alignment: Alignment.centerLeft,
      child: ClipRRect(
        // Wave 41 — backdrop blur so the retry pill stays legible
        // against any filmstrip cell content sat behind it.
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Material(
            color: AppColors.primary.withValues(alpha: 0.22),
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => _retry(context, failed),
              onLongPress: () {
                HapticFeedback.selectionClick();
                ConversionErrorLogSheet.show(context);
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.refresh_rounded,
                      size: 14,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$count failed',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
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

  Future<void> _retry(
    BuildContext context,
    List<ExerciseCapture> failed,
  ) async {
    HapticFeedback.selectionClick();
    for (final ex in failed) {
      unawaited(ConversionService.instance.retry(ex));
    }
    if (!context.mounted) return;
    final count = failed.length;
    final plural = count == 1 ? 'exercise' : 'exercises';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Retrying $count $plural',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              color: AppColors.textOnDark,
            ),
          ),
          backgroundColor: AppColors.surfaceRaised,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.surfaceBorder),
          ),
        ),
      );
  }
}

/// Floating exercise-count glyph at the leading edge of the session
/// card. Replaces the prior coral-tinted icon-box+badge composite
/// (`_LeadingIconBadge` + `_CountBadge`) — now that PR #220's filmstrip
/// background carries the visual context of "what's in this session",
/// the icon is redundant and the count carries the data on its own.
///
/// Renders as a large coral mono-numeric digit cluster with a strong
/// drop-shadow so it stays legible against any filmstrip cell. No
/// enclosing shape — pure glyph, anchored by typography alone.
///
/// Footprint stays 60px wide so existing horizontal layout (title +
/// subtitle column to the right) doesn't shift. `FittedBox` auto-fits
/// the label inside the 60×60 footprint so 1-, 2-, and 3-char counts
/// ("5", "12", "99+") all fill the slot cleanly without manual tiers.
class _LeadingCountGlyph extends StatelessWidget {
  final int count;
  const _LeadingCountGlyph({required this.count});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) {
      // Pre-capture sessions show nothing in the leading slot.
      return const SizedBox(width: 60, height: 60);
    }
    final label = count > 99 ? '99+' : '$count';
    return SizedBox(
      width: 60,
      height: 60,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 42,
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
              height: 1.0,
              letterSpacing: -1.5,
              fontFeatures: [FontFeature.tabularFigures()],
              shadows: [
                Shadow(
                  color: Color(0xCC000000),
                  blurRadius: 6,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints a dashed underline below the child. Mirrors the dashed
/// underline used on the editable client name in the per-client header
/// (`client_sessions_screen.dart`) so the rename affordance reads as
/// the same family across surfaces.
class _DashedUnderlinePainter extends CustomPainter {
  final Color color;

  const _DashedUnderlinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    const dashWidth = 4.0;
    const dashGap = 3.0;
    double x = 0;
    final y = size.height - 0.5;
    while (x < size.width) {
      final end = (x + dashWidth).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x += dashWidth + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedUnderlinePainter old) =>
      old.color != color;
}

/// Filmstrip hero background for the session card.
///
/// Renders up to [_kFilmstripMaxCells] cells horizontally, each showing
/// a single Hero frame in B&W (matches existing card thumbnails — Carl
/// signed off Option B as POPIA-friendly). Cells flex equally, so 1
/// video → 1 cell at 100%, 2 videos → 2 at 50%, 3 → 3 at 33%, 4 → 4 at
/// 25%. If the session has zero videos but at least one photo, up to
/// [_kFilmstripMaxCells] photo cells render the line-drawing thumbnails
/// (audit F17 fix — pre-2026-05-13 the photo path clamped to a single
/// cell). Rest-only sessions (zero videos AND zero photos) render the
/// default coral-tinted dark surface (mock spec: fall back to current
/// chrome).
///
/// Static — no carousel / crossfade. Animation question (#3) was
/// closed at "static" because filmstrip rotation in a list view fights
/// scroll perception and burns CPU on long client lists.
///
/// Performance:
///   - Each cell uses [Image.file] with `cacheWidth` scaled to the
///     cell's rendered width (240 → 720 px depending on cell count).
///     The original flat 240 px ceiling was sized for a 4-cell strip
///     and read soft on single-photo / single-video sessions where the
///     cell stretches across the whole card. 2026-05-13 round 2 fix.
///   - The card itself lives inside a `ListView.builder`; Flutter's
///     lazy build keeps off-screen filmstrips out of memory.
///   - Cloud-only state (raw mp4 not yet on disk after a fresh
///     install): the cell's `errorBuilder` falls back to the same
///     coral-tinted dark fill — never a broken-image glyph.
class _SessionFilmstripBackground extends StatelessWidget {
  final Session session;
  const _SessionFilmstripBackground({required this.session});

  @override
  Widget build(BuildContext context) {
    final heroes = _pickFilmstripHeroes(session);
    if (heroes.isEmpty) {
      // Rest-only session (or any session with no media) — keep the
      // default surface colour. Coral-tinted dark surface IS the card's
      // existing default (`AppColors.surfaceBase` + 1px border on the
      // outer Card). We render a transparent placeholder so the gradient
      // overlay continues to read against `surfaceBase` underneath.
      return const SizedBox.shrink();
    }
    // Decode width scales with cell count — the original `cacheWidth:
    // 240` was sized for a 4-cell strip (~97px wide on iPhone-class
    // widths). On a 1-cell or 2-cell layout the cell stretches across
    // the full card, and a 240px-wide decode reads soft (4.8× upscale
    // on a 375px iPhone for a single photo).
    //
    // 2026-05-13 round 2 — fix the soft single-photo filmstrip case
    // surfaced by Carl's QA. Math:
    //   1 cell  → 720px decode (covers retina 3x on 375px width plus a
    //             little headroom for iPad / wide iPhone displays)
    //   2 cells → 480px decode
    //   3 cells → 320px decode
    //   4 cells → 240px decode (legacy baseline)
    // Memory is still bounded — long client lists scroll lazily and
    // off-screen cards drop their image cache.
    final cells = heroes.length;
    final cacheWidthPerCell = cells <= 1
        ? 720
        : cells == 2
            ? 480
            : cells == 3
                ? 320
                : 240;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < heroes.length; i++) ...[
          Expanded(
            child: _FilmstripCell(
              exercise: heroes[i],
              cacheWidth: cacheWidthPerCell,
            ),
          ),
          // Hairline 1px black separator between adjacent cells (per
          // mockup CSS). Skipped after the last cell.
          if (i < heroes.length - 1)
            const SizedBox(
              width: 1,
              child: ColoredBox(color: Colors.black),
            ),
        ],
      ],
    );
  }
}

/// A single filmstrip cell — one video Hero frame (B&W) or one photo
/// line drawing.
///
/// Resolution routes through [resolveExerciseHero] with
/// [HeroSurface.filmstrip]:
///   - Videos render the cached B&W thumbnail (already greyscale on
///     disk) and the resolver returns [kHeroGrayscaleFilter] so the
///     filmstrip always reads as B&W regardless of the exercise's
///     `preferredTreatment`. Documented mixed-treatment aesthetic.
///   - Photos render the line-drawing JPG (the converted file is
///     already greyscale-friendly line art, and a raw photo path
///     isn't guaranteed to be on disk after a cloud-only sync). The
///     resolver does not apply a filter for the photo line path.
class _FilmstripCell extends StatelessWidget {
  final ExerciseCapture exercise;
  final int cacheWidth;
  const _FilmstripCell({required this.exercise, required this.cacheWidth});

  @override
  Widget build(BuildContext context) {
    // Filmstrip always asks for the LINE treatment so the photo path
    // resolves to the line-drawing JPG (which is always on disk after
    // capture). The resolver enforces the B&W ColorFilter on videos
    // regardless of treatment for the filmstrip surface, so videos
    // still read as B&W — see resolver `HeroSurface.filmstrip` rules.
    final hero = resolveExerciseHero(
      exercise: exercise,
      surface: HeroSurface.filmstrip,
    );
    final file = hero.posterFile;
    if (file == null) {
      return const SizedBox.expand(
        child: ColoredBox(color: AppColors.surfaceBase),
      );
    }
    // Wave Lobby — apply the per-exercise practitioner-authored 1:1
    // crop window. The filmstrip cell is non-square (card height ×
    // card-width / N), but BoxFit.cover + alignment still slides the
    // visible window along the source's free axis (X for landscape, Y
    // for portrait). Defaults to centred for legacy / un-authored
    // exercises so prior renders stay pixel-stable.
    final align = heroCropAlignment(exercise);
    Widget image = Image.file(
      file,
      fit: BoxFit.cover,
      alignment: align,
      // Decode width scales with the actual cell width — see parent
      // (_SessionFilmstripBackground.build) for the per-cell-count math.
      // Single-cell strips upgrade to 720px so a full-width photo on a
      // 375px iPhone (3x → 1125px logical, but Flutter's image cache
      // works in DIPs so 720 px is the right knob) doesn't decode-soft.
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => const ColoredBox(
        color: AppColors.surfaceBase,
      ),
    );
    final filter = hero.filter;
    if (filter != null) {
      image = ColorFiltered(colorFilter: filter, child: image);
    }
    return SizedBox.expand(child: image);
  }
}

/// Wave 17 analytics line — "Opened N× · X/Y completed · last X".
///
/// Moved INSIDE SessionCard 2026-05-04. Same formatting + relative-time
/// helper as the retired `_PlanAnalyticsRow` in client_sessions_screen.dart;
/// rendering inside the card lets the filmstrip background frame the row
/// instead of breaking visually below it. Empty-summary ("—") and
/// non-zero-opens variants are both supported.
class _AnalyticsLine extends StatelessWidget {
  final Session session;
  final PlanAnalyticsSummary? summary;

  const _AnalyticsLine({required this.session, this.summary});

  @override
  Widget build(BuildContext context) {
    final text = _format();
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 11,
        color: AppColors.textOnDark,
        shadows: [
          Shadow(color: Color(0x99000000), blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _format() {
    if (summary == null || summary!.opens == 0) return '—';
    final s = summary!;
    final totalExercises =
        session.exercises.where((e) => !e.isRest).length;
    final completionLabel = totalExercises > 0
        ? '${s.completions}/$totalExercises completed'
        : '${s.completions} completed';
    final lastLabel = s.lastOpenedAt != null
        ? _formatRelativeTime(s.lastOpenedAt!)
        : '';
    final parts = <String>[
      'Opened ${s.opens}×',
      completionLabel,
      if (lastLabel.isNotEmpty) 'last $lastLabel',
    ];
    return parts.join(' · ');
  }

  static String _formatRelativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    return '${(diff.inDays / 30).floor()}mo ago';
  }
}
