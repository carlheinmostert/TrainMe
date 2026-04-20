import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi, PortalReferralApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { PracticeSwitcher } from '@/components/PracticeSwitcher';
import { DashboardTile } from '@/components/DashboardTile';

type SearchParams = { practice?: string };

/**
 * `/dashboard` — the practitioner's summary surface.
 *
 * R-12 compliance:
 *   - R-12.1 every tile has a destination — the whole card is a Link.
 *   - R-12.2 no orphaned functionality — network share + earnings now
 *     live on /network; the dashboard tile is a summary-plus-click.
 *   - R-12.3 primary nav covers every destination — BrandHeader expanded.
 *   - R-12.4 dashboard is a summary — no inline forms, no long lists.
 *   - R-12.5 one affordance style — DashboardTile everywhere.
 *
 * Owners see 5 tiles (includes Members), practitioners see 4.
 */
export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/');

  const api = createPortalApi(supabase);
  const params = await searchParams;
  const practices = await api.listMyPractices();

  if (practices.length === 0) {
    return (
      <main className="flex min-h-screen flex-col">
        <BrandHeader showSignOut />
        <div className="mx-auto max-w-2xl px-6 py-16">
          <h1 className="font-heading text-3xl font-bold">Welcome</h1>
          <p className="mt-3 text-ink-muted">
            You&rsquo;re signed in but not yet a member of any practice. Ask
            your practice owner to invite you, or contact support to set up a
            new practice.
          </p>
        </div>
      </main>
    );
  }

  const selectedId = params.practice ?? practices[0].id;
  const selected = practices.find((p) => p.id === selectedId) ?? practices[0];
  const qs = `?practice=${selected.id}`;

  // All dashboard inputs fetched in parallel. Role drives Members tile
  // visibility + the BrandHeader Members link. Referral stats + last
  // issuance are pre-computed so the tile copy doesn't say "loading".
  const referralApi = new PortalReferralApi(supabase);
  const [
    balance,
    role,
    clients,
    referralStats,
    lastIssuanceAt,
    members,
  ] = await Promise.all([
    api.getPracticeBalance(selected.id),
    api.getCurrentUserRole(selected.id, user.id),
    api.listPracticeClients(selected.id),
    referralApi.dashboardStats(selected.id),
    api.getLastIssuanceAt(selected.id),
    api.listPracticeMembers(selected.id),
  ]);
  const isOwner = role === 'owner';

  /* ----------------------------------------------------------------- */
  /*  Derived tile content                                              */
  /* ----------------------------------------------------------------- */

  // Credits
  const creditsLow = balance < 5;
  const creditsHeadline = `${balance} ${balance === 1 ? 'credit' : 'credits'}`;
  const creditsSubtitle = creditsLow
    ? 'Running low — top up'
    : 'Buy more';

  // Clients — "active this week" = last_plan_at within last 7 days.
  const clientCount = clients.length;
  const now = Date.now();
  const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
  const activeThisWeek = clients.filter((c) => {
    if (!c.lastPlanAt) return false;
    const t = Date.parse(c.lastPlanAt);
    return Number.isFinite(t) && now - t < sevenDaysMs;
  }).length;
  const clientsHeadline =
    clientCount === 0
      ? 'No clients yet'
      : `${clientCount} ${clientCount === 1 ? 'client' : 'clients'}`;
  const clientsSubtitle =
    clientCount === 0
      ? 'Publish a plan to add your first'
      : activeThisWeek > 0
        ? `${activeThisWeek} active this week`
        : 'No activity this week';

  // Network — surface rebate-balance + referee count. Peer-to-peer
  // language: "free publishes banked", "in your network". Never
  // "earned", "commission", "reward", "payout".
  const rebateBalance = referralStats.rebate_balance_credits;
  const refereeCount = referralStats.referee_count;
  const networkHeadline =
    rebateBalance > 0
      ? `+${fmtCredits(rebateBalance)} free publishes`
      : 'Free publishes banked';
  const networkSubtitle =
    refereeCount === 0
      ? 'Share your code to start'
      : `${refereeCount} ${refereeCount === 1 ? 'practitioner' : 'practitioners'} in your network`;

  // Audit — relative "Last publish" date.
  const auditHeadline = lastIssuanceAt
    ? formatRelativeDate(lastIssuanceAt, now)
    : 'Never';
  const auditSubtitle = lastIssuanceAt
    ? 'Last plan published'
    : 'Publish from the mobile app to fill this';

  // Members (owner only)
  const memberCount = members.length;
  const membersHeadline = `${memberCount} ${memberCount === 1 ? 'practitioner' : 'practitioners'}`;
  const membersSubtitle = memberCount === 1 ? 'Invite more' : 'Manage team';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={selected.id}
        isOwner={isOwner}
      />
      <div className="mx-auto w-full max-w-5xl flex-1 px-6 py-10">
        <div className="mb-8 flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="font-heading text-3xl font-bold">Dashboard</h1>
            <p className="text-sm text-ink-muted">Signed in as {user.email}</p>
          </div>
          <PracticeSwitcher practices={practices} selectedId={selected.id} />
        </div>

        {/*
          Tile order is load-bearing. Network MUST sit next to Credits so
          the two forms of the same currency (bought credits + free
          credits earned from the network) are scannable together. This
          reinforces the single-currency mental model: you BUY credits,
          you EARN free credits on your network's spend.
        */}
        <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          <DashboardTile
            href={`/credits${qs}`}
            label="Credits"
            headline={creditsHeadline}
            subtitle={creditsSubtitle}
            tone={creditsLow ? 'warning' : 'default'}
          />

          <DashboardTile
            href={`/network${qs}`}
            label="Network"
            headline={networkHeadline}
            subtitle={networkSubtitle}
          />

          <DashboardTile
            href={`/clients${qs}`}
            label="Clients"
            headline={clientsHeadline}
            subtitle={clientsSubtitle}
          />

          <DashboardTile
            href={`/audit${qs}`}
            label="Audit"
            headline={auditHeadline}
            subtitle={auditSubtitle}
          />

          {isOwner && (
            <DashboardTile
              href={`/members${qs}`}
              label="Members"
              headline={membersHeadline}
              subtitle={membersSubtitle}
            />
          )}
        </div>
      </div>
    </main>
  );
}

/* ------------------------------------------------------------------- */
/*  Formatters                                                          */
/* ------------------------------------------------------------------- */

function fmtCredits(n: number): string {
  const rounded = Math.round(n * 10) / 10;
  return Number.isInteger(rounded)
    ? String(Math.round(rounded))
    : rounded.toFixed(1);
}

/**
 * Human-readable relative date for the Audit tile. Uses the built-in
 * `Intl.RelativeTimeFormat` so we avoid a date library dependency. The
 * ladder (minute → hour → day → week → month → year) picks the biggest
 * unit that yields a non-zero magnitude.
 *
 * Uses `numeric: 'auto'` so near-present values render as "today",
 * "yesterday", "last week" rather than the numeric "0 days ago".
 */
function formatRelativeDate(iso: string, nowMs: number): string {
  const then = Date.parse(iso);
  if (!Number.isFinite(then)) return 'Recently';
  const diffMs = then - nowMs; // negative for past

  const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
  const absSec = Math.abs(diffMs) / 1000;

  if (absSec < 60) return rtf.format(Math.round(diffMs / 1000), 'second');
  if (absSec < 60 * 60) return rtf.format(Math.round(diffMs / 60000), 'minute');
  if (absSec < 60 * 60 * 24)
    return rtf.format(Math.round(diffMs / (60 * 60 * 1000)), 'hour');
  if (absSec < 60 * 60 * 24 * 7)
    return rtf.format(Math.round(diffMs / (24 * 60 * 60 * 1000)), 'day');
  if (absSec < 60 * 60 * 24 * 30)
    return rtf.format(Math.round(diffMs / (7 * 24 * 60 * 60 * 1000)), 'week');
  if (absSec < 60 * 60 * 24 * 365)
    return rtf.format(Math.round(diffMs / (30 * 24 * 60 * 60 * 1000)), 'month');
  return rtf.format(Math.round(diffMs / (365 * 24 * 60 * 60 * 1000)), 'year');
}
