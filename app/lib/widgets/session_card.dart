import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/exercise_capture.dart';
import '../models/session.dart';
import '../services/conversion_service.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import 'conversion_error_log_sheet.dart';

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

  const SessionCard({
    super.key,
    required this.session,
    required this.isPublishing,
    required this.onOpen,
    required this.onDelete,
    this.onRenamed,
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
        child: InkWell(
          // Wave 38 — when the title is in edit mode, the surrounding
          // card body must NOT navigate; the keyboard tap-outside flow
          // hands focus elsewhere first, but a stray tap still
          // inadvertently popped the user into Studio. Block onTap in
          // edit mode; the editable title's TapRegion handles
          // tap-outside to commit.
          onTap: _editing ? null : widget.onOpen,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                _LeadingIconBadge(
                  icon: Icons.list_alt_rounded,
                  count: exerciseCount,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTitle(session),
                      const SizedBox(height: 2),
                      Text(
                        SessionCard._publishLabel(session),
                        style: TextStyle(
                          color: session.version > 0
                              ? AppColors.circuit
                              : AppColors.textSecondaryOnDark,
                          fontSize: 13,
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
                    ],
                  ),
                ),
                // Wave 18 — Publish + Share icons moved to the Studio
                // toolbar. The card now ends with the chevron only so
                // the row reads as a pure navigation affordance.
                const Icon(
                  Icons.chevron_right,
                  color: AppColors.grey500,
                  size: 22,
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
            : AppColors.textSecondaryOnDark;
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.14),
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
      child: Material(
        color: AppColors.primary.withValues(alpha: 0.14),
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

/// Small coral-tinted icon badge sat at the leading edge of session
/// (and client) cards. Colour token + treatment is centralised here
/// so both surfaces stay in lock-step visually.
///
/// Coral at 12% alpha background on the dark surface + a coral-filled
/// glyph. Wave 34 bumps the size +50% (40×40 → 60×60, icon 22 → 33,
/// radius 10 → 14) so the leading icon reads as a confident anchor on
/// the card row vs the previous chip-sized footprint. Client-card
/// leading icon (in `home_screen.dart`) was bumped in lock-step.
///
/// Wave 32: when [count] > 0, an exercise-count badge overlays the
/// bottom-right corner — like an app-icon notification badge. White
/// digits on solid coral with a 1px dark border so it pops against
/// both the icon and the card surface. Hidden when [count] == 0
/// (pre-capture sessions).
///
/// Wave 34: count badge shrunk ~15% (16×16 → 14×14, font 10 → 9 single,
/// 8 → 7 multi-digit) — but device QA found the smaller badge looked
/// anemic against the +50% leading icon.
///
/// Wave 36: reverse direction — bump 14×14 → 21×21 (+50%), fonts 9/7 →
/// 13/10. Anchor offset relaxed so the larger badge still feels
/// pinned to the bottom-right corner rather than floating off it.
class _LeadingIconBadge extends StatelessWidget {
  final IconData icon;
  final int count;
  const _LeadingIconBadge({required this.icon, this.count = 0});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      height: 60,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: AppColors.primary, size: 33),
          ),
          if (count > 0)
            // Wave 36 — at 21×21 the badge body is meatier, so we sit it
            // about a third outside the icon footprint (rather than
            // hugging the corner). Tested: single-digit + 2-digit + "99+"
            // all read as confidently anchored accents against the icon.
            Positioned(
              right: -5,
              bottom: -5,
              child: _CountBadge(count: count),
            ),
        ],
      ),
    );
  }
}

/// Coral count pill — circular, white digits, 1px dark border.
/// Triple-digit counts widen to a stadium so "99+" still reads.
///
/// Wave 33: digits shrink at 2+ characters so the count fits without
/// truncating inside the badge footprint. Carl flagged 10+ were running
/// off the badge — dropping the font at width ≥ 2 chars solves that
/// without changing the iconography.
///
/// Wave 34: badge geometry shrunk ~15% (16 → 14, fonts 10/8 → 9/7) —
/// QA found the result anemic next to the +50% leading icon.
///
/// Wave 36: reverse direction. 14 → 21 (+50%), fonts 9/7 → 13/10. Pad
/// for "99+" widened in lock-step so the stadium still hugs the glyphs.
class _CountBadge extends StatelessWidget {
  final int count;
  const _CountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    final isMultiDigit = label.length >= 2;
    return Container(
      constraints: const BoxConstraints(minWidth: 21, minHeight: 21),
      padding: EdgeInsets.symmetric(
        // "99+" gets enough horizontal pad that the glyphs don't kiss
        // the dark border — three glyphs at 9pt need a bit of room.
        // Two-digit fits inside 21px once the font drops to 9pt — no
        // extra pad needed.
        horizontal: count > 99 ? 4 : 0,
        vertical: 0,
      ),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.surfaceBg, width: 1),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Inter',
          color: Colors.white,
          // Wave 37 — −10% from W36's 13/10. Single-digit 13 → 12,
          // two-digit 10 → 9. Container size stays 21×21; the smaller
          // glyph reads as a confident accent without crowding the
          // pill border.
          fontSize: isMultiDigit ? 9 : 12,
          fontWeight: FontWeight.w700,
          height: 1.0,
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
