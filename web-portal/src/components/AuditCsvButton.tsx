'use client';

import { useState } from 'react';
import { createPortalAuditApi, type AuditRow } from '@/lib/supabase/api';
import { getBrowserClient } from '@/lib/supabase-browser';

/**
 * AuditCsvButton — export the CURRENTLY FILTERED audit set to a CSV file.
 *
 * Design:
 *   - Refetches with `limit = totalCount` (capped at 5000 for safety —
 *     larger exports should paginate server-side; CSV in-browser past 5000
 *     rows blocks the main thread).
 *   - Matches the filter state from the URL. The server component passes
 *     the same filter triplet down so both the table view and the export
 *     stay consistent.
 *   - Builds the CSV client-side + triggers a blob download. No server
 *     round-trip for the file generation.
 *   - Filename: `homefit-audit-{practiceSlug}-{fromYYYYMMDD}-{toYYYYMMDD}.csv`.
 */

const MAX_EXPORT_ROWS = 5000;

export function AuditCsvButton({
  practiceId,
  practiceSlug,
  filters,
  disabled,
}: {
  practiceId: string;
  practiceSlug: string;
  filters: {
    kinds?: string[];
    actor?: string | null;
    from?: string | null;
    to?: string | null;
  };
  disabled?: boolean;
}) {
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  async function exportCsv() {
    if (busy || disabled) return;
    setBusy(true);
    setToast(null);
    try {
      const supabase = getBrowserClient();
      const api = createPortalAuditApi(supabase);
      // Probe pass — fetch 1 row to discover total.
      const probe = await api.listAudit(practiceId, {
        offset: 0,
        limit: 1,
        kinds: filters.kinds,
        actor: filters.actor,
        from: filters.from,
        to: filters.to,
      });
      // Wave 39 — surface RPC failures instead of letting them masquerade
      // as "No events to export." (totalCount=0 on error indistinguishable
      // from a legitimate empty page without checking `.error`).
      if (probe.error) {
        setToast(`Audit RPC failed: ${probe.error}`);
        return;
      }
      const total = probe.totalCount;
      if (total === 0) {
        setToast('No events to export.');
        return;
      }
      const cap = Math.min(total, MAX_EXPORT_ROWS);
      // Second pass — fetch the whole filtered slice (capped).
      const page = await api.listAudit(practiceId, {
        offset: 0,
        limit: cap,
        kinds: filters.kinds,
        actor: filters.actor,
        from: filters.from,
        to: filters.to,
      });
      if (page.error) {
        setToast(`Audit RPC failed: ${page.error}`);
        return;
      }
      const csv = toCsv(page.rows);
      const fileName = buildFileName(practiceSlug, filters.from, filters.to);
      triggerDownload(csv, fileName);
      if (total > MAX_EXPORT_ROWS) {
        setToast(
          `Exported first ${MAX_EXPORT_ROWS} of ${total} — narrow the date range for the rest.`,
        );
      } else {
        setToast(`Exported ${total} events.`);
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Export failed.';
      setToast(msg);
    } finally {
      setBusy(false);
      // Keep toasts around long enough to read.
      setTimeout(() => setToast(null), 4000);
    }
  }

  return (
    <div className="flex flex-col items-end">
      <button
        type="button"
        disabled={busy || disabled}
        onClick={exportCsv}
        className="rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-sm text-ink transition hover:border-brand hover:text-brand disabled:cursor-not-allowed disabled:opacity-50"
      >
        {busy ? 'Exporting…' : 'Export CSV'}
      </button>
      {toast && (
        <p
          className="mt-2 text-xs text-ink-muted"
          role="status"
          aria-live="polite"
        >
          {toast}
        </p>
      )}
    </div>
  );
}

// ----------------------------------------------------------------------------
// CSV helpers
// ----------------------------------------------------------------------------

const CSV_COLUMNS = [
  'date',
  'kind',
  'actor_email',
  'actor_full_name',
  'actor_trainer_id',
  'description',
  'client_id',
  'client_name',
  'credits_delta',
  'balance_after',
  'ref_id',
  'meta_json',
] as const;

function toCsv(rows: AuditRow[]): string {
  const header = CSV_COLUMNS.join(',');
  const body = rows.map((r) =>
    [
      r.ts,
      r.kind,
      r.email ?? '',
      r.fullName ?? '',
      r.trainerId ?? '',
      r.title ?? '',
      r.clientId ?? '',
      r.clientName ?? '',
      r.creditsDelta === null ? '' : String(r.creditsDelta),
      r.balanceAfter === null ? '' : String(r.balanceAfter),
      r.refId ?? '',
      r.meta ? JSON.stringify(r.meta) : '',
    ]
      .map(csvEscape)
      .join(','),
  );
  // Prepend a UTF-8 BOM so Excel detects the encoding correctly.
  return '\uFEFF' + [header, ...body].join('\r\n');
}

function csvEscape(v: string): string {
  // Wrap if the field contains a comma, double quote, CR, or LF. Double up
  // any existing double quotes inside the field per RFC 4180.
  const needsQuote = /[",\r\n]/.test(v);
  const escaped = v.replace(/"/g, '""');
  return needsQuote ? `"${escaped}"` : escaped;
}

function buildFileName(
  practiceSlug: string,
  from: string | null | undefined,
  to: string | null | undefined,
): string {
  const f = from ? from.slice(0, 10).replaceAll('-', '') : 'all';
  const t = to ? to.slice(0, 10).replaceAll('-', '') : 'all';
  return `homefit-audit-${practiceSlug}-${f}-${t}.csv`;
}

function triggerDownload(csv: string, fileName: string) {
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}
