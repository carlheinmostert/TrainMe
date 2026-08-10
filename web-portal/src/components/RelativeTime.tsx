/**
 * Shared relative-time formatter. Used by ClientsList, SessionsList, and any
 * other surface that renders "3 days ago" style timestamps.
 *
 * No external dependencies — accuracy is "scannable at a glance", not
 * statistical.
 */

function relativeString(d: Date): string {
  const diffMs = Date.now() - d.getTime();
  const diffSec = Math.round(diffMs / 1000);
  if (diffSec < 60) return 'just now';
  const diffMin = Math.round(diffSec / 60);
  if (diffMin < 60) return `${diffMin} min${diffMin === 1 ? '' : 's'} ago`;
  const diffHr = Math.round(diffMin / 60);
  if (diffHr < 24) return `${diffHr} hour${diffHr === 1 ? '' : 's'} ago`;
  const diffDay = Math.round(diffHr / 24);
  if (diffDay < 7) return `${diffDay} day${diffDay === 1 ? '' : 's'} ago`;
  const diffWk = Math.round(diffDay / 7);
  if (diffWk < 5) return `${diffWk} week${diffWk === 1 ? '' : 's'} ago`;
  const diffMo = Math.round(diffDay / 30);
  if (diffMo < 12) return `${diffMo} month${diffMo === 1 ? '' : 's'} ago`;
  const diffYr = Math.round(diffDay / 365);
  return `${diffYr} year${diffYr === 1 ? '' : 's'} ago`;
}

/**
 * Renders an ISO timestamp as a relative "3 days ago" string with an
 * exact-timestamp `title` for hover. Falls back to `fallback` when null.
 */
export function RelativeTime({
  iso,
  fallback = '—',
  fallbackClass,
}: {
  iso: string | null;
  fallback?: string;
  fallbackClass?: string;
}) {
  if (!iso) {
    return <span className={fallbackClass}>{fallback}</span>;
  }
  const date = new Date(iso);
  const abs = date.toLocaleString('en-ZA', {
    dateStyle: 'medium',
    timeStyle: 'short',
  });
  return <span title={abs}>{relativeString(date)}</span>;
}
