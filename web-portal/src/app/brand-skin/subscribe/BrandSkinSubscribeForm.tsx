'use client';

import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  BrandSkinSubscriptionError,
  type BrandSkinSubscriptionResult,
  type BrandSkinTrialResult,
} from '@/lib/supabase/api';

type Props = {
  practiceId: string;
  initialBalance: number;
  /**
   * True if no active subscription exists for this practice — we offer
   * the free trial CTA. False if the practice has lapsed past grace OR
   * is renewing inside the grace window — we go straight to the paid
   * debit CTA.
   *
   * If the trial RPC returns `trial_already_used`, the form falls
   * through to the paid CTA automatically without a page reload.
   */
  offerTrial: boolean;
};

/**
 * Brand-skin subscribe flow. Two CTAs depending on `offerTrial`:
 *
 *   * Trial path — call startBrandSkinTrial. If it succeeds, show
 *     "Trial active for 30 days" success. If it returns
 *     trial_already_used, automatically fall through to the paid CTA.
 *   * Paid path — call startBrandSkinSubscription. Same UX as the
 *     Safe Mode form (success / insufficient-credits / error).
 *
 * Owner-only is enforced upstream in the server component; this client
 * form trusts the surrounding gate.
 *
 * Wave: Artifact-system Wave 4 / ADR-0029.
 */
export function BrandSkinSubscribeForm({
  practiceId,
  initialBalance,
  offerTrial,
}: Props) {
  const [submitting, setSubmitting] = useState(false);
  const [paidResult, setPaidResult] =
    useState<BrandSkinSubscriptionResult | null>(null);
  const [trialResult, setTrialResult] =
    useState<BrandSkinTrialResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  // After a trial_already_used response we fall through to the paid
  // CTA without forcing the user to refresh. Tracks that state.
  const [forcePaid, setForcePaid] = useState(false);
  const router = useRouter();

  const inTrialBranch = offerTrial && !forcePaid;

  const onSubmitTrial = async () => {
    if (submitting) return;
    setSubmitting(true);
    setError(null);
    try {
      const supabase = getBrowserClient();
      const portal = createPortalApi(supabase);
      const res = await portal.startBrandSkinTrial(practiceId);
      setTrialResult(res);
      if (res.ok) {
        router.refresh();
      } else if (res.reason === 'trial_already_used') {
        // Past trial — switch the form to the paid CTA without forcing a
        // page reload. The button below now reads "Subscribe · 4 credits
        // / month" and clicking it calls startBrandSkinSubscription.
        setForcePaid(true);
      }
    } catch (e) {
      const msg =
        e instanceof BrandSkinSubscriptionError
          ? e.message
          : 'Could not start trial. Try again shortly.';
      setError(msg);
    } finally {
      setSubmitting(false);
    }
  };

  const onSubmitPaid = async () => {
    if (submitting) return;
    setSubmitting(true);
    setError(null);
    try {
      const supabase = getBrowserClient();
      const portal = createPortalApi(supabase);
      const res = await portal.startBrandSkinSubscription(practiceId);
      setPaidResult(res);
      if (res.ok) {
        router.refresh();
      }
    } catch (e) {
      const msg =
        e instanceof BrandSkinSubscriptionError
          ? e.message
          : 'Subscription failed. Try again shortly.';
      setError(msg);
    } finally {
      setSubmitting(false);
    }
  };

  // Trial success.
  if (trialResult?.ok) {
    return (
      <div className="mt-8 rounded-2xl border border-success/40 bg-success/5 p-6">
        <p className="text-base font-semibold text-success">
          Brand-skin trial started.
        </p>
        <p className="mt-2 text-sm text-ink-muted">
          Your handouts will render in your brand for the next 30 days at
          no cost. We&rsquo;ll remind you before day 31; if you do
          nothing the subscription renews itself only if you confirm.
        </p>
        <Link
          href={`/dashboard?practice=${practiceId}`}
          className="mt-4 inline-block text-sm font-semibold text-brand hover:underline"
        >
          Back to dashboard
        </Link>
      </div>
    );
  }

  // Paid success.
  if (paidResult?.ok) {
    return (
      <div className="mt-8 rounded-2xl border border-success/40 bg-success/5 p-6">
        <p className="text-base font-semibold text-success">
          Brand-skin subscribed.
        </p>
        <p className="mt-2 text-sm text-ink-muted">
          New credit balance:{' '}
          <span className="text-ink">{paidResult.newBalance}</span>. Your
          handouts render in your brand for the next 30 days; we&rsquo;ll
          remind you before the cycle ends.
        </p>
        <Link
          href={`/dashboard?practice=${practiceId}`}
          className="mt-4 inline-block text-sm font-semibold text-brand hover:underline"
        >
          Back to dashboard
        </Link>
      </div>
    );
  }

  // Insufficient credits.
  if (paidResult?.ok === false && paidResult.reason === 'insufficient_credits') {
    return (
      <div className="mt-8 rounded-2xl border border-warning/40 bg-warning/5 p-6">
        <p className="text-base font-semibold text-warning">
          Not enough credits.
        </p>
        <p className="mt-2 text-sm text-ink-muted">
          Your practice has {paidResult.balance} credit
          {paidResult.balance === 1 ? '' : 's'}; the subscription costs 4.
          Top up and try again.
        </p>
        <Link
          href={`/credits?practice=${practiceId}`}
          className="mt-4 inline-block rounded-full bg-brand px-5 py-2 text-sm font-semibold text-surface-bg shadow hover:bg-brand-dark"
        >
          Buy credits
        </Link>
      </div>
    );
  }

  return (
    <div className="mt-8 space-y-4">
      <div className="rounded-2xl border border-surface-border bg-surface-base p-6">
        <p className="text-sm text-ink-muted">Current credit balance</p>
        <p className="mt-1 text-2xl font-bold text-ink">{initialBalance}</p>
      </div>
      <button
        type="button"
        onClick={inTrialBranch ? onSubmitTrial : onSubmitPaid}
        disabled={submitting}
        className="w-full rounded-2xl bg-brand px-6 py-4 text-base font-semibold text-surface-bg shadow transition hover:bg-brand-dark disabled:cursor-not-allowed disabled:opacity-60"
      >
        {submitting
          ? inTrialBranch
            ? 'Starting trial…'
            : 'Subscribing…'
          : inTrialBranch
            ? 'Try free for 30 days'
            : 'Subscribe · 4 credits / month'}
      </button>
      <p className="text-xs text-ink-muted">
        {inTrialBranch
          ? 'We won’t debit any credits today. The 30-day trial covers a full cycle; we’ll send a reminder before day 31.'
          : 'We’ll debit 4 credits from this practice’s balance. No auto-renewal — the subscription lasts 30 days. Check back here on or before the expiry date to renew.'}
      </p>
      {forcePaid && trialResult && !trialResult.ok ? (
        <p className="text-xs text-ink-muted">
          This practice has already used its free trial. The button above
          starts a paid subscription instead.
        </p>
      ) : null}
      {error ? (
        <p className="text-sm font-semibold text-brand">{error}</p>
      ) : null}
    </div>
  );
}
