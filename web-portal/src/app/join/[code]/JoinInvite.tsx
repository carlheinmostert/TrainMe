'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalMembersApi,
  MembersError,
} from '@/lib/supabase/api';

type Props = {
  /** Normalized upper-case invite code. */
  code: string;
};

/**
 * Client-side claim button for `/join/[code]`.
 *
 * The RPC is SECURITY DEFINER but it inspects `auth.uid()`, so it has to
 * run under the authenticated browser session (not the server component
 * cookie context, though those produce the same claim — we keep the
 * client path for parity with the referral `/r/{code}` claim behavior
 * and to give the user an explicit "Join" click rather than an
 * auto-claim side effect).
 *
 * Success: redirect to `/dashboard?practice={practiceId}` so the user
 * lands in their new practice context immediately.
 *
 * Failure: inline error message. Common paths:
 *   - `not-found` (P0002) → "Invite code is invalid or has already been
 *     claimed." This covers expired, revoked, or double-claim cases.
 *   - `invalid`   (22023) → surfaces the raw DB message.
 *   - `auth`      (28000) → session expired; bounce to sign-in.
 */
export function JoinInvite({ code }: Props) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function handleClaim() {
    startTransition(async () => {
      setError(null);
      try {
        const supabase = getBrowserClient();
        const api = createPortalMembersApi(supabase);
        const { practiceId } = await api.claimInvite(code);
        // Hard navigation so the new practice_members row is picked up
        // by every downstream server component read on the next page
        // (SSR cached RLS reads otherwise).
        window.location.assign(`/dashboard?practice=${practiceId}`);
      } catch (e) {
        setError(mapError(e));
      }
    });
  }

  return (
    <div className="mt-8 space-y-4">
      <div className="rounded-lg border border-surface-border bg-surface-base p-5">
        <p className="text-xs uppercase tracking-wider text-ink-muted">
          Invite code
        </p>
        <p className="mt-1 font-mono text-lg font-semibold text-ink">
          {code}
        </p>
      </div>

      <div className="flex flex-col items-stretch gap-3 sm:flex-row sm:items-center">
        <button
          type="button"
          onClick={handleClaim}
          disabled={pending}
          className="inline-flex items-center justify-center rounded-md bg-brand px-6 py-3 text-base font-semibold text-surface-bg transition hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-60 focus-visible:shadow-focus-ring"
        >
          {pending ? 'Joining…' : 'Join as practitioner'}
        </button>
        <p className="text-xs text-ink-dim">
          You&rsquo;ll become a{' '}
          <span className="font-semibold text-ink-muted">practitioner</span>{' '}
          in the inviting practice. You can leave at any time from the
          Members page.
        </p>
      </div>

      {error && (
        <p
          role="alert"
          className="rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error"
        >
          {error}
        </p>
      )}

      {/* Manual back-out lives at the bottom of the page. If the user
          lands here by mistake they can dashboard-bounce without
          hitting any destructive action. */}
      <button
        type="button"
        onClick={() => router.push('/dashboard')}
        className="text-xs font-semibold uppercase tracking-wider text-ink-muted transition hover:text-ink"
      >
        Not now
      </button>
    </div>
  );
}

function mapError(e: unknown): string {
  if (e instanceof MembersError) {
    switch (e.kind) {
      case 'not-found':
        return 'This invite code is invalid or has already been used.';
      case 'invalid':
        return e.message;
      case 'auth':
        return 'Your session expired. Sign in again to accept the invite.';
      default:
        return e.message;
    }
  }
  return e instanceof Error ? e.message : 'Something went wrong.';
}
