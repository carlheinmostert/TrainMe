/// Shared duration formatting helpers.
///
/// Two output styles are supported:
/// - [DurationFormatStyle.compact]  — "Ns" / "Nm" / "Nm Ns"  (e.g. "45s", "2m",
///   "2m 30s"). Used in slider value labels where space is tight.
/// - [DurationFormatStyle.verbose]  — "Ns" / "N min" / "Nh Nmin"  (e.g. "45s",
///   "12 min", "1h 30min"). Used for estimated session/exercise durations.
enum DurationFormatStyle { compact, verbose }

String formatDurationStyled(
  int totalSeconds, {
  DurationFormatStyle style = DurationFormatStyle.verbose,
}) {
  if (totalSeconds < 60) return '${totalSeconds}s';

  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;

  switch (style) {
    case DurationFormatStyle.compact:
      if (minutes < 60) {
        if (seconds == 0) return '${minutes}m';
        return '${minutes}m ${seconds}s';
      }
      // Fall through to hours for very long durations.
      final hours = minutes ~/ 60;
      final remainingMinutes = minutes % 60;
      if (remainingMinutes == 0 && seconds == 0) return '${hours}h';
      if (seconds == 0) return '${hours}h ${remainingMinutes}m';
      return '${hours}h ${remainingMinutes}m ${seconds}s';

    case DurationFormatStyle.verbose:
      if (minutes < 60) return '$minutes min';
      final hours = minutes ~/ 60;
      final remainingMinutes = minutes % 60;
      if (remainingMinutes == 0) return '${hours}h';
      return '${hours}h ${remainingMinutes}min';
  }
}
