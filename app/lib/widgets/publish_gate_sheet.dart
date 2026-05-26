// =============================================================================
// PublishGateSheet — Wave 3 (artifact-system, 2026-05-26)
// =============================================================================
//
// Multi-select publish checklist. Replaces the legacy "Publish single
// plan_url" button-to-RPC flow with a checklist of every registered
// artifact kind, each showing its price (free / 1-2 credits / TBD) and
// state (Available / Live / Soon). The footer carries a balance line, a
// big coral running total, and a CTA that states exactly what it'll do
// ("Publish 2 artifacts · 1 credit").
//
// Mockup: docs/design/mockups/2026-05-26-publish-gate.html
// Locked decisions: nothing pre-checked (#5); Live rows are no-op on
// re-tick — never re-charged (#6); registry-future kinds render as Soon.
//
// Reader-App safe: the only money-words here are "credit" / "credits".
// No PayFast, no Stripe, no purchase paths.
// =============================================================================

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// Result returned by [PublishGateSheet.show] when the practitioner taps
/// the CTA. Null means they backed out (dismissed the sheet with no
/// publish intent).
class PublishGateResult {
  /// Kinds the practitioner checked (excludes Live rows that were
  /// already published — re-ticking those is a no-op per locked #6).
  final List<String> kinds;

  /// Total credits this publish will burn. Sum of per-kind paid prices
  /// (free kinds contribute 0). Already-Live kinds contribute 0 (never
  /// re-charged).
  final int credits;

  const PublishGateResult({required this.kinds, required this.credits});
}

/// Per-row state machine for the gate. Wire-side state strings are the
/// same as the mockup callouts ("Available", "Live", "Soon").
enum _RowState { availableUnchecked, availableChecked, live, soon }

class PublishGateSheet extends StatefulWidget {
  /// Currently-published artifact statuses on this plan. Drives which
  /// rows render as `Live` (sage). Empty for never-published plans.
  final List<PlanArtifactStatus> existing;

  /// Server-previewed cost for the paid path (0, 1, or 2). Same value
  /// the workflow pill shows; mirrored here so the balance line reads
  /// "Plan ≤ 75 min · 1 credit" without re-fetching the preview.
  ///
  /// 0 here means self-trainer all-verified — the workout player is
  /// effectively free for this practitioner. The gate still surfaces
  /// it as a "Paid" tier row but the running total shows 0 credits.
  final int? planUrlCreditCost;

  /// Practice's current credit balance. Drives the balance line above
  /// the total. Null while the read is in-flight; the sheet renders
  /// "—" in that frame.
  final int? creditBalance;

  const PublishGateSheet({
    super.key,
    required this.existing,
    required this.planUrlCreditCost,
    required this.creditBalance,
  });

  /// Open the gate as a bottom sheet. Resolves to a [PublishGateResult]
  /// when the practitioner taps the CTA, or null when they back out.
  /// The detent is ~85% per the existing settings-sheet convention so
  /// the legend + footer never compete with the iOS keyboard.
  static Future<PublishGateResult?> show(
    BuildContext context, {
    required List<PlanArtifactStatus> existing,
    required int? planUrlCreditCost,
    required int? creditBalance,
  }) {
    return showModalBottomSheet<PublishGateResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceBase,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollCtrl) => PublishGateSheet(
          existing: existing,
          planUrlCreditCost: planUrlCreditCost,
          creditBalance: creditBalance,
        ),
      ),
    );
  }

  @override
  State<PublishGateSheet> createState() => _PublishGateSheetState();
}

class _PublishGateSheetState extends State<PublishGateSheet> {
  /// Per-kind checked state. Pre-populated to false for every shippable
  /// kind — nothing pre-checked per locked decision #5.
  final Map<String, bool> _checked = {};

  @override
  void initState() {
    super.initState();
    for (final spec in ArtifactKindRegistry.all) {
      if (spec.shippable) _checked[spec.kind] = false;
    }
  }

  /// Look up an existing `plan_artifacts` row by kind. Returns null if
  /// the kind has never been published on this plan.
  PlanArtifactStatus? _existingFor(String kind) {
    for (final e in widget.existing) {
      if (e.kind == kind && e.isPublished) return e;
    }
    return null;
  }

  _RowState _stateFor(ArtifactKindSpec spec) {
    if (!spec.shippable) return _RowState.soon;
    if (_existingFor(spec.kind) != null) return _RowState.live;
    return (_checked[spec.kind] ?? false)
        ? _RowState.availableChecked
        : _RowState.availableUnchecked;
  }

  /// Per-kind running credit cost. Live rows contribute 0 (already
  /// paid, never re-charged); Soon rows can't be checked; unchecked
  /// rows contribute 0; checked rows contribute the spec's tier price.
  int _costFor(ArtifactKindSpec spec) {
    final state = _stateFor(spec);
    if (state != _RowState.availableChecked) return 0;
    switch (spec.priceTier) {
      case ArtifactPriceTier.free:
        return 0;
      case ArtifactPriceTier.paid:
        // Only `plan_url` is paid + shippable in Wave 3. Use the
        // server-previewed cost when available; fall back to 1.
        return widget.planUrlCreditCost ?? 1;
      case ArtifactPriceTier.premiumTbd:
        // No premium TBD kinds are shippable in Wave 3.
        return 0;
    }
  }

  int get _totalCredits {
    var sum = 0;
    for (final spec in ArtifactKindRegistry.all) {
      sum += _costFor(spec);
    }
    return sum;
  }

  List<String> get _checkedKinds {
    final out = <String>[];
    for (final spec in ArtifactKindRegistry.all) {
      if (_stateFor(spec) == _RowState.availableChecked) {
        out.add(spec.kind);
      }
    }
    return out;
  }

  String _balanceLine() {
    final bal = widget.creditBalance;
    final cost = widget.planUrlCreditCost ?? 1;
    final balText = bal == null
        ? '—'
        : '$bal credit${bal == 1 ? '' : 's'}';
    final tierText = cost == 2
        ? 'Plan > 75 min · 2 credits'
        : (cost == 0
            ? 'Self-verified · free'
            : 'Plan ≤ 75 min · 1 credit');
    return 'You have $balText · $tierText';
  }

  String _ctaLabel() {
    final n = _checkedKinds.length;
    final c = _totalCredits;
    if (n == 0) return 'Publish';
    final artifactWord = n == 1 ? 'artifact' : 'artifacts';
    final creditWord = c == 0
        ? 'free'
        : '$c credit${c == 1 ? '' : 's'}';
    return 'Publish $n $artifactWord · $creditWord';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle. The bottom-sheet's own `showDragHandle: true`
            // isn't enabled here because we want the header to sit
            // below it; we draw our own to keep spacing tight.
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Publish',
              style: TextStyle(
                fontFamily: 'Montserrat',
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.textOnDark,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Pick what you want to send your client. Live rows are already minted.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12.5,
                color: AppColors.textSecondaryOnDark,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),

            // Kind rows
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: ArtifactKindRegistry.all.length,
                separatorBuilder: (_, idx) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final spec = ArtifactKindRegistry.all[i];
                  return _KindRow(
                    spec: spec,
                    state: _stateFor(spec),
                    onTap: spec.shippable && _existingFor(spec.kind) == null
                        ? () {
                            setState(() {
                              _checked[spec.kind] =
                                  !(_checked[spec.kind] ?? false);
                            });
                          }
                        : null,
                  );
                },
              ),
            ),

            const SizedBox(height: 16),
            // Footer — balance, total, CTA
            _Footer(
              balanceLine: _balanceLine(),
              totalCredits: _totalCredits,
              ctaLabel: _ctaLabel(),
              ctaEnabled: _checkedKinds.isNotEmpty,
              onConfirm: () {
                final r = PublishGateResult(
                  kinds: _checkedKinds,
                  credits: _totalCredits,
                );
                Navigator.of(context).pop(r);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _KindRow extends StatelessWidget {
  final ArtifactKindSpec spec;
  final _RowState state;
  final VoidCallback? onTap;

  const _KindRow({required this.spec, required this.state, this.onTap});

  Color _backgroundColor() {
    switch (state) {
      case _RowState.availableChecked:
        return AppColors.primary.withValues(alpha: 0.12);
      case _RowState.live:
        return AppColors.rest.withValues(alpha: 0.08);
      case _RowState.soon:
        return AppColors.surfaceBg;
      case _RowState.availableUnchecked:
        return AppColors.surfaceBase;
    }
  }

  Color _borderColor() {
    switch (state) {
      case _RowState.availableChecked:
        return AppColors.primary.withValues(alpha: 0.5);
      case _RowState.live:
        return AppColors.rest.withValues(alpha: 0.32);
      case _RowState.soon:
        return AppColors.surfaceBorder;
      case _RowState.availableUnchecked:
        return AppColors.surfaceBorder;
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = state == _RowState.soon;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
          decoration: BoxDecoration(
            color: _backgroundColor(),
            border: Border.all(color: _borderColor(), width: 1),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CheckGlyph(state: state),
              const SizedBox(width: 12),
              _KindGlyph(kind: spec.kind, state: state),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            spec.label,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: muted
                                  ? AppColors.textSecondaryOnDark
                                  : AppColors.textOnDark,
                              letterSpacing: -0.1,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (state == _RowState.soon) ...[
                          const SizedBox(width: 8),
                          const _StatusChip(
                            label: 'Soon',
                            background: AppColors.surfaceRaised,
                            foreground: AppColors.textSecondaryOnDark,
                          ),
                        ] else if (state == _RowState.live) ...[
                          const SizedBox(width: 8),
                          _StatusChip(
                            label: 'Live',
                            background:
                                AppColors.rest.withValues(alpha: 0.18),
                            foreground: AppColors.rest,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      spec.description,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11.5,
                        color: muted
                            ? AppColors.textSecondaryOnDark.withValues(alpha: 0.6)
                            : AppColors.textSecondaryOnDark,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _PriceLabel(tier: spec.priceTier, state: state),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckGlyph extends StatelessWidget {
  final _RowState state;

  const _CheckGlyph({required this.state});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color border;
    IconData? icon;
    Color iconColor = Colors.white;
    switch (state) {
      case _RowState.availableChecked:
        bg = AppColors.primary;
        border = AppColors.primary;
        icon = Icons.check;
        break;
      case _RowState.live:
        bg = AppColors.rest;
        border = AppColors.rest;
        icon = Icons.check;
        iconColor = AppColors.surfaceBg;
        break;
      case _RowState.soon:
        bg = Colors.transparent;
        border = AppColors.surfaceBorder;
        icon = null;
        break;
      case _RowState.availableUnchecked:
        bg = Colors.transparent;
        border = AppColors.surfaceBorder;
        icon = null;
        break;
    }
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border, width: 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: icon != null
          ? Icon(icon, size: 14, color: iconColor)
          : null,
    );
  }
}

class _KindGlyph extends StatelessWidget {
  final String kind;
  final _RowState state;

  const _KindGlyph({required this.kind, required this.state});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (state) {
      case _RowState.availableChecked:
        color = AppColors.primary;
        break;
      case _RowState.live:
        color = AppColors.rest;
        break;
      case _RowState.soon:
        color = AppColors.textSecondaryOnDark.withValues(alpha: 0.55);
        break;
      case _RowState.availableUnchecked:
        color = AppColors.textOnDark;
        break;
    }
    IconData icon;
    switch (kind) {
      case ArtifactKind.handout:
        icon = Icons.description_outlined; // page-with-lines
        break;
      case ArtifactKind.planUrl:
        icon = Icons.play_arrow_rounded; // filled play
        break;
      case ArtifactKind.poster:
        icon = Icons.image_outlined;
        break;
      case ArtifactKind.reel:
        icon = Icons.grid_view_rounded;
        break;
      case ArtifactKind.aiReel:
        icon = Icons.auto_awesome;
        break;
      case ArtifactKind.calendar:
        icon = Icons.event_outlined;
        break;
      default:
        icon = Icons.help_outline;
    }
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

class _PriceLabel extends StatelessWidget {
  final ArtifactPriceTier tier;
  final _RowState state;

  const _PriceLabel({required this.tier, required this.state});

  @override
  Widget build(BuildContext context) {
    final muted = state == _RowState.soon;
    switch (tier) {
      case ArtifactPriceTier.free:
        return _stack(
          context,
          big: 'Free',
          unit: '0 cr',
          bigColor: muted
              ? AppColors.textSecondaryOnDark
              : AppColors.rest,
          unitColor: AppColors.textSecondaryOnDark.withValues(
            alpha: muted ? 0.55 : 1.0,
          ),
        );
      case ArtifactPriceTier.paid:
        // Paid kind — show the planUrlCreditCost when known. Wave 3
        // only ships plan_url as a paid kind so the price renders
        // straight off the cost preview. Soon paid kinds (reel later)
        // would resolve their own tier here.
        // Heuristic: display "1" as the canonical paid placeholder
        // until the row is checked, then the running-total in the
        // footer surfaces the real cost. Keeps the row stable.
        return _stack(
          context,
          big: '1',
          unit: 'credit',
          bigColor: muted
              ? AppColors.textSecondaryOnDark
              : AppColors.textOnDark,
          unitColor: AppColors.textSecondaryOnDark.withValues(
            alpha: muted ? 0.55 : 1.0,
          ),
        );
      case ArtifactPriceTier.premiumTbd:
        return _stack(
          context,
          big: 'TBD',
          unit: 'premium',
          bigColor: AppColors.textSecondaryOnDark,
          unitColor: AppColors.textSecondaryOnDark.withValues(alpha: 0.6),
        );
    }
  }

  Widget _stack(
    BuildContext context, {
    required String big,
    required String unit,
    required Color bigColor,
    required Color unitColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          big,
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w700,
            fontSize: 14.5,
            color: bigColor,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          unit.toUpperCase(),
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w600,
            fontSize: 9.5,
            color: unitColor,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;

  const _StatusChip({
    required this.label,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Montserrat',
          fontWeight: FontWeight.w700,
          fontSize: 9.5,
          color: foreground,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final String balanceLine;
  final int totalCredits;
  final String ctaLabel;
  final bool ctaEnabled;
  final VoidCallback onConfirm;

  const _Footer({
    required this.balanceLine,
    required this.totalCredits,
    required this.ctaLabel,
    required this.ctaEnabled,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Balance line
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            balanceLine,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 11.5,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
        ),
        // Big total
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const Text(
                'Total now',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondaryOnDark,
                  letterSpacing: 0.3,
                ),
              ),
              const Spacer(),
              Text(
                totalCredits == 0 ? 'Free' : '$totalCredits',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w800,
                  fontSize: 28,
                  color: totalCredits == 0
                      ? AppColors.rest
                      : AppColors.primary,
                  letterSpacing: -0.5,
                  height: 1.0,
                ),
              ),
              if (totalCredits > 0) ...[
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    totalCredits == 1 ? 'credit' : 'credits',
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondaryOnDark,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        ElevatedButton(
          onPressed: ctaEnabled ? onConfirm : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            disabledBackgroundColor:
                AppColors.surfaceRaised.withValues(alpha: 0.7),
            disabledForegroundColor:
                AppColors.textSecondaryOnDark.withValues(alpha: 0.6),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(13),
            ),
            elevation: 0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_rounded, size: 18),
              const SizedBox(width: 8),
              Text(
                ctaLabel,
                style: const TextStyle(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
