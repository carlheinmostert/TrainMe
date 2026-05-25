'use client';

import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  SafeModeSubscriptionError,
  type SafeModeSubscriptionResult,
} from '@/lib/supabase/api';

type Props = {
  practiceId: string;
  initialBalance: number;
};

/**
 * Single-CTA Subscribe form for the Safe Mode subscription page.
 *
 * Calls `start_safe_mode_subscription(practiceId)` via PortalApi.
 * Renders three states:
 *
 *   * idle — large coral CTA "Subscribe · 4 credits / month · 3-day
 *     free trial on first sub". Shows current balance.
 *   * submitting — disabled CTA with spinner.
 *   * success — green confirmation panel, new balance, link back to
 *     the dashboard.
 *   * insufficient credits — friendly error + link to /credits.
 *   * unexpected error — generic message + retry CTA.
 *
 * On success the page refreshes the server-component snapshot so the
 * "Your Safe Mode access is active" banner takes over without a hard
 * reload.
 *
 * Wave: Self-trainer PR #8.
 */
export function SafeModeSubscribeForm({ practiceId, initialBalance }: Props) {
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<SafeModeSubscriptionResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const router = useRouter();

  const onSubmit = async () => {
    if (submitting) return;
    setSubmitting(true);
    setError(null);
    try {
      const supabase = getBrowserClient();
      const portal = createPortalApi(supabase);
      const res = await portal.startSafeModeSubscription(practiceId);
      setResult(res);
      if (res.ok) {
        // Pull a fresh server-side snapshot so the parent page re-renders
        // with the "Your Safe Mode access is active" banner.
        router.refresh();
      }
    } catch (e) {
      const msg = e instanceof SafeModeSubscriptionError
        ? e.message
        : 'Subscription failed. Try again shortly.';
      setError(msg);
    } finally {
      setSubmitting(false);
    }
  };

  if (result?.ok) {
    return (
      <div className="mt-8 rounded-2xl border border-success/40 bg-success/5 p-6">
        <p className="text-base font-semibold text-success">
          Safe Mode subscribed.
        </p>
        <p className="mt-2 text-sm text-ink-muted">
          New credit balance: <span className="text-ink">{result.newBalance}</span>.
          You can capture inside enforcing premises right now. We&rsquo;ll
          send a reminder when the month is close to ending.
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

  if (result?.ok === false && result.reason === 'insufficient_credits') {
    return (
      <div className="mt-8 rounded-2xl border border-warning/40 bg-warning/5 p-6">
        <p className="text-base font-semibold text-warning">
          Not enough credits.
        </p>
        <p className="mt-2 text-sm text-ink-muted">
          Your practice has {result.balance} credit
          {result.balance === 1 ? '' : 's'}; the subscription costs 4.
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
        onClick={onSubmit}
        disabled={submitting}
        className="w-full rounded-2xl bg-brand px-6 py-4 text-base font-semibold text-surface-bg shadow transition hover:bg-brand-dark disabled:cursor-not-allowed disabled:opacity-60"
      >
        {submitting
          ? 'Subscribing…'
          : 'Subscribe · 4 credits / month · 3-day free trial on first sub'}
      </button>
      <p className="text-xs text-ink-muted">
        We&rsquo;ll debit 4 credits from this practice&rsquo;s balance. No
        auto-renewal &mdash; the subscription lasts 30 days, and
        we&rsquo;ll notify you before it ends.
      </p>
      {error ? (
        <p className="text-sm font-semibold text-brand">{error}</p>
      ) : null}
    </div>
  );
}
