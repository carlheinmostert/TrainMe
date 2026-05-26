import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { getServerClient } from '@/lib/supabase-server';
import {
  createPortalApi,
  createPortalAuditApi,
  PortalReferralApi,
} from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { DashboardTile } from '@/components/DashboardTile';
import { DashboardAuditCard } from '@/components/DashboardAuditCard';
import { DashboardTooltipProvider } from '@/components/DashboardTooltipProvider';
import { GetTheAppBanner } from '@/components/GetTheAppBanner';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';
import {
  Coins,
  UserRound,
  ScrollText,
  UsersRound,
  Settings,
  Building2,
  Globe2,
  Layers,
  Dumbbell,
} from 'lucide-react';

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
 * Dashboard rework (2026-05-22 — C-9 + C-12 + C-13):
 *   - C-9: Classes tile remains as a coming-soon teaser.
 *   - C-12: Network tile removed. Its content now lives on the Credits
 *     tile as a coral footer band ("+ N free earned from your network").
 *   - C-13: GetTheAppBanner renders above the grid for practices that
 *     haven't published yet. Clients + Classes tiles carry an "iOS"
 *     chip signalling that their content lives in the iOS app.
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
        <BrandHeader
          showSignOut
          userEmail={user.email ?? ''}
          practices={practices}
        />
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

  // Active-practice resolution order:
  //   1. Explicit `?practice=` (covered by middleware on first visit;
  //      this branch only fires inside the portal's own internal Links
  //      that propagate the param).
  //   2. `hf_active_practice` cookie set by middleware on the previous
  //      app→portal handoff. Lets a refresh / new-tab visit stay in
  //      the practice the practitioner was just acting in.
  //   3. First membership (legacy fallback for users who've never
  //      arrived here from the app).
  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value;
  const cookieFallback =
    cookiePractice && practices.some((p) => p.id === cookiePractice)
      ? cookiePractice
      : practices[0].id;
  const selectedId = params.practice ?? cookieFallback;
  const selected = practices.find((p) => p.id === selectedId) ?? practices[0];
  const qs = `?practice=${selected.id}`;

  // All dashboard inputs fetched in parallel. Role drives Members tile
  // visibility + the BrandHeader Members link. Referral stats + last
  // issuance are pre-computed so the tile copy doesn't say "loading".
  //
  // `otherBalances` pre-computes credit balances for EVERY practice the
  // caller is a member of — the switcher popover renders them as the
  // per-row disambiguator ("47 credits" / "0 credits"). Parallelised
  // so the extra membership's balance costs one round-trip, not two.
  const referralApi = new PortalReferralApi(supabase);
  const auditApi = createPortalAuditApi(supabase);
  const [
    role,
    clients,
    referralStats,
    members,
    allBalances,
    auditPreview,
    premises,
    publicProfile,
    myWorkouts,
  ] = await Promise.all([
    api.getCurrentUserRole(selected.id, user.id),
    api.listPracticeClients(selected.id),
    referralApi.dashboardStats(selected.id),
    api.listPracticeMembers(selected.id),
    Promise.all(
      practices.map(async (p) => [p.id, await api.getPracticeBalance(p.id)] as const),
    ),
    // Wave 40 P4 — dashboard audit card. Pull the 5 most-recent events
    // for the active practice; the dashboard tile renders a sage-chipped
    // mini-list and the click target routes to /audit. No filters
    // applied — the card is the engagement signal, the dedicated page
    // is for triage. Replaces the pre-Wave-40 `getLastIssuanceAt` single-
    // line "Last publish · 2 days ago" tile which surfaced no row payload.
    //
    // Dashboard rework (C-13): this same query gates the GetTheAppBanner
    // visibility — any row whose kind is `plan.publish` proves the
    // practice has published before, so the loud banner stops rendering.
    auditApi.listAudit(selected.id, { limit: 5 }),
    api.listPracticePremises(selected.id),
    // Public Profile v2 — surface the practice's branding + directory
    // readiness in the dashboard. Returns null when no row exists yet
    // (pre-v2 practices); the tile handles that with a "Not set up"
    // copy + warning tone.
    api.getPracticePublicProfile(selected.id),
    // M29 (2026-05-26) — practitioner's self-capture workouts across
    // every practice they belong to. Powers the primary-position tile.
    // No practice scoping — list_my_workouts() filters by Self-client
    // membership (clients.user_id = auth.uid()), not by practice.
    api.listMyWorkouts(),
  ]);
  const isOwner = role === 'owner';

  // Map practiceId → credits. Used both by the Credits tile (active
  // practice) and the switcher popover (per-row disambiguator).
  const balancesById: Record<string, number> = Object.fromEntries(allBalances);
  const balance = balancesById[selected.id] ?? 0;

  /* ----------------------------------------------------------------- */
  /*  Derived tile content                                              */
  /* ----------------------------------------------------------------- */

  // My Workouts (M29) — primary-position tile. Headline = count, subtitle
  // = relative time of the most-recent publish. The list is already
  // ordered by `last_published_at DESC NULLS LAST` so we pick the first
  // row's stamp; the fallback "No self-captures yet" copy fires when
  // either the count is 0 or no row has been published.
  const myWorkoutsCount = myWorkouts.length;
  const myWorkoutsRecent = myWorkouts.find((w) => w.lastPublishedAt !== null);
  const myWorkoutsHeadline =
    myWorkoutsCount === 0
      ? 'No workouts yet'
      : `${myWorkoutsCount} ${myWorkoutsCount === 1 ? 'workout' : 'workouts'}`;
  const myWorkoutsSubtitle =
    myWorkoutsCount === 0
      ? 'Record your first in the iOS app'
      : myWorkoutsRecent?.lastPublishedAt
        ? `Latest ${dashboardRelative(myWorkoutsRecent.lastPublishedAt)}`
        : 'Drafts only';

  // Credits
  const creditsLow = balance < 5;
  const creditsHeadline = `${balance} ${balance === 1 ? 'credit' : 'credits'}`;
  const creditsSubtitle = creditsLow
    ? 'Running low — top up'
    : 'Buy more';

  // Credits footer band copy (C-12 merge). The band is the entry point
  // to /network — when the practitioner has earned rebate credits the
  // copy surfaces the figure; otherwise it's a forward-leaning invite.
  const rebateBalance = referralStats.rebate_balance_credits;
  const creditsFooterCopy =
    rebateBalance > 0
      ? `+ ${fmtCredits(rebateBalance)} free earned from your network`
      : 'Earn free credits from your network';

  // Clients — "active this week" = last_plan_at within last 7 days.
  // Self-trainer wave hotfix (2026-05-25): exclude Self-clients
  // (user_id IS NOT NULL) from the dashboard tile so the count stays
  // consistent with /clients (which hides them) and the "your private
  // one-on-one clients" tile copy.
  const realClients = clients.filter((c) => c.userId === null);
  const clientCount = realClients.length;
  const now = Date.now();
  const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
  const activeThisWeek = realClients.filter((c) => {
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

  // Audit — DashboardAuditCard renders rows directly; the pre-Wave-40
  // single-line "Last publish · …" computation moved into the card's
  // empty-state fallback.

  // GetTheAppBanner gate (C-13). Show the loud install banner unless
  // the audit feed contains a `plan.publish` row. We reuse the audit
  // query the dashboard already makes — no extra round-trip. With
  // limit=5 we catch the vast majority of fresh-signup users (their
  // ledger usually contains only credit.signup_bonus on row 1);
  // returning users whose 5 most-recent events all post-date their
  // first publish naturally fall through to the "hide banner" branch.
  const hasPublished = auditPreview.rows.some(
    (r) => r.kind === 'plan.publish',
  );

  // Members (owner only)
  const memberCount = members.length;
  const membersHeadline = `${memberCount} ${memberCount === 1 ? 'practitioner' : 'practitioners'}`;
  const membersSubtitle = memberCount === 1 ? 'Invite more' : 'Manage team';

  // Premises — count + Safe Mode coverage. "Registered only" sites that
  // have safe_mode_enforced=false still count for the directory but not
  // for capture-time enforcement.
  const premisesCount = premises.length;
  const enforcedCount = premises.filter((p) => p.safeModeEnforced).length;
  const premisesHeadline =
    premisesCount === 0
      ? 'No premises'
      : `${premisesCount} ${premisesCount === 1 ? 'site' : 'sites'}`;
  const premisesSubtitle =
    premisesCount === 0
      ? 'Add a site to enable Safe Mode'
      : enforcedCount === 0
        ? 'None enforce Safe Mode'
        : `${enforcedCount} enforce Safe Mode`;

  // Public profile — directory listing + brand cascade readiness.
  // States:
  //   - no row OR no slug → "Not set up" + warning tone (the client
  //     plan URL still works, but cascade defaults to homefit coral
  //     and no /v/{slug} directory page exists).
  //   - slug + listed     → headline = slug, subtitle = "Listed in directory".
  //   - slug + !listed    → headline = slug, subtitle = "Hidden from directory".
  const profileSlug = publicProfile?.slug ?? null;
  const profileListed = publicProfile?.listed ?? false;
  const profileReady = Boolean(profileSlug);
  const publicProfileHeadline = profileReady
    ? (profileSlug as string)
    : 'Not set up';
  const publicProfileSubtitle = !profileReady
    ? 'Add a slug to claim your /v/ page'
    : profileListed
      ? 'Listed in directory'
      : 'Hidden from directory';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={selected.id}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-5xl flex-1 px-6 py-10">
        {/* C-13: install nudge for users who haven't published yet.
            Disappears automatically once `plan.publish` appears in the
            audit feed. */}
        {!hasPublished && <GetTheAppBanner />}

        {/*
          Tile inventory (post-rework 2026-05-22):
            1. Credits        — what you have to spend (footer band
                                surfaces "+ N free earned from network")
            2. Clients        — the core work surface (1:1 relationship,
                                iOS chip — content lives in the app)
            3. Classes        — coming-soon teaser (iOS chip — same)
            4. Members        — (owner only; non-owners see the row reflow)
            5. Public profile — your directory + branding face
            6. Premises       — Safe Mode geofence sites
            7. Account        — email, password, practice name
            8. Audit          — append-only history of everything above

          C-12 merge: the standalone Network tile was retired. Both
          forms of credit (bought + earned-from-network) now live on the
          Credits tile — the body links to /credits and the coral footer
          band links to /network. No nested anchors; the band is a
          sibling Link inside the card chrome.

          C-7: each tile owns two Tooltip.Roots (main + touch info) so
          popovers anchor to the hovered tile, not viewport (0,0).
          C-8: every tile carries `h-full` so row-mates equalise to the
          tallest card (usually Audit).
        */}
        <DashboardTooltipProvider>
          {/* iPhone-portrait wave 3 follow-up (2026-05-25): added
              `grid-cols-1` at base so CSS Grid uses an explicit single
              column on narrow viewports instead of falling back to the
              implicit `minmax(min-content, 1fr)` track sizing which
              expands the column to the widest child's intrinsic
              content. The implicit behaviour was forcing the dashboard
              grid (and every ancestor up to <html>) wider than the
              402px iPhone viewport. */}
          <div className="grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3">
            {/* M29 (2026-05-26) — primary-position My Workouts tile.
                Always first, above Credits, Clients, Classes. The
                practitioner-as-subject library is the most personal
                surface; surfacing it first matches the mobile IA where
                My Workouts is the always-on-launch default scope. */}
            <DashboardTile
              href={`/my-workouts${qs}`}
              label="My Workouts"
              headline={myWorkoutsHeadline}
              subtitle={myWorkoutsSubtitle}
              icon={<Dumbbell size={24} strokeWidth={1.75} aria-hidden="true" />}
              description="Workouts you've captured for yourself. View-only here — capture and editing live in the iOS app."
            />

            <DashboardTile
              href={`/credits${qs}`}
              label="Credits"
              headline={creditsHeadline}
              subtitle={creditsSubtitle}
              tone={creditsLow ? 'warning' : 'default'}
              icon={<Coins size={24} strokeWidth={1.75} aria-hidden="true" />}
              description="Buy publishing credits and see what's left. One credit publishes one plan. The coral band below shows credits earned from your network."
              footerBand={{ copy: creditsFooterCopy, href: `/network${qs}` }}
            />

            <DashboardTile
              href={`/clients${qs}`}
              label="Clients (private)"
              headline={clientsHeadline}
              subtitle={clientsSubtitle}
              icon={<UserRound size={24} strokeWidth={1.75} aria-hidden="true" />}
              description="Your private one-on-one clients. Each one gets a custom plan you build for them in the iOS app."
              requiresApp
            />

            {/*
              Classes coming-soon teaser. Mirrors the mobile app's
              coming-soon pattern (see app/lib/widgets/classes_coming_soon_view.dart).
              Non-clickable, no chevron, dimmed icon. The Radix Tooltip still
              works so practitioners can read what's coming on hover or tap.
              Visible to ALL practitioners (owners + non-owners) — not
              gated like Members. Sits adjacent to Clients per Carl's
              2026-05-22 follow-up: classes are a multi-client construct
              (one programme, many enrollees), so the pairing reads as
              "Clients (singular relationship) → Classes (group relationship)".
            */}
            <DashboardTile
              href="#"
              label="Classes (group)"
              headline="Group workouts"
              subtitle="Coming soon"
              icon={<Layers size={24} strokeWidth={1.75} aria-hidden="true" />}
              description="Group classes — build a programme once, many enrollees subscribe to follow it. Coming after MVP ships."
              comingSoon
              requiresApp
              badge="Soon"
            />

            {isOwner && (
              <DashboardTile
                href={`/members${qs}`}
                label="Members"
                headline={membersHeadline}
                subtitle={membersSubtitle}
                icon={<UsersRound size={24} strokeWidth={1.75} aria-hidden="true" />}
                description="Add or remove practitioners in your practice. Owners can also rename the practice."
              />
            )}

            {/*
              Public profile (v2) — branding + directory listing entry.
              Warning tone when no slug claimed: the client-plan URL still
              renders, but cascades fall back to homefit coral and there's
              no /v/{slug} page in the directory yet.
            */}
            <DashboardTile
              href={`/public-profile${qs}`}
              label="Public profile"
              headline={publicProfileHeadline}
              subtitle={publicProfileSubtitle}
              tone={profileReady ? 'default' : 'warning'}
              icon={<Globe2 size={24} strokeWidth={1.75} aria-hidden="true" />}
              description="Your /v/{slug} directory page — branding, cover, and whether prospective clients can find you."
            />

            <DashboardTile
              href={`/premises${qs}`}
              label="Premises"
              headline={premisesHeadline}
              subtitle={premisesSubtitle}
              icon={<Building2 size={24} strokeWidth={1.75} aria-hidden="true" />}
              description="Sites you train at. Enforcing Safe Mode at a site automatically blurs bystanders when you capture there."
            />

            <DashboardTile
              href={`/account${qs}`}
              label="Account"
              headline="Settings"
              subtitle="Email, password, practice name"
              icon={<Settings size={24} strokeWidth={1.75} aria-hidden="true" />}
              description="Your email, password, and the active practice's name."
            />

            <DashboardAuditCard
              href={`/audit${qs}`}
              rows={auditPreview.rows}
              error={auditPreview.error}
              icon={<ScrollText size={24} strokeWidth={1.75} aria-hidden="true" />}
              description="Append-only log of every publish, purchase, and consent change in your practice."
            />
          </div>
        </DashboardTooltipProvider>
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
 * M29 (2026-05-26) — compact relative-time formatter for the My
 * Workouts dashboard tile subtitle. Falls back to "recently" for any
 * invalid ISO. Keeps the chrome tight ("Latest 3d ago") to fit the
 * one-line subtitle constraint.
 */
function dashboardRelative(iso: string): string {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return 'recently';
  const delta = Date.now() - t;
  if (delta < 60_000) return 'just now';
  const minutes = Math.round(delta / 60_000);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days}d ago`;
  const months = Math.round(days / 30);
  if (months < 12) return `${months}mo ago`;
  return `${Math.round(months / 12)}y ago`;
}
