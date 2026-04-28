import type { ReactNode } from 'react';
import Link from 'next/link';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import {
  createPortalApi,
  createPortalAuditApi,
  auditChipTone,
  AUDIT_EVENT_KINDS,
  type AuditChipTone,
  type AuditRow,
} from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import {
  AuditFilterBar,
  type ActorOption,
  type KindOption,
} from '@/components/AuditFilterBar';
import { AuditCsvButton } from '@/components/AuditCsvButton';
import { ClientTime } from '@/components/ClientTime';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';

/**
 * `/audit` — Wave 9 unified practice event log.
 *
 * Sources unioned by `list_practice_audit`:
 *   - plan_issuances (plan.publish)
 *   - credit_ledger (credit.*)
 *   - referral_rebate_ledger (referral.rebate)
 *   - clients (client.create / client.delete)
 *   - practice_members (member.join)
 *   - audit_events (catchall — member.role_change, member.remove,
 *     practice.rename, client.restore, ...)
 *
 * Wave 14: invite.mint / invite.claim / invite.revoke chips retired
 * when the Wave 5 invite-code flow was replaced with add-by-email.
 * The label + description maps still carry fallback copy so any legacy
 * audit_events rows with those kinds render gracefully, but nothing
 * new emits them.
 *
 * Transparency rule (CLAUDE.md): every practice member sees every event.
 * No role-based filtering. The Members link in the nav is still owner-only
 * — that's a navigation-clutter call, not an audit-visibility call.
 *
 * URL-driven filters: kinds / actor / from / to / offset all live in the
 * query string so the page is shareable + back-button friendly. The filter
 * bar is a Client Component that mutates the URL; this Server Component
 * reads it + re-runs the RPC.
 */

const PAGE_SIZE = 50;

type SearchParams = {
  practice?: string;
  offset?: string;
  kinds?: string;
  actor?: string;
  from?: string;
  to?: string;
};

export default async function AuditPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/');

  const params = await searchParams;
  // Resolution order: explicit `?practice=` (in-portal Link), then the
  // `hf_active_practice` cookie set by middleware on the most recent
  // app→portal handoff. Middleware 302-strips the param after setting
  // the cookie, so without this fallback the dashboard tile click
  // bounces here, finds no param, and redirects back to /dashboard.
  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? '';
  const practiceId = params.practice ?? cookiePractice;

  const portalApi = createPortalApi(supabase);
  if (!practiceId) {
    // Without a practice context, the event log has nothing to say.
    // Bounce through the dashboard, which picks a default practice.
    redirect('/dashboard');
  }

  const role = await portalApi.getCurrentUserRole(practiceId, user.id);
  if (role === null) {
    // Non-member: the RPC would 42501 anyway; pre-empt for a cleaner UX.
    redirect('/dashboard');
  }
  const isOwner = role === 'owner';

  // Parse filter triplet from URL. Empty strings normalise to null so we
  // never ask the RPC to match an empty string (which would filter to
  // nothing rather than "no filter").
  const offset = parseNonNegativeInt(params.offset, 0);
  const kinds = parseKindList(params.kinds);
  const actor = nullIfBlank(params.actor);
  const from = normaliseDateStart(params.from);
  const to = normaliseDateEnd(params.to);

  const auditApi = createPortalAuditApi(supabase);
  const [page, practices, members] = await Promise.all([
    auditApi.listAudit(practiceId, {
      offset,
      limit: PAGE_SIZE,
      kinds,
      actor,
      from,
      to,
    }),
    portalApi.listMyPractices(),
    // Pull the member list for the actor dropdown. RPC falls back to an
    // empty array when not granted — the dropdown will just show "All
    // practitioners".
    listMembersForActorFilter(portalApi, practiceId),
  ]);

  const practice = practices.find((p) => p.id === practiceId);
  const practiceSlug = practice
    ? slugify(practice.name)
    : practiceId.slice(0, 8);

  const totalCount = page.totalCount;
  const showingFrom = totalCount === 0 ? 0 : offset + 1;
  const showingTo = Math.min(offset + page.rows.length, totalCount);

  const kindGroups = buildKindGroups();
  const practiceQs = `practice=${practiceId}`;
  const filterQs = buildFilterQs(params);

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={practiceId}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-6xl flex-1 px-6 py-10">
        <nav className="mb-4 text-sm text-ink-muted">
          <Link
            href={`/dashboard?${practiceQs}`}
            className="hover:text-brand"
          >
            &larr; Dashboard
          </Link>
        </nav>

        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="font-heading text-3xl font-bold">Audit log</h1>
            <p className="mt-2 text-sm text-ink-muted">
              Every event in this practice — publishes, credits, members,
              invites, clients. Visible to every practice member.
            </p>
          </div>
          <AuditCsvButton
            practiceId={practiceId}
            practiceSlug={practiceSlug}
            filters={{ kinds, actor, from, to }}
            disabled={totalCount === 0}
          />
        </div>

        <AuditFilterBar
          practiceId={practiceId}
          actors={members}
          kindGroups={kindGroups}
          initialKinds={kinds ?? []}
          initialActor={actor}
          initialFrom={params.from ?? null}
          initialTo={params.to ?? null}
        />

        <div className="mt-4 flex items-center justify-between text-xs text-ink-muted">
          <span>
            {page.error
              ? 'Audit log unavailable.'
              : totalCount === 0
                ? 'No events.'
                : `Showing ${showingFrom}–${showingTo} of ${totalCount}`}
          </span>
        </div>

        {page.error ? (
          <AuditErrorBanner message={page.error} />
        ) : page.rows.length === 0 ? (
          <EmptyState practiceId={practiceId} hasAnyFilter={hasAnyFilter(params)} />
        ) : (
          <AuditTable rows={page.rows} />
        )}

        <Pagination
          offset={offset}
          pageSize={PAGE_SIZE}
          totalCount={totalCount}
          pathQs={`?${filterQs}`}
        />
      </div>
    </main>
  );
}

// ----------------------------------------------------------------------------
// Table
// ----------------------------------------------------------------------------

function AuditTable({ rows }: { rows: AuditRow[] }) {
  // Wave 39 — derive the unlock ↔ publish mapping client-side. For each
  // credit.consumption row whose title is 'unlock_plan_for_edit', find the
  // earliest later plan.publish row on the same plan whose
  // meta.prepaid_unlock_at matches the unlock's ts. Build two lookup maps
  // so the row renderer can stamp:
  //   * publishesByPrepaidTs[unlock.ts] -> the publish row's ts
  //     ("Used at ..." subtitle on the unlock row)
  //   * plan.publish row already carries meta.prepaid_unlock_at ->
  //     "Prepaid via unlock at ..." subtitle on the publish row
  //
  // The rows array is ordered ts DESC, so we iterate from the END
  // (oldest-first) when matching unlocks to publishes. A pure-client
  // derivation is fine: the audit page is paginated at 50 rows; an
  // unlock and its corresponding publish are typically adjacent in
  // time (and almost always in the same page).
  const usedByUnlockTs = new Map<string, string>();
  for (const r of rows) {
    if (r.kind !== 'plan.publish') continue;
    const prepaid = r.meta?.prepaid_unlock_at;
    if (typeof prepaid === 'string' && prepaid.length > 0) {
      // Multiple publishes can share the same prepaid timestamp only in
      // the (impossible) double-spend race; keep the earliest publish
      // wins behaviour by checking before set.
      const existing = usedByUnlockTs.get(prepaid);
      if (!existing || new Date(r.ts) < new Date(existing)) {
        usedByUnlockTs.set(prepaid, r.ts);
      }
    }
  }

  return (
    <div className="mt-6 overflow-hidden rounded-lg border border-surface-border bg-surface-base">
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="bg-surface-raised text-xs uppercase tracking-wider text-ink-muted">
            <tr>
              <th scope="col" className="px-4 py-3">Date</th>
              <th scope="col" className="px-4 py-3">Actor</th>
              <th scope="col" className="px-4 py-3">Kind</th>
              <th scope="col" className="px-4 py-3">Description</th>
              <th scope="col" className="px-4 py-3">Client</th>
              <th scope="col" className="px-4 py-3 text-right">Credits &Delta;</th>
              <th scope="col" className="px-4 py-3 text-right">Balance after</th>
              <th scope="col" className="px-4 py-3">Link</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-surface-border">
            {rows.map((r, idx) => (
              <AuditTableRow
                key={`${r.ts}-${r.kind}-${idx}`}
                row={r}
                publishTsForUnlock={usedByUnlockTs.get(r.ts) ?? null}
              />
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function AuditTableRow({
  row,
  publishTsForUnlock,
}: {
  row: AuditRow;
  publishTsForUnlock: string | null;
}) {
  const tone = auditChipTone(row.kind);
  const description = buildDescription(row);
  const link = buildLink(row);
  // Wave 39 — secondary subtitle line. Two sources:
  //   1. plan.publish + meta.prepaid_unlock_at → "Prepaid via unlock at …"
  //   2. credit.consumption + title='unlock_plan_for_edit' →
  //        "Used at {publish date}" or "Awaiting republish"
  const subtitle = buildSubtitle(row, publishTsForUnlock);
  // Wave 40.1 — `plan.opened` rows now derive the practitioner who LAST
  // published the plan via plan_issuances.trainer_id (see
  // `list_practice_audit`). The actor email is no longer NULL for the
  // anon-web-player path. We surface a discreet tooltip on the actor cell
  // explaining that the actor for `plan.opened` rows is the plan owner —
  // an anonymous client triggered the open. Least-cluttered UI hint per
  // Wave 40.1 brief.
  const actorTooltip =
    row.kind === 'plan.opened'
      ? 'Plan owner — opened by anonymous client'
      : undefined;

  return (
    <tr>
      <td className="whitespace-nowrap px-4 py-3 text-ink-muted">
        <ClientTime ts={row.ts} />
      </td>
      <td className="px-4 py-3" title={actorTooltip}>
        {row.email ? (
          <div className="flex flex-col">
            <span className="text-sm text-ink">{row.email}</span>
            {row.fullName ? (
              <span className="text-xs text-ink-dim">{row.fullName}</span>
            ) : null}
          </div>
        ) : (
          <span className="text-ink-dim">&mdash;</span>
        )}
      </td>
      <td className="px-4 py-3">
        <KindChip kind={row.kind} tone={tone} />
      </td>
      <td className="px-4 py-3 text-ink">
        <div>{description}</div>
        {subtitle ? (
          <div className="mt-1 text-xs text-ink-dim">{subtitle}</div>
        ) : null}
      </td>
      <td className="px-4 py-3">
        <ClientCell clientId={row.clientId} clientName={row.clientName} />
      </td>
      <td
        className={`whitespace-nowrap px-4 py-3 text-right font-mono text-xs ${creditsClass(row.creditsDelta)}`}
      >
        {row.creditsDelta === null ? '—' : fmtCreditDelta(row.creditsDelta)}
      </td>
      <td className="whitespace-nowrap px-4 py-3 text-right font-mono text-xs text-ink-muted">
        {row.balanceAfter === null ? '—' : fmtBalance(row.balanceAfter)}
      </td>
      <td className="px-4 py-3">
        {link ? (
          <a
            href={link.href}
            target={link.external ? '_blank' : undefined}
            rel={link.external ? 'noopener noreferrer' : undefined}
            className="text-brand hover:underline"
          >
            {link.label}
          </a>
        ) : (
          <span className="text-ink-dim">—</span>
        )}
      </td>
    </tr>
  );
}

/** Wave 40.1 — Client column cell. Plan-shaped + client-shaped rows show
 *  a `<Link>` to the client detail page; practice-shaped rows show "—".
 *  Tombstoned clients still surface their last-known name (the link still
 *  resolves — the detail page handles deleted clients gracefully). */
function ClientCell({
  clientId,
  clientName,
}: {
  clientId: string | null;
  clientName: string | null;
}) {
  if (!clientId || !clientName) {
    return <span className="text-ink-dim">&mdash;</span>;
  }
  return (
    <Link
      href={`/clients/${clientId}`}
      className="text-brand hover:underline"
    >
      {clientName}
    </Link>
  );
}

/** Wave 39 — secondary subtitle for the description column. Surfaces the
 *  unlock ↔ publish prepayment relationship so the audit log reads
 *  end-to-end without a context-switch.
 *
 *  Branches:
 *    1. plan.publish + meta.prepaid_unlock_at: "Prepaid via unlock at {ts}"
 *    2. credit.consumption + title='unlock_plan_for_edit':
 *         - matched publish in this page → "Used at {publish ts}"
 *         - no match → "Awaiting republish"
 *    Returns null otherwise.
 *
 *  Wave 39.4 — return type widened to ReactNode so the embedded timestamp
 *  can render via <ClientTime> (browser-local TZ post-hydration) instead
 *  of a UTC-pinned string. The single caller renders the result as a JSX
 *  child, which accepts ReactNode natively. */
function buildSubtitle(
  row: AuditRow,
  publishTsForUnlock: string | null,
): ReactNode {
  if (row.kind === 'plan.publish') {
    const prepaid = row.meta?.prepaid_unlock_at;
    if (typeof prepaid === 'string' && prepaid.length > 0) {
      return (
        <>
          Prepaid via unlock at <ClientTime ts={prepaid} />
        </>
      );
    }
    return null;
  }
  if (
    row.kind === 'credit.consumption' &&
    typeof row.title === 'string' &&
    row.title === 'unlock_plan_for_edit'
  ) {
    if (publishTsForUnlock) {
      return (
        <>
          Used at <ClientTime ts={publishTsForUnlock} />
        </>
      );
    }
    return 'Awaiting republish';
  }
  return null;
}

function KindChip({ kind, tone }: { kind: string; tone: AuditChipTone }) {
  return (
    <span
      className={`inline-block rounded-full px-2.5 py-0.5 text-xs font-medium ${chipClass(tone)}`}
    >
      {kindLabel(kind)}
    </span>
  );
}

// ----------------------------------------------------------------------------
// Empty + pagination
// ----------------------------------------------------------------------------

/** Wave 39 — surfaced when `listAudit` returns a non-null `error`. Replaces
 *  the misleading "no events" empty state so an RPC failure doesn't hide
 *  the entire feature. The detail line is intentionally terse — the full
 *  error already lives in the browser console via `console.error`. */
function AuditErrorBanner({ message }: { message: string }) {
  return (
    <div className="mt-10 rounded-lg border border-coral/40 bg-coral/5 p-6 text-center">
      <p className="font-medium text-coral">Audit log unavailable</p>
      <p className="mt-2 text-sm text-ink-muted">
        The audit RPC returned an error. Try refreshing — if it persists,
        the browser console has the diagnostic detail.
      </p>
      <p className="mt-3 font-mono text-xs text-ink-dim">{message}</p>
    </div>
  );
}

function EmptyState({
  practiceId,
  hasAnyFilter,
}: {
  practiceId: string;
  hasAnyFilter: boolean;
}) {
  return (
    <div className="mt-10 rounded-lg border border-surface-border bg-surface-base p-8 text-center">
      <p className="text-ink-muted">
        {hasAnyFilter
          ? 'No events match these filters.'
          : 'No events yet. Publish a plan or invite a practitioner to see activity here.'}
      </p>
      {hasAnyFilter && (
        <Link
          href={`/audit?practice=${practiceId}`}
          className="mt-3 inline-block text-sm text-brand hover:underline"
        >
          Clear filters
        </Link>
      )}
    </div>
  );
}

function Pagination({
  offset,
  pageSize,
  totalCount,
  pathQs,
}: {
  offset: number;
  pageSize: number;
  totalCount: number;
  pathQs: string;
}) {
  if (totalCount <= pageSize) return null;
  const prevOffset = Math.max(0, offset - pageSize);
  const nextOffset = offset + pageSize;
  const hasPrev = offset > 0;
  const hasNext = nextOffset < totalCount;
  const prevHref = buildOffsetHref(pathQs, prevOffset);
  const nextHref = buildOffsetHref(pathQs, nextOffset);

  return (
    <div className="mt-4 flex items-center justify-end gap-2">
      {hasPrev ? (
        <Link
          href={prevHref}
          className="rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-sm text-ink transition hover:border-brand hover:text-brand"
        >
          ← Prev
        </Link>
      ) : (
        <span className="rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-sm text-ink-dim">
          ← Prev
        </span>
      )}
      {hasNext ? (
        <Link
          href={nextHref}
          className="rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-sm text-ink transition hover:border-brand hover:text-brand"
        >
          Next →
        </Link>
      ) : (
        <span className="rounded-md border border-surface-border bg-surface-raised px-3 py-1.5 text-sm text-ink-dim">
          Next →
        </span>
      )}
    </div>
  );
}

// ----------------------------------------------------------------------------
// Helpers — parsing + formatting + mapping kind → label / description / link
// ----------------------------------------------------------------------------

function parseNonNegativeInt(v: string | undefined, fallback: number): number {
  if (!v) return fallback;
  const n = Number.parseInt(v, 10);
  if (!Number.isFinite(n) || n < 0) return fallback;
  return n;
}

function parseKindList(v: string | undefined): string[] | undefined {
  if (!v) return undefined;
  const arr = v
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  return arr.length > 0 ? arr : undefined;
}

function nullIfBlank(v: string | undefined): string | null {
  if (!v) return null;
  const t = v.trim();
  return t.length === 0 ? null : t;
}

/** Accept YYYY-MM-DD from the <input type="date"> and pin to day-start. */
function normaliseDateStart(v: string | undefined): string | null {
  if (!v) return null;
  const t = v.trim();
  if (t.length === 0) return null;
  // Already ISO? Pass through. Otherwise append the T00:00 suffix.
  if (t.includes('T')) return t;
  return `${t}T00:00:00.000Z`;
}

function normaliseDateEnd(v: string | undefined): string | null {
  if (!v) return null;
  const t = v.trim();
  if (t.length === 0) return null;
  if (t.includes('T')) return t;
  // Inclusive end-of-day.
  return `${t}T23:59:59.999Z`;
}

function hasAnyFilter(params: SearchParams): boolean {
  return Boolean(params.kinds || params.actor || params.from || params.to);
}

function buildFilterQs(params: SearchParams): string {
  const p = new URLSearchParams();
  if (params.practice) p.set('practice', params.practice);
  if (params.kinds) p.set('kinds', params.kinds);
  if (params.actor) p.set('actor', params.actor);
  if (params.from) p.set('from', params.from);
  if (params.to) p.set('to', params.to);
  return p.toString();
}

function buildOffsetHref(baseQs: string, offset: number): string {
  // Strip any existing offset + re-append.
  const p = new URLSearchParams(baseQs.startsWith('?') ? baseQs.slice(1) : baseQs);
  if (offset > 0) p.set('offset', String(offset));
  else p.delete('offset');
  return `?${p.toString()}`;
}

function fmtCreditDelta(n: number): string {
  const sign = n > 0 ? '+' : '';
  // Strip trailing zeros on fractional values but keep integers clean.
  const rounded = Math.round(n * 10000) / 10000;
  if (Number.isInteger(rounded)) return `${sign}${rounded}`;
  return `${sign}${rounded}`;
}

function fmtBalance(n: number): string {
  const rounded = Math.round(n * 10000) / 10000;
  if (Number.isInteger(rounded)) return `${rounded}`;
  return `${rounded}`;
}

function creditsClass(n: number | null): string {
  if (n === null) return 'text-ink-dim';
  if (n > 0) return 'text-emerald-400';
  if (n < 0) return 'text-red-400';
  return 'text-ink-muted';
}

/** Render-friendly label for a kind string. Unknown kinds pass through
 *  with dots → spaces so future audit_events emit sensible copy without
 *  needing a code change. */
function kindLabel(kind: string): string {
  const map: Record<string, string> = {
    'plan.publish': 'Plan publish',
    // Wave 39 — client engagement read.
    'plan.opened': 'Plan opened',
    'credit.consumption': 'Credit consumption',
    'credit.purchase': 'Credit purchase',
    'credit.refund': 'Credit refund',
    'credit.adjustment': 'Credit adjustment',
    'credit.signup_bonus': 'Signup bonus',
    'credit.referral_signup_bonus': 'Referral signup bonus',
    'referral.rebate': 'Referral rebate',
    'client.create': 'Client create',
    'client.delete': 'Client delete',
    'client.restore': 'Client restore',
    // Wave 40.3 — set_client_video_consent emission.
    'client.consent.update': 'Visibility update',
    'member.join': 'Member join',
    'member.role_change': 'Role change',
    'member.remove': 'Member remove',
    'invite.mint': 'Invite minted',
    'invite.claim': 'Invite claimed',
    'invite.revoke': 'Invite revoked',
    'practice.rename': 'Practice rename',
  };
  if (map[kind]) return map[kind];
  return kind.replaceAll('.', ' ').replaceAll('_', ' ');
}

function chipClass(tone: AuditChipTone): string {
  switch (tone) {
    case 'coral':
      return 'bg-brand-tint-bg text-brand';
    case 'sage':
      return 'bg-emerald-500/15 text-emerald-400';
    case 'red':
      return 'bg-red-500/15 text-red-400';
    default:
      return 'bg-surface-raised text-ink-muted';
  }
}

function buildDescription(row: AuditRow): string {
  // Kind-specific description copy. The `title` column holds the natural
  // primary detail for most kinds (plan title, client name, member role,
  // invite code, ledger notes); the meta jsonb adds secondary detail
  // when we care about it.
  switch (row.kind) {
    case 'plan.publish': {
      const version = row.meta && typeof row.meta.version === 'number'
        ? ` (v${row.meta.version})`
        : '';
      return row.title ? `${row.title}${version}` : `Plan published${version}`;
    }
    case 'plan.opened':
      // Anon read from the web player; we don't have the title in the
      // audit row, but the Player link in the Link column resolves to
      // the plan URL.
      return 'Client opened plan';
    case 'credit.consumption':
      return row.title ?? 'Credit spent on publish';
    case 'credit.purchase':
      return row.title ?? 'Credits purchased';
    case 'credit.refund':
      return row.title ?? 'Credits refunded';
    case 'credit.adjustment':
      return row.title ?? 'Credit adjustment';
    case 'credit.signup_bonus':
      return row.title ?? 'Organic signup bonus';
    case 'credit.referral_signup_bonus':
      return row.title ?? 'Referral signup bonus';
    case 'referral.rebate':
      return 'Referral rebate earned';
    case 'client.create':
      return row.title ? `Created client "${row.title}"` : 'Client created';
    case 'client.delete':
      return row.title ? `Deleted client "${row.title}"` : 'Client deleted';
    case 'client.restore':
      return row.title ? `Restored client "${row.title}"` : 'Client restored';
    case 'client.consent.update': {
      // Wave 40.3 — meta carries `from`/`to` jsonb. Surface the keys whose
      // boolean flipped so the practitioner can read the row without
      // expanding it. Falls back to a generic line when the meta shape is
      // missing or both bags are equal (server-side guard should prevent
      // the latter, but defensive).
      const who = row.clientName ? `${row.clientName}` : 'client';
      const diffs = describeConsentDiff(row.meta);
      if (diffs.length === 0) {
        return `Visibility settings updated for ${who}`;
      }
      return `Visibility for ${who}: ${diffs.join(', ')}`;
    }
    case 'member.join':
      return row.title
        ? `Joined as ${row.title}`
        : 'Joined the practice';
    case 'member.role_change':
      return 'Role changed';
    case 'member.remove':
      return 'Removed from practice';
    case 'invite.mint':
      return row.title ? `Minted invite code ${row.title}` : 'Invite minted';
    case 'invite.claim':
      return row.title ? `Claimed invite code ${row.title}` : 'Invite claimed';
    case 'invite.revoke':
      return 'Invite code revoked';
    case 'practice.rename':
      return 'Practice renamed';
    default:
      return row.title ?? kindLabel(row.kind);
  }
}

/**
 * Wave 40.3 — render a compact diff summary from a `client.consent.update`
 * row's meta jsonb. Returns one short token per key whose boolean flipped
 * (e.g. `Avatar on`, `B&W off`). `line_drawing` is excluded — it's locked
 * true and never moves. Returns `[]` when the meta shape is missing, both
 * bags are equal, or both bags are empty.
 */
function describeConsentDiff(
  meta: Record<string, unknown> | null,
): string[] {
  if (!meta) return [];
  const from = meta.from as Record<string, unknown> | null | undefined;
  const to = meta.to as Record<string, unknown> | null | undefined;
  if (!from || !to || typeof from !== 'object' || typeof to !== 'object') {
    return [];
  }
  // Stable display order: line_drawing skipped, then the practitioner-
  // facing toggles in the same vertical order as ClientDetailPanel.
  const order: Array<{ key: string; label: string }> = [
    { key: 'grayscale', label: 'B&W' },
    { key: 'original', label: 'Colour' },
    { key: 'avatar', label: 'Avatar' },
  ];
  const diffs: string[] = [];
  for (const { key, label } of order) {
    const before = Boolean(from[key]);
    const after = Boolean(to[key]);
    if (before !== after) {
      diffs.push(`${label} ${after ? 'on' : 'off'}`);
    }
  }
  return diffs;
}

type AuditLink = { href: string; label: string; external: boolean };

function buildLink(row: AuditRow): AuditLink | null {
  if (!row.refId) return null;
  switch (row.kind) {
    case 'client.create':
    case 'client.delete':
    case 'client.restore':
    // Wave 40.3 — link the consent update through to the client detail page.
    case 'client.consent.update':
      return {
        href: `/clients/${row.refId}`,
        label: 'Client',
        external: false,
      };
    case 'plan.publish':
    // Wave 39 — plan.opened rows carry the plan uuid in ref_id (set
    // by record_plan_opened); same external-link target as publish.
    case 'plan.opened':
      // The plan URL lives on plans.plan_url, which the RPC doesn't surface.
      // Use refId (plan uuid) as the link; the player page treats any
      // non-matching uuid as "plan not found" gracefully.
      return {
        href: `https://session.homefit.studio/p/${row.refId}`,
        label: 'Player',
        external: true,
      };
    default:
      return null;
  }
}

// ----------------------------------------------------------------------------
// Kind groupings for the filter bar
// ----------------------------------------------------------------------------

function buildKindGroups(): {
  tone: AuditChipTone;
  label: string;
  kinds: KindOption[];
}[] {
  const groups: Record<
    AuditChipTone,
    { tone: AuditChipTone; label: string; kinds: KindOption[] }
  > = {
    coral: { tone: 'coral', label: 'Plan / burn', kinds: [] },
    sage: { tone: 'sage', label: 'Credits in', kinds: [] },
    red: { tone: 'red', label: 'Destructive', kinds: [] },
    grey: { tone: 'grey', label: 'Neutral', kinds: [] },
  };
  for (const kind of AUDIT_EVENT_KINDS) {
    const tone = auditChipTone(kind);
    groups[tone].kinds.push({
      kind,
      label: kindLabel(kind),
      tone,
    });
  }
  return [groups.coral, groups.sage, groups.red, groups.grey].filter(
    (g) => g.kinds.length > 0,
  );
}

// ----------------------------------------------------------------------------
// Actor list for the filter dropdown
// ----------------------------------------------------------------------------

async function listMembersForActorFilter(
  portalApi: ReturnType<typeof createPortalApi>,
  practiceId: string,
): Promise<ActorOption[]> {
  // Wave 5 RPC returns email + full_name + role. Fall back to an empty
  // list if it fails — the filter bar renders "All practitioners" only.
  const rows = await portalApi.listPracticeMembersWithProfile(practiceId);
  return rows
    .map((r) => ({
      trainerId: r.trainerId,
      email: r.email,
      fullName: r.fullName,
    }))
    .filter((a) => a.trainerId.length > 0 && a.email.length > 0);
}

function slugify(name: string): string {
  return name
    .toLowerCase()
    .replaceAll(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 32) || 'practice';
}
