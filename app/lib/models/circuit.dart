/// A circuit groups consecutive exercises that repeat together as a cycle.
///
/// For example, exercises 2, 3, 4 grouped into a circuit with 3 cycles means:
/// do exercise 2, then 3, then 4, then repeat that block 3 times total.
class Circuit {
  final String id;

  /// Number of times to repeat the circuit block. Range: 1-10, default: 3.
  final int cycles;

  const Circuit({required this.id, this.cycles = 3});
}
