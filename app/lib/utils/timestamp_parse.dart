/// Shared utility for deserializing timestamps that may arrive as an
/// ISO-8601 string (from Supabase JSON), a milliseconds-since-epoch int
/// (from local SQLite), a DateTime (already decoded upstream), or null.
///
/// Used by [Session], [Client], [CachedClient], and [SyncService] to
/// avoid duplicating the same null-safe parsing logic across models.
DateTime? parseTimestamp(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value);
  return null;
}
