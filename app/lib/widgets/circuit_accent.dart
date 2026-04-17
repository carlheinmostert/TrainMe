import 'package:flutter/material.dart';
import '../theme.dart';

/// A left-border accent wrapper used to visually group exercises that are part
/// of the same circuit. Renders a 3px coral-orange rule on the left edge and
/// adds 8px of interior padding so the child's content doesn't collide with
/// the rule.
class CircuitAccent extends StatelessWidget {
  final Widget child;

  const CircuitAccent({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 8),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(
            color: AppColors.circuit,
            width: 3,
          ),
        ),
      ),
      child: child,
    );
  }
}
