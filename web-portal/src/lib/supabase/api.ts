import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database, Tables, TablesInsert } from './database.types';

/**
 * Supabase-js v2.103 declares `SupabaseClient` with five generic slots
 * (Database, SchemaNameOrClientOptions, SchemaName, Schema, ClientOptions),
 * while `@supabase/ssr` 0.5.x still uses the three-slot legacy signature
 * (Database, SchemaName, Schema) when returning from `createServerClient`
 * / `createBrowserClient`. The two resolved shapes are structurally
 * compatible at runtime but TypeScript reports them as distinct. We
 * accept a loose `SupabaseClient<Database, any, any>` here so the
 * wrappers below don't care which factory built the client — a fine
 * trade since all methods exercise `supabase.from(...)` / `supabase.rpc(...)`
 * which have Database-wide type guarantees regardless of the outer
 * generics shape.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type CompatSupabase = SupabaseClient<Database, any, any>;

/**
 * homefit.studio — Web Portal data-access layer
 * =============================================
 * The ONE file that enumerates every Supabase operation the Next.js web
 * portal is allowed to perform. Pages and route handlers MUST route all
 * queries through this module — direct `supabase.from(...)`, `supabase.rpc(...)`
 * etc. are a layering violation (see `docs/DATA_ACCESS_LAYER.md`).
 *
 * Why a class per client? We have two Supabase clients in the portal:
 *   - `getServerClient()` — RLS-bound, cookie-authed, for server components
 *     and route handlers.
 *   - `getBrowserClient()` — client-side auth and RPC calls from Client
 *     Components.
 * Rather than duplicate method signatures, we parameterise a single
 * `PortalApi` over whichever `SupabaseClient<Database>` instance the
 * caller already has.
 *
 * ## Type safety
 *
 * The Database generic flows from `database.types.ts`, which is generated
 * from the live Supabase schema via:
 *
 *     supabase gen types typescript --linked --schema public \
 *       > web-portal/src/lib/supabase/database.types.ts
 *
 * That means RPC parameter names are a COMPILE-TIME contract. Today's
 * `plan_id` → `p_plan_id` rename would have surfaced as a TS error here
 * instead of a silent runtime 500.
 *
 * Regenerate the types after every migration that changes schema. See
 * docs/DATA_ACCESS_LAYER.md → "How to add a new RPC".
 *
 * ## What's NOT here
 *
 * - Service-role writes from the PayFast ITN webhook — that code path
 *   lives in `supabase/functions/payfast-webhook` and the sandbox-
 *   optimistic helper at `src/app/credits/return/page.tsx` uses the
 *   service role separately. Neither is part of the anon/authenticated
 *   client surface this file enumerates; they bypass RLS by design.
 * - `supabase.auth.*` convenience reads like `getUser()` — they stay
 *   inline at the callsite because the session cookie check is
 *   page-scoped flow control, not a business operation.
 */

export type PracticeWithRole = {
  id: string;
  name: string;
  role: 'owner' | 'practitioner';
};

export type PlanIssuanceRow = {
  id: string;
  created_at: string;
  credits_charged: number | null;
  trainer_id: string | null;
  plan_url: string | null;
  plans: { title: string | null } | { title: string | null }[] | null;
};

export type MemberRow = {
  trainer_id: string;
  role: 'owner' | 'practitioner';
  joined_at: string;
};

/**
 * PortalApi wraps a `SupabaseClient<Database>` with the enumerated
 * operations the portal surface is permitted to perform. Construct via
 * the helpers at the bottom of this module; never `new PortalApi(...)`
 * with a raw client the page created inline.
 */
export class PortalApi {
  constructor(private readonly supabase: CompatSupabase) {}

  // ==========================================================================
  // Practice membership
  // ==========================================================================

  /**
   * List the practices the signed-in user is a member of.
   *
   * RLS (Milestone C, helper-fn rewrite): `practice_members` is limited to
   * rows where `trainer_id = auth.uid()`. No extra filter needed — if the
   * caller is signed in, they only see their own memberships.
   *
   * The nested `practices` join can be either a single row or an array
   * depending on PostgREST's mood — we normalise to a single object here
   * so every caller receives `PracticeWithRole[]`.
   */
  async listMyPractices(): Promise<PracticeWithRole[]> {
    const { data, error } = await this.supabase
      .from('practice_members')
      .select('role, practice_id, practices:practice_id ( id, name )')
      .order('joined_at', { ascending: true });

    if (error || !data) return [];

    return data
      .map((row) => {
        const practice = Array.isArray(row.practices)
          ? row.practices[0]
          : row.practices;
        if (!practice) return null;
        return {
          id: practice.id as string,
          name: practice.name as string,
          role: row.role as 'owner' | 'practitioner',
        };
      })
      .filter((p): p is PracticeWithRole => p !== null);
  }

  /**
   * List members of a specific practice. RLS restricts visibility to
   * members of any practice the caller belongs to (helper fn
   * `user_practice_ids()`), so a call for a foreign practice silently
   * returns `[]` — which is the same shape as "no members found".
   */
  async listPracticeMembers(practiceId: string): Promise<MemberRow[]> {
    const { data, error } = await this.supabase
      .from('practice_members')
      .select('trainer_id, role, joined_at')
      .eq('practice_id', practiceId)
      .order('joined_at', { ascending: true });

    if (error || !data) return [];
    return data as MemberRow[];
  }

  /**
   * Membership check for the current user on a specific practice. Used
   * by the members page to decide whether to show the Invite UI, and by
   * the purchase route to gate `pending_payments` inserts.
   */
  async getCurrentUserRole(
    practiceId: string,
    userId: string,
  ): Promise<'owner' | 'practitioner' | null> {
    const { data } = await this.supabase
      .from('practice_members')
      .select('role')
      .eq('practice_id', practiceId)
      .eq('trainer_id', userId)
      .maybeSingle();
    return (data?.role as 'owner' | 'practitioner' | undefined) ?? null;
  }

  /**
   * Membership existence check — convenience that resolves to true/false
   * instead of the role. Used by the PayFast purchase route as the pre-
   * insert guard on `pending_payments`.
   */
  async isUserInPractice(
    practiceId: string,
    userId: string,
  ): Promise<boolean> {
    const role = await this.getCurrentUserRole(practiceId, userId);
    return role !== null;
  }

  // ==========================================================================
  // Credits + billing
  // ==========================================================================

  /**
   * `practice_credit_balance(p_practice_id)` — SECURITY DEFINER fn that
   * returns SUM(delta) over `credit_ledger` for the practice.
   *
   * Returns `0` for any error so callers can treat the result as display-
   * safe. Reduced observability is intentional for MVP; add structured
   * logging if/when this moves to an RPC that needs stricter error
   * surfacing.
   */
  async getPracticeBalance(practiceId: string): Promise<number> {
    const { data, error } = await this.supabase.rpc('practice_credit_balance', {
      p_practice_id: practiceId,
    });
    if (error || data === null) return 0;
    return typeof data === 'number' ? data : 0;
  }

  // ==========================================================================
  // Audit
  // ==========================================================================

  /**
   * Recent plan issuances for a practice. Used by the /audit page. Limit
   * is hardcoded at 50 — the portal currently has no paging UI; when that
   * lands, add `offset` + `limit` args here and in the corresponding
   * page handler.
   *
   * TODO(MVP): `auth.users` join is deferred until the `public.trainers`
   * view ships; the caller renders the trainer uuid until then. Same
   * caveat as the pre-refactor code — see inline comment in that page.
   */
  async listRecentIssuances(
    practiceId: string,
    limit = 50,
  ): Promise<PlanIssuanceRow[]> {
    const { data, error } = await this.supabase
      .from('plan_issuances')
      .select(
        'id, created_at, credits_charged, trainer_id, plan_url, plans:plan_id ( title )',
      )
      .eq('practice_id', practiceId)
      .order('created_at', { ascending: false })
      .limit(limit);

    if (error || !data) return [];
    return data as unknown as PlanIssuanceRow[];
  }
}

// ============================================================================
// Admin (service-role) carve-out
// ============================================================================
//
// The PayFast checkout + sandbox-optimistic flows need to write to
// `pending_payments` and `credit_ledger`, which the anon session can't
// reach (RLS denies + pending_payments has no INSERT policy at all).
// Those writes happen via a service-role client created inline at the
// callsite today. We expose a typed admin surface here so route handlers
// can switch to it without re-learning the column shapes every time.
//
// IMPORTANT: never instantiate `AdminApi` with a non-service-role client.
// The type system can't enforce that, so the factory `createAdminApi`
// takes the key explicitly and refuses to construct without it.

export type PendingPaymentInsert = TablesInsert<'pending_payments'>;
export type CreditLedgerInsert = TablesInsert<'credit_ledger'>;
export type PendingPaymentRow = Tables<'pending_payments'>;

export class AdminApi {
  constructor(private readonly supabase: CompatSupabase) {}

  /**
   * Insert a new `pending_payments` row — the server-side intent that
   * the PayFast ITN webhook matches against. Runs as service role so it
   * bypasses RLS (the table has no INSERT policy for anon/authenticated).
   */
  async insertPendingPayment(row: PendingPaymentInsert): Promise<void> {
    const { error } = await this.supabase.from('pending_payments').insert(row);
    if (error) throw new Error(error.message);
  }

  /**
   * Look up a pending payment by its id (= the PayFast m_payment_id we
   * sent). Returns null when not found; callers decide the UX.
   */
  async findPendingPayment(pid: string): Promise<PendingPaymentRow | null> {
    const { data } = await this.supabase
      .from('pending_payments')
      .select(
        'id, practice_id, credits, amount_zar, status, bundle_key, pf_payment_id, notes, completed_at, created_at',
      )
      .eq('id', pid)
      .maybeSingle();
    return (data as PendingPaymentRow | null) ?? null;
  }

  /**
   * Sandbox-optimistic credit apply (only triggered when the sandbox
   * env flag is set — see the callsite in `credits/return/page.tsx`).
   * Inserts a ledger row and flips the intent to `complete` in a
   * compensatable pair of writes. Returns whether the ledger row was
   * written; caller is responsible for the race-check on `status`.
   */
  async applyPendingPayment(
    pid: string,
    ledgerRow: CreditLedgerInsert,
  ): Promise<{ applied: boolean; reason?: string }> {
    const { error: ledgerErr } = await this.supabase
      .from('credit_ledger')
      .insert(ledgerRow);
    if (ledgerErr) return { applied: false, reason: ledgerErr.message };

    await this.supabase
      .from('pending_payments')
      .update({
        status: 'complete',
        notes: 'applied optimistically on /credits/return (sandbox only)',
        completed_at: new Date().toISOString(),
      })
      .eq('id', pid)
      .eq('status', 'pending'); // belt-and-suspenders vs. race with real ITN

    return { applied: true };
  }

  /**
   * Sandbox-optimistic credit apply with referral rebate awareness.
   * Mirrors the PayFast ITN webhook by routing through the
   * `record_purchase_with_rebates` SECURITY DEFINER RPC, so the sandbox
   * path also produces the +10/+10 signup bonus on first purchase and
   * the 5% lifetime credit rebate on every subsequent purchase —
   * atomically with the purchase row, in a single DB transaction.
   *
   * Use this in place of `applyPendingPayment` whenever the referral
   * loop should fire. The plain `applyPendingPayment` is preserved for
   * legacy / non-rebate-aware callers.
   */
  async applyPendingPaymentWithRebates(
    pid: string,
    args: {
      practice_id: string;
      credits: number;
      amount_zar: number;
      bundle_key: string | null;
      cost_per_credit_zar: number;
    },
  ): Promise<{ applied: boolean; reason?: string }> {
    const { error: ledgerErr } = await this.supabase.rpc(
      'record_purchase_with_rebates',
      {
        p_practice_id: args.practice_id,
        p_credits: args.credits,
        p_amount_zar: args.amount_zar,
        p_payfast_payment_id: null, // sandbox-optimistic has no real pf_payment_id
        p_bundle_key: args.bundle_key,
        p_cost_per_credit_zar: args.cost_per_credit_zar,
      },
    );
    if (ledgerErr) return { applied: false, reason: ledgerErr.message };

    await this.supabase
      .from('pending_payments')
      .update({
        status: 'complete',
        notes: 'applied optimistically on /credits/return (sandbox only)',
        completed_at: new Date().toISOString(),
      })
      .eq('id', pid)
      .eq('status', 'pending'); // belt-and-suspenders vs. race with real ITN

    return { applied: true };
  }
}

// ============================================================================
// Factories
// ============================================================================

/**
 * Construct a `PortalApi` bound to the given (already-authenticated)
 * Supabase client. Callers are responsible for obtaining the client via
 * `getServerClient()` / `getBrowserClient()`.
 */
export function createPortalApi(supabase: CompatSupabase): PortalApi {
  return new PortalApi(supabase);
}

/**
 * Construct an `AdminApi` using the service role key. Throws if the key
 * is not configured — never silently falls back to the anon client.
 *
 * We import `createClient` lazily inside the factory to avoid pulling
 * `@supabase/supabase-js` into every page bundle that only needs the
 * anon-scoped client.
 */
export async function createAdminApi(): Promise<AdminApi> {
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const supabaseUrl =
    process.env.NEXT_PUBLIC_SUPABASE_URL ??
    'https://yrwcofhovrcydootivjx.supabase.co';
  if (!serviceRoleKey) {
    throw new Error(
      'SUPABASE_SERVICE_ROLE_KEY is not set — cannot construct AdminApi',
    );
  }
  const { createClient } = await import('@supabase/supabase-js');
  const admin = createClient<Database>(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return new AdminApi(admin);
}
