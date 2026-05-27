/// Session-title formatting helpers.
///
/// Format: `{DD Mon YYYY HH:MM}` — e.g. `19 Apr 2026 17:09`.
///
/// Reverted from the earlier `{ClientName} · {datetime}` format: since
/// sessions now live under their client's page, the client context is
/// implicit in the navigation.
library;

const List<String> _kMonths = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Format a `{DD Mon YYYY HH:MM}` session title.
String formatSessionTitle(DateTime dt) {
  return formatSessionTimestamp(dt);
}

/// Just the `{DD Mon YYYY HH:MM}` piece — no client prefix.
///
/// Carried over verbatim from the retired
/// `HomeScreen._formatSessionName` so the timestamp layout stays
/// unchanged across versions (practitioners read this at a glance).
String formatSessionTimestamp(DateTime dt) {
  final day = dt.day;
  final month = _kMonths[dt.month - 1];
  final year = dt.year;
  final hour = dt.hour.toString().padLeft(2, '0');
  final minute = dt.minute.toString().padLeft(2, '0');
  return '$day $month $year $hour:$minute';
}
