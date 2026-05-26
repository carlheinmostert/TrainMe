// =============================================================================
// ArtifactStatusRow — Wave 3 (artifact-system, 2026-05-26)
// =============================================================================
//
// Compact glyph + state pill row that sits under the Studio AppBar's
// session title, summarising which artifact kinds have been published on
// this plan. Reads "Handout · live · Player · published · Reel · not yet"
// in a single line of compact chips.
//
// Mockup: docs/design/mockups/2026-05-26-studio-status-bits.html (Section 1)
//
// State semantics (matches Wave 3 ADR 0027 + ADR 0028):
//
//   * Live (sage)        — minted-and-fresh. Reserved for FREE kinds (any
//                          kind with credits_charged == 0). Edits flow
//                          through automatically; no lock pressure.
//   * Published (coral)  — paid-and-minted. Coral signals "credit was
//                          spent". This state arms the edit-lock the
//                          moment the client first opens any paid artifact
//                          (see Section 2 of the mockup — the chip /
//                          countdown lives in the AppBar, not here).
//   * Not yet (muted)    — never-published. Dashed muted border, kind
//                          glyph at 70% opacity. "Available but unspent"
//                          — no negative tone.
//
// V3 the pills are non-tappable (read-only status). A future wave will
// open the Publish gate scoped to that kind on tap.
// =============================================================================

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// One pill in the row. Backed by a [PlanArtifactStatus] when the kind
/// has a `plan_artifacts` row, or a "not yet" placeholder otherwise.
@immutable
class _BitData {
  final String kind;
  final String label;
  final IconData glyph;
  final _BitState state;

  const _BitData({
    required this.kind,
    required this.label,
    required this.glyph,
    required this.state,
  });
}

enum _BitState { live, published, notYet }

class ArtifactStatusRow extends StatelessWidget {
  /// The plan's current `plan_artifacts` rows. Drives which kinds render
  /// as Live / Published, and which kinds are "not yet" (no row).
  final List<PlanArtifactStatus> statuses;

  /// Kinds to always show even when they have no `plan_artifacts` row
  /// yet. For Wave 3, the default is `[plan_url, handout]` — the two
  /// shippable kinds. Showing them in the "not yet" state for fresh
  /// sessions sets the practitioner's expectation that publishing is
  /// the next move. Future kinds (reel) join this set when they ship.
  ///
  /// Kinds in [statuses] but NOT in this set are silently dropped from
  /// the row — keeps forward-compat with a future server that ships a
  /// kind this mobile build doesn't know yet.
  final List<String> alwaysVisibleKinds;

  const ArtifactStatusRow({
    super.key,
    required this.statuses,
    this.alwaysVisibleKinds = const [
      ArtifactKind.handout,
      ArtifactKind.planUrl,
    ],
  });

  IconData _glyphFor(String kind) {
    switch (kind) {
      case ArtifactKind.handout:
        return Icons.description_outlined;
      case ArtifactKind.planUrl:
        return Icons.play_arrow_rounded;
      case ArtifactKind.poster:
        return Icons.image_outlined;
      case ArtifactKind.reel:
        return Icons.grid_view_rounded;
      case ArtifactKind.aiReel:
        return Icons.auto_awesome;
      case ArtifactKind.calendar:
        return Icons.event_outlined;
      default:
        return Icons.help_outline;
    }
  }

  String _shortLabelFor(String kind) {
    // Use the short, scannable form for the pill. The full label
    // ("Workout handout") lives in the Publish gate; the status row
    // optimises for compact reading at a glance.
    switch (kind) {
      case ArtifactKind.handout:
        return 'Handout';
      case ArtifactKind.planUrl:
        return 'Player';
      case ArtifactKind.poster:
        return 'Poster';
      case ArtifactKind.reel:
        return 'Reel';
      case ArtifactKind.aiReel:
        return 'AI Reel';
      case ArtifactKind.calendar:
        return 'Calendar';
      default:
        return kind;
    }
  }

  String _stateLabel(_BitState s) {
    switch (s) {
      case _BitState.live:
        return 'live';
      case _BitState.published:
        return 'published';
      case _BitState.notYet:
        return 'not yet';
    }
  }

  List<_BitData> _buildBits() {
    // Index existing statuses by kind for O(1) lookup.
    final byKind = <String, PlanArtifactStatus>{};
    for (final s in statuses) {
      if (s.isPublished) byKind[s.kind] = s;
    }

    // Build the bit list in the order of `alwaysVisibleKinds`. Append
    // any unexpected kinds (kinds in `statuses` that aren't in the
    // visible set) at the end so a forward-compat server can surface
    // them without a client release — but a Wave-3 client only knows
    // about handout + plan_url so this branch is effectively dead
    // until a new kind ships.
    final order = <String>[];
    for (final k in alwaysVisibleKinds) {
      order.add(k);
    }
    for (final s in statuses) {
      if (!order.contains(s.kind) && ArtifactKindRegistry.specFor(s.kind) != null) {
        order.add(s.kind);
      }
    }

    final out = <_BitData>[];
    for (final kind in order) {
      final spec = ArtifactKindRegistry.specFor(kind);
      if (spec == null) continue; // unknown to this client; skip
      final status = byKind[kind];
      _BitState state;
      if (status == null) {
        state = _BitState.notYet;
      } else if (status.wasPaid) {
        state = _BitState.published;
      } else {
        state = _BitState.live;
      }
      out.add(
        _BitData(
          kind: kind,
          label: _shortLabelFor(kind),
          glyph: _glyphFor(kind),
          state: state,
        ),
      );
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final bits = _buildBits();
    if (bits.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [for (final b in bits) _Bit(data: b, stateLabel: _stateLabel(b.state))],
      ),
    );
  }
}

class _Bit extends StatelessWidget {
  final _BitData data;
  final String stateLabel;

  const _Bit({required this.data, required this.stateLabel});

  Color _backgroundColor() {
    switch (data.state) {
      case _BitState.live:
        return AppColors.rest.withValues(alpha: 0.08);
      case _BitState.published:
        return AppColors.primary.withValues(alpha: 0.12);
      case _BitState.notYet:
        return AppColors.surfaceBg;
    }
  }

  Color _borderColor() {
    switch (data.state) {
      case _BitState.live:
        return AppColors.rest.withValues(alpha: 0.28);
      case _BitState.published:
        return AppColors.primary.withValues(alpha: 0.3);
      case _BitState.notYet:
        return AppColors.surfaceBorder;
    }
  }

  Color _glyphColor() {
    switch (data.state) {
      case _BitState.live:
        return AppColors.rest;
      case _BitState.published:
        return AppColors.primaryLight;
      case _BitState.notYet:
        return AppColors.textSecondaryOnDark.withValues(alpha: 0.7);
    }
  }

  Color _textColor() {
    switch (data.state) {
      case _BitState.live:
        return AppColors.rest;
      case _BitState.published:
        return AppColors.primaryLight;
      case _BitState.notYet:
        return AppColors.textSecondaryOnDark.withValues(alpha: 0.7);
    }
  }

  IconData _stateGlyph() {
    switch (data.state) {
      case _BitState.live:
      case _BitState.published:
        return Icons.check;
      case _BitState.notYet:
        return Icons.remove;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dashed = data.state == _BitState.notYet;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 11, 5),
      decoration: dashed
          ? _dashedDecoration(borderColor: _borderColor())
          : BoxDecoration(
              color: _backgroundColor(),
              border: Border.all(color: _borderColor(), width: 1),
              borderRadius: BorderRadius.circular(999),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(data.glyph, size: 14, color: _glyphColor()),
          const SizedBox(width: 6),
          Text(
            '${data.label} · $stateLabel',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontWeight: FontWeight.w600,
              fontSize: 10.5,
              color: _textColor(),
              letterSpacing: 0.15,
            ),
          ),
          if (data.state != _BitState.notYet) ...[
            const SizedBox(width: 4),
            Icon(_stateGlyph(), size: 10, color: _textColor()),
          ],
        ],
      ),
    );
  }

  /// A dashed-border pill via [ShapeDecoration] with a [_DashedRoundedBorder].
  /// Flutter's default `Border.all` doesn't support dashed strokes; we paint
  /// our own via a [CustomPainter] under [Container] when needed.
  ShapeDecoration _dashedDecoration({required Color borderColor}) {
    return ShapeDecoration(
      color: _backgroundColor(),
      shape: _DashedRoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        color: borderColor,
        dashWidth: 3,
        gapWidth: 3,
        strokeWidth: 1,
      ),
    );
  }
}

/// Dashed variant of [RoundedRectangleBorder]. Used for the "not yet"
/// status pill per the mockup's `border-style: dashed`. Flutter's
/// built-in Border doesn't support dashed strokes, so we draw the
/// border via a custom paint pass.
class _DashedRoundedRectangleBorder extends OutlinedBorder {
  final BorderRadius borderRadius;
  final Color color;
  final double dashWidth;
  final double gapWidth;
  final double strokeWidth;

  const _DashedRoundedRectangleBorder({
    required this.borderRadius,
    required this.color,
    required this.dashWidth,
    required this.gapWidth,
    required this.strokeWidth,
  }) : super(side: BorderSide.none);

  @override
  ShapeBorder scale(double t) => _DashedRoundedRectangleBorder(
        borderRadius: borderRadius * t,
        color: color,
        dashWidth: dashWidth * t,
        gapWidth: gapWidth * t,
        strokeWidth: strokeWidth * t,
      );

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..addRRect(borderRadius.resolve(textDirection).toRRect(rect.deflate(strokeWidth)));
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..addRRect(borderRadius.resolve(textDirection).toRRect(rect));
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(strokeWidth);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final rrect = borderRadius.resolve(textDirection).toRRect(rect.deflate(strokeWidth / 2));
    final path = Path()..addRRect(rrect);
    final metrics = path.computeMetrics().toList();
    for (final m in metrics) {
      var dist = 0.0;
      while (dist < m.length) {
        final end = (dist + dashWidth).clamp(0.0, m.length);
        canvas.drawPath(m.extractPath(dist, end), paint);
        dist = end + gapWidth;
      }
    }
  }

  @override
  _DashedRoundedRectangleBorder copyWith({
    BorderSide? side,
    BorderRadius? borderRadius,
    Color? color,
    double? dashWidth,
    double? gapWidth,
    double? strokeWidth,
  }) {
    return _DashedRoundedRectangleBorder(
      borderRadius: borderRadius ?? this.borderRadius,
      color: color ?? this.color,
      dashWidth: dashWidth ?? this.dashWidth,
      gapWidth: gapWidth ?? this.gapWidth,
      strokeWidth: strokeWidth ?? this.strokeWidth,
    );
  }
}
