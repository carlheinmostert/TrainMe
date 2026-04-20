/// Default session-title formatter for new sessions created from the
/// Clients-as-Home spine.
///
/// Format: `{ClientName} · {DD Mon YYYY HH:MM}` — e.g. `Jan Smith · 19 Apr 2026 17:09`.
///
/// Used by:
/// - `ClientSessionsScreen._startNewSession` when minting a session.
/// - `Session.clientName` backing store continues to carry the raw client
///   name so legacy session-filtering by name still resolves correctly.
library;

const List<String> _kMonths = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Format a `{ClientName} · {DD Mon YYYY HH:MM}` session title.
///
/// Trims [clientName]. When empty falls back to the timestamp alone so the
/// session still gets a useful title rather than a dangling separator.
String formatSessionTitle(String clientName, DateTime dt) {
  final stamp = formatSessionTimestamp(dt);
  final trimmed = clientName.trim();
  if (trimmed.isEmpty) return stamp;
  return '$trimmed \u00b7 $stamp';
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
