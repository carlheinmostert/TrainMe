import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import 'undo_snackbar.dart';

/// The circuit-header control sheet. Opened by tapping a circuit header
/// in the Studio list. Replaces the old inline slider with a focused
/// bottom sheet containing:
///   - Circuit name (editable)
///   - Cycles stepper (−/+; min 1, max 10)
///   - "Break circuit" — fires immediately, R-01-style toast undo.
///
/// No modal "Are you sure?" confirmations — the caller handles undo via
/// the returned [CircuitSheetResult] and the helper's built-in snackbar.
class CircuitControlSheet extends StatefulWidget {
  final String initialName;
  final int initialCycles;
  final int minCycles;
  final int maxCycles;
  final bool breakLocked;

  const CircuitControlSheet({
    super.key,
    required this.initialName,
    required this.initialCycles,
    this.minCycles = 1,
    this.maxCycles = 10,
    this.breakLocked = false,
  });

  @override
  State<CircuitControlSheet> createState() => _CircuitControlSheetState();
}

class _CircuitControlSheetState extends State<CircuitControlSheet> {
  late TextEditingController _nameController;
  late int _cycles;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _cycles = widget.initialCycles.clamp(widget.minCycles, widget.maxCycles);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _commit({required bool breakCircuit}) {
    Navigator.of(context).pop(
      CircuitSheetResult(
        name: _nameController.text.trim(),
        cycles: _cycles,
        breakCircuit: breakCircuit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(
            top: BorderSide(color: AppColors.surfaceBorder),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Grabber.
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Static heading — the circuit letter (A/B/C...) is
            // auto-assigned and displayed on the header bar. Renaming
            // is a post-MVP feature that needs a plans.circuit_names
            // JSONB column; until then the field would collect input
            // and silently discard it, which is worse UX than no field.
            Text(
              widget.initialName,
              style: const TextStyle(
                fontFamily: 'Montserrat',
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: AppColors.textOnDark,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Cycles',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondaryOnDark,
                  ),
                ),
                Row(
                  children: [
                    _StepperBtn(
                      icon: Icons.remove,
                      enabled: _cycles > widget.minCycles,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _cycles = (_cycles - 1)
                            .clamp(widget.minCycles, widget.maxCycles));
                      },
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        '×$_cycles',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontFamilyFallback: ['Menlo', 'Courier'],
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    _StepperBtn(
                      icon: Icons.add,
                      enabled: _cycles < widget.maxCycles,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _cycles = (_cycles + 1)
                            .clamp(widget.minCycles, widget.maxCycles));
                      },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.breakLocked
                        ? () {
                            showPublishLockToast(context);
                          }
                        : () {
                            HapticFeedback.mediumImpact();
                            _commit(breakCircuit: true);
                          },
                    icon: Icon(
                      Icons.link_off,
                      size: 18,
                      color: widget.breakLocked
                          ? AppColors.textSecondaryOnDark
                              .withValues(alpha: 0.5)
                          : AppColors.error,
                    ),
                    label: Text(
                      'Break circuit',
                      style: TextStyle(
                        color: widget.breakLocked
                            ? AppColors.textSecondaryOnDark
                                .withValues(alpha: 0.5)
                            : AppColors.error,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: widget.breakLocked
                            ? AppColors.surfaceBorder
                            : AppColors.error.withValues(alpha: 0.4),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      _commit(breakCircuit: false);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepperBtn extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepperBtn({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(9999),
          border: Border.all(
            color: AppColors.surfaceBorder,
          ),
        ),
        child: Icon(
          icon,
          size: 18,
          color: enabled
              ? AppColors.textOnDark
              : AppColors.textSecondaryOnDark.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}

/// Result of the [CircuitControlSheet]. [breakCircuit] true means the
/// practitioner tapped "Break circuit" and the parent should dissolve
/// the circuit id.
class CircuitSheetResult {
  final String name;
  final int cycles;
  final bool breakCircuit;
  const CircuitSheetResult({
    required this.name,
    required this.cycles,
    required this.breakCircuit,
  });
}

Future<CircuitSheetResult?> showCircuitControlSheet(
  BuildContext context, {
  required String initialName,
  required int initialCycles,
  int minCycles = 1,
  int maxCycles = 10,
  bool breakLocked = false,
}) {
  return showModalBottomSheet<CircuitSheetResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => CircuitControlSheet(
      initialName: initialName,
      initialCycles: initialCycles,
      minCycles: minCycles,
      maxCycles: maxCycles,
      breakLocked: breakLocked,
    ),
  );
}
