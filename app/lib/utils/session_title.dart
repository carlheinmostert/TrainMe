/// Default session-title formatter for new sessions created from the
/// Clients-as-Home spine.
///
/// Format: `{DD Mon YYYY HH:MM}` — e.g. `19 Apr 2026 17:09`.
///
/// Reverted from the earlier `{ClientName} · {datetime}` format: since
/// sessions now live under their client's page, the client context is
/// implicit in the navigation. Repeating the client name in every
/// session title was redundant noise.
///
/// [clientName] is retained in the parameter list for API compatibility
/// with existing callers but is intentionally unused. Later cleanup can
/// drop the parameter.
///
/// Used by:
/// - `ClientSessionsScreen._startNewSession` when minting a session.
/// - `Session.clientName` backing store still carries the raw client
///   name so legacy session-filtering by name resolves correctly.
library;

const List<String> _kMonths = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Format a `{DD Mon YYYY HH:MM}` session title.
///
/// Takes [clientName] for API compatibility with the earlier
/// `{clientName} · {datetime}` variant; the parameter is currently
/// ignored — callers can drop it on the next clean-up pass.
// ignore: unused_element_parameter
String formatSessionTitle(String clientName, DateTime dt) {
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
