import Link from 'next/link';
import { redirect } from 'next/navigation';
import { createClient } from '@supabase/supabase-js';
import { getServerClient } from '@/lib/supabase-server';
import { BrandHeader } from '@/components/BrandHeader';
import { isSandboxEnabled } from '@/lib/payfast';

type SearchParams = { pid?: string; practice?: string };

// PayFast redirects the buyer here after a successful payment. In production
// credits are applied by the ITN webhook (server-to-server), which is the
// authoritative path and preserves the 4-gate authenticity check.
//
// Sandbox wrinkle: PayFast's shared sandbox does not fire ITNs automatically,
// and even a custom sandbox merchant sometimes fails to deliver them. To keep
// end-to-end testing unblocked WITHOUT weakening production, we expose an
// explicit opt-in flag `PAYFAST_SANDBOX_OPTIMISTIC=true` that lets THIS page
// (on buyer bounce-back) promote a `pending_payments` row to complete and
// write the `credit_ledger` purchase row itself.
//
// Guards:
//   • PAYFAST_SANDBOX must be true  (production never takes this path)
//   • PAYFAST_SANDBOX_OPTIMISTIC must be explicitly true
//   • The `pid` must exist in pending_payments and match this user's practice
//   • The row must still be `status = 'pending'` — idempotent re-lands are a no-op
// Any failure is swallowed silently; the page still renders its confirmation UI
// and the real ITN (if it eventually arrives) is idempotent in the webhook.
async function maybeApplyOptimisticSandboxCredit(
  userId: string,
  pid: string,
): Promise<{ applied: boolean; credits?: number; reason?: string }> {
  const sandbox = isSandboxEnabled();
  const optimistic = (process.env.PAYFAST_SANDBOX_OPTIMISTIC ?? '').toLowerCase() === 'true';
  if (!sandbox || !optimistic) return { applied: false, reason: 'disabled' };

  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const supabaseUrl =
    process.env.NEXT_PUBLIC_SUPABASE_URL ??
    'https://yrwcofhovrcydootivjx.supabase.co';
  if (!serviceRoleKey) return { applied: false, reason: 'no service role' };

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Look up the pending payment by its id (= the PayFast m_payment_id we sent).
  const { data: pending, error: lookupErr } = await admin
    .from('pending_payments')
    .select('id, practice_id, credits, amount_zar, status, bundle_key')
    .eq('id', pid)
    .maybeSingle();
  if (lookupErr || !pending) return { applied: false, reason: 'lookup failed' };

  // Idempotent — if another signal already completed it, bail.
  if (pending.status !== 'pending') {
    return { applied: false, reason: `already ${pending.status}` };
  }

  // Authorisation — the signed-in user must actually belong to the practice
  // this payment was issued for. Uses the anon JWT's membership row.
  const { data: membership } = await admin
    .from('practice_members')
    .select('practice_id')
    .eq('practice_id', pending.practice_id)
    .eq('trainer_id', userId)
    .maybeSingle();
  if (!membership) return { applied: false, reason: 'not a member' };

  // Apply: insert the ledger row, then mark the intent complete. If the ledger
  // insert fails we leave status='pending' so a retry / real ITN can still land.
  const { error: ledgerErr } = await admin.from('credit_ledger').insert({
    practice_id: pending.practice_id,
    delta: pending.credits,
    type: 'purchase',
    payfast_payment_id: null, // no real pf_payment_id in sandbox-optimistic path
    notes: `sandbox-optimistic purchase of ${pending.credits} credits via pending_payment ${pending.id}`,
  });
  if (ledgerErr) return { applied: false, reason: ledgerErr.message };

  await admin
    .from('pending_payments')
    .update({
      status: 'complete',
      notes: 'applied optimistically on /credits/return (sandbox only)',
      completed_at: new Date().toISOString(),
    })
    .eq('id', pending.id)
    .eq('status', 'pending'); // belt-and-suspenders against a race with the ITN
  return { applied: true, credits: pending.credits };
}

export default async function CreditsReturnPage({
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
  const practiceId = params.practice ?? '';

  let appliedSandboxCredits: number | undefined;
  if (params.pid) {
    const result = await maybeApplyOptimisticSandboxCredit(user.id, params.pid);
    if (result.applied) appliedSandboxCredits = result.credits;
  }

  return (
    <main className="flex min-h-screen flex-col">
      <BrandHeader showSignOut />
      <div className="mx-auto w-full max-w-2xl flex-1 px-6 py-16">
        <div className="rounded-lg border border-brand/40 bg-brand/10 p-8 text-center">
          <h1 className="font-heading text-2xl font-bold text-brand">
            Payment received
          </h1>
          <p className="mt-3 text-sm text-ink">
            {appliedSandboxCredits
              ? `Thanks — ${appliedSandboxCredits} credits have been added to your practice (sandbox mode).`
              : 'Thanks — PayFast has acknowledged your payment. Your credits will appear on your dashboard as soon as we receive PayFast\u2019s confirmation notification (usually within a few seconds).'}
          </p>
          {params.pid && (
            <p className="mt-4 text-xs text-ink-dim">
              Reference: <code className="font-mono">{params.pid}</code>
            </p>
          )}
          <div className="mt-8 flex justify-center gap-3">
            <Link
              href={
                practiceId
                  ? `/dashboard?practice=${practiceId}`
                  : '/dashboard'
              }
              className="rounded-md bg-brand px-5 py-2.5 text-sm font-semibold text-surface-bg transition hover:bg-brand-light"
            >
              Back to dashboard
            </Link>
            <Link
              href={
                practiceId ? `/credits?practice=${practiceId}` : '/credits'
              }
              className="rounded-md border border-surface-border px-5 py-2.5 text-sm font-semibold text-ink transition hover:border-brand"
            >
              Buy another bundle
            </Link>
          </div>
        </div>
      </div>
    </main>
  );
}
