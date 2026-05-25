import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import type { Metadata } from 'next';
import { getServerClient } from '@/lib/supabase-server';
import { createPortalApi } from '@/lib/supabase/api';
import { BrandHeader } from '@/components/BrandHeader';
import { ACTIVE_PRACTICE_COOKIE } from '@/lib/active-practice';
import { SafeModeSubscribeForm } from './SafeModeSubscribeForm';

export const metadata: Metadata = {
  title: 'Safe Mode subscription — homefit.studio',
  description:
    'Subscribe to Safe Mode capture inside enforcing premises. 4 credits / month, 3-day free trial on first sub.',
};

type SearchParams = { practice?: string };

/**
 * `/safe-mode/subscribe` — server-rendered shell that resolves the
 * active practice + ownership status, then mounts a client component
 * for the single Subscribe CTA.
 *
 * Per ADR-0021 / Reader-App compliance, the mobile app NEVER shows a
 * price or Subscribe button — it deep-links to THIS page when a user
 * tries to capture inside an enforcing geofence without an active
 * sub. This page is the canonical place a Safe Mode subscription is
 * purchased.
 *
 * Resolution order for the active practice mirrors `/credits`:
 *   1. `?practice=<uuid>` from a portal Link.
 *   2. The `hf_active_practice` cookie set by middleware on the
 *      most-recent app→portal handoff.
 *
 * Owner-only — the `start_safe_mode_subscription` RPC enforces
 * membership; we add this UI-level gate so a non-owner sees a
 * helpful message instead of the bare "insufficient permission"
 * error from the RPC.
 *
 * Wave: Self-trainer PR #8 (2026-05-25). Brief:
 * docs/sub-agent-briefs/08-safe-mode-subscription-gate.md.
 */
export default async function SafeModeSubscribePage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/?next=/safe-mode/subscribe');

  const params = await searchParams;
  const cookieStore = await cookies();
  const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? '';
  const practiceId = params.practice ?? cookiePractice;

  const portal = createPortalApi(supabase);
  const [role, practices, balance, hasActiveSub] = await Promise.all([
    practiceId
      ? portal.getCurrentUserRole(practiceId, user.id)
      : Promise.resolve(null),
    portal.listMyPractices(),
    practiceId ? portal.getPracticeBalance(practiceId) : Promise.resolve(0),
    portal.getSafeModeSubStatus(),
  ]);

  const isOwner = role === 'owner';

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader
        showSignOut
        practiceId={practiceId}
        isOwner={isOwner}
        userEmail={user.email ?? ''}
        practices={practices}
      />
      <div className="mx-auto w-full max-w-2xl flex-1 px-6 py-10">
        <h1 className="font-heading text-3xl font-bold">
          Safe Mode subscription
        </h1>
        <p className="mt-3 text-base leading-relaxed text-ink">
          Capture inside enforcing premises (gyms, group sessions) needs
          an active Safe Mode subscription. 4 credits / month, billed
          from your practice&rsquo;s credit balance.
        </p>

        {hasActiveSub ? (
          <div className="mt-8 rounded-2xl border border-success/40 bg-success/5 p-6">
            <p className="text-base font-semibold text-success">
              Your Safe Mode access is active.
            </p>
            <p className="mt-2 text-sm text-ink-muted">
              You can capture in enforcing premises right now. We&rsquo;ll
              renew nothing automatically &mdash; we&rsquo;ll send a
              reminder when your current month is close to ending.
            </p>
          </div>
        ) : !practiceId ? (
          <p className="mt-8 text-sm text-warning">
            Pick a practice in the header above first, then come back here
            to subscribe.
          </p>
        ) : !isOwner ? (
          <p className="mt-8 text-sm text-warning">
            Only the practice owner can subscribe. Ask them to visit this
            page from their account.
          </p>
        ) : (
          <SafeModeSubscribeForm
            practiceId={practiceId}
            initialBalance={balance}
          />
        )}

        <section className="mt-12 space-y-4 text-sm leading-relaxed text-ink-muted">
          <h2 className="font-heading text-base font-semibold text-ink">
            What you get
          </h2>
          <ul className="list-disc space-y-2 pl-5">
            <li>
              30 days of unlimited capture inside any practice premises
              you have access to.
            </li>
            <li>
              Bystanders blurred on-device, before the file leaves the
              phone &mdash; your client stays sharp.
            </li>
            <li>
              First subscription includes a 3-day free trial. You can
              cancel any time by simply not renewing &mdash; we never
              auto-bill.
            </li>
            <li>
              Captures you&rsquo;ve already made stay accessible forever,
              even after a subscription lapses.
            </li>
          </ul>
        </section>
      </div>
    </main>
  );
}
