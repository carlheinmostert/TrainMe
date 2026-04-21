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
 * Row shape returned by `list_practice_members_with_profile` (Wave 5 RPC,
 * SECURITY DEFINER). Same columns as MemberRow plus identity fields
 * resolved via auth.users. Used by the audit filter dropdown + members
 * admin surfaces.
 */
export type MemberProfileRow = {
  trainerId: string;
  email: string;
  fullName: string;
  role: 'owner' | 'practitioner';
  joinedAt: string;
  isCurrentUser: boolean;
};

/**
 * A published session visible to the caller. See `list_practice_sessions`
 * RPC (`supabase/schema_milestone_h_list_practice_sessions.sql`). The
 * trainer fields are populated from the most recent `plan_issuances` row
 * for each plan — `plans` itself carries no `trainer_id`.
 */
export type PracticeSession = {
  id: string;
  title: string;
  clientName: string | null;
  trainerId: string;
  trainerEmail: string | null;
  version: number;
  /** ISO timestamp of the most recent publish. Null if never published. */
  lastPublishedAt: string | null;
  /** One-way stamp from `get_plan_full`; null until the client opens the link. */
  firstOpenedAt: string | null;
  /** Total rows in `plan_issuances` for this plan (all versions). */
  issuanceCount: number;
  /** Non-rest exercises on the plan. */
  exerciseCount: number;
  /** True when the current user is the most recent publisher. */
  isOwnSession: boolean;
};

/**
 * Per-client consent matrix. Matches the `clients.video_consent` jsonb
 * default from `schema_milestone_g_three_treatment.sql`. `line_drawing`
 * is always true — de-identification is structural, not toggleable.
 */
export type ClientVideoConsent = {
  line_drawing: true;
  grayscale: boolean;
  original: boolean;
};

/**
 * A row from `list_practice_clients(p_practice_id)`. The RPC surfaces
 * practice-scoped clients plus the timestamp of their most-recent plan
 * (null when they have no plans yet, which in practice means they've
 * been created but not published-to).
 */
export type PracticeClient = {
  id: string;
  name: string;
  videoConsent: ClientVideoConsent;
  /** ISO timestamp of the client's most recent plan activity. Null when none. */
  lastPlanAt: string | null;
};

/**
 * A single client, resolved via `get_client_by_id(p_client_id)`. Separated
 * from `PracticeClient` because the detail RPC has no `last_plan_at`
 * join — callers that need activity dates should combine this with
 * `listSessionsForClient()`.
 */
export type ClientDetail = {
  id: string;
  name: string;
  videoConsent: ClientVideoConsent;
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
   *
   * IMPORTANT: we explicitly filter by `trainer_id = auth.uid()` — the
   * practice_members RLS policy allows SELECTs on ALL rows of any
   * practice the caller is a member of (needed by /members for the
   * invite UI), so without this filter the caller sees peer members'
   * rows too. Seen in the wild when @me.com was signed in and a 3rd
   * row (@icloud.com's owner row on the shared practice) surfaced in
   * the practice switcher.
   */
  async listMyPractices(): Promise<PracticeWithRole[]> {
    const { data: userRes } = await this.supabase.auth.getUser();
    const userId = userRes.user?.id;
    if (!userId) return [];

    const { data, error } = await this.supabase
      .from('practice_members')
      .select('role, practice_id, practices:practice_id ( id, name )')
      .eq('trainer_id', userId)
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
   * List members with email / full name via the Wave 5 SECURITY DEFINER
   * RPC `list_practice_members_with_profile`. Join onto auth.users happens
   * inside the RPC — callers never need service-role access. Returns an
   * empty array if the caller isn't a member (the RPC raises 42501 which
   * we fold here) or the RPC hasn't shipped yet.
   *
   * Used by:
   *   - /members admin surface (Wave 5 table body)
   *   - /audit filter bar actor dropdown (Wave 9)
   */
  async listPracticeMembersWithProfile(
    practiceId: string,
  ): Promise<MemberProfileRow[]> {
    const { data, error } = await this.supabase.rpc(
      'list_practice_members_with_profile',
      { p_practice_id: practiceId },
    );
    if (error || !data) return [];
    const rows = (data as unknown as Array<Record<string, unknown>>) ?? [];
    return rows.map((r) => ({
      trainerId: String(r.trainer_id ?? ''),
      email: String(r.email ?? ''),
      fullName: String(r.full_name ?? ''),
      role: (r.role === 'owner' ? 'owner' : 'practitioner'),
      joinedAt: String(r.joined_at ?? ''),
      isCurrentUser: Boolean(r.is_current_user),
    }));
  }

  /**
   * Rename a practice. Wraps the `rename_practice(p_practice_id, p_new_name)`
   * SECURITY DEFINER RPC from milestone N. Owner-only inside the RPC —
   * practitioners surface as 42501 here.
   *
   * Throws a typed error so the caller (dashboard inline rename + Account
   * Settings field) can map to nice copy:
   *   - `RenamePracticeError.NotOwner` — caller isn't the practice owner (42501).
   *   - `RenamePracticeError.NotFound` — practice id doesn't exist (P0002).
   *   - `RenamePracticeError.Empty`    — blank name after trim (22023, "name required").
   *   - `RenamePracticeError.TooLong`  — >60 chars after trim (22023, "name too long...").
   *   - Generic Error otherwise.
   */
  async renamePractice(practiceId: string, newName: string): Promise<void> {
    const { error } = await this.supabase.rpc('rename_practice', {
      p_practice_id: practiceId,
      p_new_name: newName,
    });
    if (!error) return;
    const code = (error as { code?: string }).code;
    const message = error.message ?? '';
    if (code === '42501') {
      throw new RenamePracticeError('not-owner', message);
    }
    if (code === 'P0002') {
      throw new RenamePracticeError('not-found', message);
    }
    if (code === '22023') {
      // Distinguish empty vs. too-long via message text. Both carry the
      // same SQLSTATE (22023 invalid_parameter_value) — the RPC surfaces
      // "name required" vs. "name too long (max 60 chars)".
      if (/too long/i.test(message)) {
        throw new RenamePracticeError('too-long', message);
      }
      throw new RenamePracticeError('empty', message);
    }
    throw new Error(message);
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

  /**
   * Most recent `plan_issuances.created_at` for a practice. Used by the
   * dashboard Audit tile to render a "Last publish {relative-date}"
   * summary without pulling every row.
   *
   * Returns null if the practice has never published or the caller
   * can't see the issuances (RLS / non-member). The tile treats null
   * as the "Never" state.
   */
  async getLastIssuanceAt(practiceId: string): Promise<string | null> {
    const { data, error } = await this.supabase
      .from('plan_issuances')
      .select('created_at')
      .eq('practice_id', practiceId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (error || !data) return null;
    return (data as { created_at: string | null }).created_at ?? null;
  }

  // ==========================================================================
  // Sessions
  // ==========================================================================

  /**
   * Sessions (plans) visible to the caller in a given practice.
   *
   * Wraps the `list_practice_sessions(p_practice_id)` SECURITY DEFINER
   * RPC. Visibility is determined inside the RPC:
   *   - Owner       → every session in the practice.
   *   - Practitioner → only sessions they most-recently published.
   * Non-members of the practice receive a 42501 exception, which we
   * fold to an empty list here — the portal page should already have
   * gated the call on `getCurrentUserRole()`, so this is defense-in-depth.
   */
  async listPracticeSessions(
    practiceId: string,
  ): Promise<PracticeSession[]> {
    const { data, error } = await this.supabase.rpc('list_practice_sessions', {
      p_practice_id: practiceId,
    });
    if (error || !data) return [];
    const rows = (data as unknown as Array<Record<string, unknown>>) ?? [];
    return rows.map(mapPracticeSessionRow);
  }

  // ==========================================================================
  // Clients
  // ==========================================================================

  /**
   * List the clients belonging to a practice. Wraps `list_practice_clients`
   * (Milestone G). Non-members receive 42501 inside the RPC which we fold
   * to an empty list here — the portal page should have gated on
   * `getCurrentUserRole` first.
   *
   * Rows are ordered most-recent-activity-first by the RPC (NULLs last,
   * alphabetical tiebreak). Callers that need a different sort should
   * sort client-side after the fetch.
   */
  async listPracticeClients(
    practiceId: string,
  ): Promise<PracticeClient[]> {
    const { data, error } = await this.supabase.rpc('list_practice_clients', {
      p_practice_id: practiceId,
    });
    if (error || !data) return [];
    const rows = (data as unknown as Array<Record<string, unknown>>) ?? [];
    return rows.map((r) => ({
      id: String(r.id ?? ''),
      name: String(r.name ?? ''),
      videoConsent: normaliseConsent(r.video_consent),
      lastPlanAt: r.last_plan_at ? String(r.last_plan_at) : null,
    }));
  }

  /**
   * Fetch a single client by id. Wraps `get_client_by_id` (Milestone G),
   * which returns an empty set — not an error — when the client doesn't
   * exist or the caller isn't a member. We normalise that to `null`.
   */
  async getClientById(clientId: string): Promise<ClientDetail | null> {
    const { data, error } = await this.supabase.rpc('get_client_by_id', {
      p_client_id: clientId,
    });
    if (error || !data) return null;
    const rows = Array.isArray(data) ? data : [data];
    const row = rows[0] as Record<string, unknown> | undefined;
    if (!row) return null;
    return {
      id: String(row.id ?? ''),
      name: String(row.name ?? ''),
      videoConsent: normaliseConsent(row.video_consent),
    };
  }

  /**
   * Sessions belonging to a single client. Wraps the Milestone I RPC
   * `list_sessions_for_client`. Same visibility rules as
   * `listPracticeSessions`: practitioners see only their own publishes,
   * owners see every session. Non-member → empty array.
   *
   * A new RPC rather than client-side filtering because the detail page
   * has no business pulling every session in the practice to render one
   * client's slice — better to let Postgres do the WHERE.
   */
  async listSessionsForClient(
    clientId: string,
  ): Promise<PracticeSession[]> {
    const { data, error } = await this.supabase.rpc('list_sessions_for_client', {
      p_client_id: clientId,
    });
    if (error || !data) return [];
    const rows = (data as unknown as Array<Record<string, unknown>>) ?? [];
    return rows.map(mapPracticeSessionRow);
  }

  /**
   * Update a client's video treatment toggles. `line_drawing` is always
   * true (the RPC rejects false; line drawings are the structural
   * de-identification layer and can't be "withdrawn"). `grayscale` and
   * `original` are the practitioner-facing toggles on `/clients/[id]`.
   *
   * Throws on RPC error so the caller can surface a toast. Returns void
   * on success — callers that need the updated row should refetch via
   * `getClientById`.
   */
  async setClientVideoConsent(
    clientId: string,
    grayscale: boolean,
    original: boolean,
  ): Promise<void> {
    const { error } = await this.supabase.rpc('set_client_video_consent', {
      p_client_id: clientId,
      p_line_drawing: true,
      p_grayscale: grayscale,
      p_original: original,
    });
    if (error) throw new Error(error.message);
  }

  /**
   * Rename a client. Wraps the `rename_client(p_client_id, p_new_name)`
   * SECURITY DEFINER RPC from milestone J.
   *
   * Throws a typed error for the caller to surface:
   *   - `RenameClientError.Duplicate` — another client in the practice
   *     already uses the target name (PostgreSQL 23505 unique_violation).
   *   - `RenameClientError.NotFound` — client id doesn't exist (P0002).
   *   - `RenameClientError.NotMember` — caller isn't a member of the
   *     client's practice (42501).
   *   - `RenameClientError.Empty` — blank name (22023).
   *   - Generic Error otherwise.
   */
  async renameClient(clientId: string, newName: string): Promise<void> {
    const { error } = await this.supabase.rpc('rename_client', {
      p_client_id: clientId,
      p_new_name: newName,
    });
    if (!error) return;
    const code = (error as { code?: string }).code;
    if (code === '23505') throw new RenameClientError('duplicate', error.message);
    if (code === 'P0002') throw new RenameClientError('not-found', error.message);
    if (code === '42501') throw new RenameClientError('not-member', error.message);
    if (code === '22023') throw new RenameClientError('empty', error.message);
    throw new Error(error.message);
  }

  /**
   * `delete_client(p_client_id)` — soft-delete the client and cascade
   * a tombstone onto every plan owned by the client. Identical
   * `deleted_at` timestamp on both, so `restoreClient` can reverse
   * exactly what this cascaded.
   *
   * Idempotent — calling on an already-deleted client is a no-op
   * server-side (returns the tombstoned row unchanged). SECURITY
   * DEFINER; practice-membership enforced inside the RPC.
   *
   * Throws a typed [DeleteClientError] for the caller (Delete action
   * in [ClientsList] / [ClientDetailPanel]) to surface:
   *   - `not-found` (P0002) — client id doesn't exist.
   *   - `not-member` (42501) — caller isn't a member of the practice.
   *   - Generic Error otherwise.
   */
  async deleteClient(clientId: string): Promise<void> {
    const { error } = await this.supabase.rpc('delete_client', {
      p_client_id: clientId,
    });
    if (!error) return;
    const code = (error as { code?: string }).code;
    if (code === 'P0002') throw new DeleteClientError('not-found', error.message);
    if (code === '42501') throw new DeleteClientError('not-member', error.message);
    throw new Error(error.message);
  }

  /**
   * `restore_client(p_client_id)` — reverses [deleteClient]. Flips the
   * client's `deleted_at` back to null AND restores cascaded plans
   * whose `deleted_at` matches the client's `deleted_at` exactly.
   * Plans soft-deleted at a different timestamp stay deleted.
   *
   * Idempotent on an already-live client.
   */
  async restoreClient(clientId: string): Promise<void> {
    const { error } = await this.supabase.rpc('restore_client', {
      p_client_id: clientId,
    });
    if (!error) return;
    const code = (error as { code?: string }).code;
    if (code === 'P0002') throw new DeleteClientError('not-found', error.message);
    if (code === '42501') throw new DeleteClientError('not-member', error.message);
    throw new Error(error.message);
  }
}

export class RenameClientError extends Error {
  constructor(
    public readonly kind: 'duplicate' | 'not-found' | 'not-member' | 'empty',
    message: string,
  ) {
    super(message);
    this.name = 'RenameClientError';
  }
}

/**
 * Typed failure from [PortalApi.renamePractice]. Mirrors the
 * [RenameClientError] shape (kind = SQLSTATE bucket) so the two inline-
 * rename flows present the same error-mapper shape to callers.
 *
 * `not-owner` replaces `not-member` because the DB check is the stricter
 * owner role, not general membership.
 */
export class RenamePracticeError extends Error {
  constructor(
    public readonly kind: 'not-owner' | 'not-found' | 'empty' | 'too-long',
    message: string,
  ) {
    super(message);
    this.name = 'RenamePracticeError';
  }
}

/**
 * Categorised failure from [PortalApi.deleteClient] /
 * [PortalApi.restoreClient]. Mirrors the mobile surface so both
 * twins show the same voice ("Client not found" / "You don't have
 * permission"). Only the 42501 / P0002 SQLSTATEs are named — other
 * errors surface as a plain [Error] with the server message.
 */
export class DeleteClientError extends Error {
  constructor(
    public readonly kind: 'not-found' | 'not-member',
    message: string,
  ) {
    super(message);
    this.name = 'DeleteClientError';
  }
}

// ============================================================================
// Members surface (PortalMembersApi)
// ============================================================================
//
// Wraps the Wave 14 (milestone U) SECURITY DEFINER RPCs for add-member-by-
// email, pending-revoke, combined roster + pending list, role change,
// remove, and leave flows. Owner-only gates live inside each RPC — the
// client just surfaces the typed signature + error mapping.
//
// Supersedes the Wave 5 invite-code flow (mint + claim). The new model
// is: owner types invitee email → existing auth.users get added
// immediately; new-to-homefit emails get parked in pending_practice_members
// and a trigger drains them on signup. The invitee never sees an invite
// link or code — magic-link throttle is no longer in the critical path.
//
// Visibility: any practice member can read the roster + pending list
// (transparency intentional, carries over from Wave 5). Writes enforce
// owner-only at the DB level.

export type MemberProfile = {
  trainerId: string;
  email: string;
  fullName: string;
  role: 'owner' | 'practitioner';
  joinedAt: string;
  isCurrentUser: boolean;
};

/**
 * A parking-lot entry in `pending_practice_members`. Surfaces in the
 * "Pending" section of the /members page alongside the current-member
 * table. `email` is the only identity — there's no auth.users row yet.
 * `addedAt` is when the owner nudged them; `addedBy` is the owner uuid.
 */
export type PendingMember = {
  email: string;
  addedBy: string | null;
  addedAt: string;
};

/**
 * Return payload from `addMemberByEmail` — mirrors the three-way branch
 * inside `add_practice_member_by_email`: the target already has an
 * auth.users row and is (a) now added, (b) already a member, or (c) no
 * auth.users row yet → parked in pending.
 */
export type AddMemberResult =
  | {
      kind: 'added';
      trainerId: string;
      email: string;
      fullName: string;
      role: 'owner' | 'practitioner';
    }
  | {
      kind: 'already_member';
      trainerId: string;
      email: string;
      fullName: string;
      role: 'owner' | 'practitioner';
    }
  | {
      kind: 'pending';
      email: string;
    };

/**
 * Typed failure from [PortalMembersApi] mutations. Mirrors the
 * [RenameClientError] / [RenamePracticeError] shape — kind bucket + message —
 * so the pages can pick the matching inline copy without string parsing.
 *
 *   - `not-owner` (42501) — caller is not an owner (add, set-role, remove, remove-pending).
 *   - `not-member` (42501) — caller is not in the practice (leave).
 *   - `not-found` (P0002) — member row missing.
 *   - `invalid` (22023) — self-role-change, last-owner, solo-member,
 *     malformed email on add.
 *   - `auth` (28000) — session expired; caller should re-auth.
 */
export class MembersError extends Error {
  constructor(
    public readonly kind:
      | 'not-owner'
      | 'not-member'
      | 'not-found'
      | 'invalid'
      | 'auth',
    message: string,
  ) {
    super(message);
    this.name = 'MembersError';
  }
}

export class PortalMembersApi {
  constructor(private readonly supabase: CompatSupabase) {}

  /**
   * Roster for a practice — every member's uuid, email, display name,
   * role, join-timestamp, plus an `isCurrentUser` flag for the own-row
   * tag.
   *
   * Preserves the Wave 5 shape for backward-compat callers (audit filter
   * actor dropdown uses this; see `listPracticeMembersWithProfile` on
   * PortalApi). /members itself has moved to `listMembersAndPending`
   * which UNIONs current + pending in one call.
   *
   * RPC enforces membership (42501 if not a member); we surface an
   * empty list in that case because defence-in-depth: the caller should
   * already have gated on `getCurrentUserRole`. Other errors bubble as
   * empty list too — the members page treats that as "no roster yet"
   * which matches the degraded-degraded UX the other list wrappers here
   * follow.
   */
  async listMembers(practiceId: string): Promise<MemberProfile[]> {
    const { data, error } = await this.supabase.rpc(
      'list_practice_members_with_profile',
      { p_practice_id: practiceId },
    );
    if (error || !data) return [];
    const rows = (data as unknown as Array<Record<string, unknown>>) ?? [];
    return rows.map((r) => ({
      trainerId: String(r.trainer_id ?? ''),
      email: String(r.email ?? ''),
      fullName: String(r.full_name ?? ''),
      role: (r.role === 'owner' ? 'owner' : 'practitioner') as
        | 'owner'
        | 'practitioner',
      joinedAt: String(r.joined_at ?? ''),
      isCurrentUser: Boolean(r.is_current_user),
    }));
  }

  /**
   * Wave 14 — list current members + pending entries in a single RPC
   * call. The RPC UNIONs `practice_members` (joined on auth.users for
   * identity) with `pending_practice_members`; the `is_pending` flag
   * splits the two sections at render time. Current-member rows carry
   * null `addedBy` / `addedAt`; pending rows carry null `trainerId`.
   *
   * Used by /members. Everywhere else should stay on `listMembers` so
   * pending rows don't leak into surfaces that only model real
   * practitioners (audit filter, mobile).
   *
   * Non-member callers get 42501 inside the RPC which we fold to
   * `{members: [], pending: []}` here — defence-in-depth.
   */
  async listMembersAndPending(
    practiceId: string,
  ): Promise<{ members: MemberProfile[]; pending: PendingMember[] }> {
    const { data, error } = await this.supabase.rpc(
      'list_practice_members_and_pending',
      { p_practice_id: practiceId },
    );
    if (error || !data) return { members: [], pending: [] };
    const rows = (data as unknown as Array<Record<string, unknown>>) ?? [];
    const members: MemberProfile[] = [];
    const pending: PendingMember[] = [];
    for (const r of rows) {
      if (Boolean(r.is_pending)) {
        pending.push({
          email: String(r.email ?? ''),
          addedBy: r.added_by ? String(r.added_by) : null,
          addedAt: String(r.added_at ?? ''),
        });
      } else {
        members.push({
          trainerId: String(r.trainer_id ?? ''),
          email: String(r.email ?? ''),
          fullName: String(r.full_name ?? ''),
          role: (r.role === 'owner' ? 'owner' : 'practitioner') as
            | 'owner'
            | 'practitioner',
          joinedAt: String(r.joined_at ?? ''),
          isCurrentUser: Boolean(r.is_current_user),
        });
      }
    }
    return { members, pending };
  }

  /**
   * Wave 14 — add a member to a practice by email.
   *
   * Wraps `add_practice_member_by_email(p_practice_id, p_email)`
   * (SECURITY DEFINER, owner-only). The RPC returns a single row with a
   * `kind` discriminator so the caller can pick the right toast copy:
   *
   *   - `added`          — the email had an auth.users row and was just
   *                        inserted into practice_members.
   *   - `already_member` — the email had an auth.users row AND was
   *                        already in practice_members. The existing
   *                        role is echoed back for display parity with
   *                        `added`.
   *   - `pending`        — no auth.users row yet. A pending_practice_members
   *                        row was upserted; a trigger on auth.users
   *                        INSERT will drain it on signup.
   *
   * Typed errors:
   *   - `not-owner` (42501) — caller is not an owner.
   *   - `invalid`   (22023) — email missing / malformed.
   *   - `auth`      (28000) — session expired.
   */
  async addMemberByEmail(
    practiceId: string,
    email: string,
  ): Promise<AddMemberResult> {
    const { data, error } = await this.supabase.rpc(
      'add_practice_member_by_email',
      { p_practice_id: practiceId, p_email: email },
    );
    if (error) throw mapMembersError(error);
    const rows = Array.isArray(data) ? data : data ? [data] : [];
    const row = rows[0] as Record<string, unknown> | undefined;
    if (!row) {
      throw new Error('add_practice_member_by_email returned empty payload');
    }
    const kind = String(row.kind ?? '');
    if (kind === 'pending') {
      return { kind: 'pending', email: String(row.email ?? '') };
    }
    if (kind === 'added' || kind === 'already_member') {
      return {
        kind,
        trainerId: String(row.trainer_id ?? ''),
        email: String(row.email ?? ''),
        fullName: String(row.full_name ?? ''),
        role: (row.role === 'owner' ? 'owner' : 'practitioner') as
          | 'owner'
          | 'practitioner',
      };
    }
    throw new Error(
      `add_practice_member_by_email returned unexpected kind "${kind}"`,
    );
  }

  /**
   * Wave 14 — revoke a pending entry before the user signs up.
   *
   * Wraps `remove_pending_practice_member(p_practice_id, p_email)`
   * (SECURITY DEFINER, owner-only). No-op if the pending row doesn't
   * exist (so the UI doesn't need to race against the trigger draining
   * the row on signup).
   */
  async removePendingMember(
    practiceId: string,
    email: string,
  ): Promise<void> {
    const { error } = await this.supabase.rpc(
      'remove_pending_practice_member',
      { p_practice_id: practiceId, p_email: email },
    );
    if (error) throw mapMembersError(error);
  }

  /**
   * Update a member's role. Owner-only; the RPC rejects self-role-change
   * and last-owner demotion at the DB level. Returns void on success.
   *
   * Typed errors:
   *   - `not-owner` (42501) — caller is not an owner.
   *   - `not-found` (P0002) — member row doesn't exist.
   *   - `invalid` (22023) — self-change, invalid role string, or last-owner.
   */
  async setMemberRole(
    practiceId: string,
    trainerId: string,
    role: 'owner' | 'practitioner',
  ): Promise<void> {
    const { error } = await this.supabase.rpc('set_practice_member_role', {
      p_practice_id: practiceId,
      p_trainer_id: trainerId,
      p_new_role: role,
    });
    if (error) throw mapMembersError(error);
  }

  /**
   * Remove a member from a practice. Owner-only; RPC rejects self-remove
   * (caller must use `leavePractice` instead) and last-owner remove.
   *
   * Hard delete — no undo for Wave 5. Follow-up wave may add a 5-second
   * undo RPC that re-inserts the member.
   */
  async removeMember(practiceId: string, trainerId: string): Promise<void> {
    const { error } = await this.supabase.rpc('remove_practice_member', {
      p_practice_id: practiceId,
      p_trainer_id: trainerId,
    });
    if (error) throw mapMembersError(error);
  }

  /**
   * Leave a practice yourself. Any member can call. Blocks:
   *   - You're the solo member — contact support to delete the practice.
   *   - You're the last owner with other members — promote someone first.
   *
   * After a successful call the caller's page should redirect to `/`
   * (which boots them to their remaining practices via practice switcher).
   */
  async leavePractice(practiceId: string): Promise<void> {
    const { error } = await this.supabase.rpc('leave_practice', {
      p_practice_id: practiceId,
    });
    if (error) throw mapMembersError(error);
  }
}

/** Construct a `PortalMembersApi` bound to the given Supabase client. */
export function createPortalMembersApi(
  supabase: CompatSupabase,
): PortalMembersApi {
  return new PortalMembersApi(supabase);
}

// Error classifier for the Milestone P RPCs. Mirrors the SQLSTATE choices
// inside `schema_milestone_p_members.sql`.
function mapMembersError(
  err: { code?: string; message?: string } | null | undefined,
): Error {
  if (!err) return new Error('Unknown error');
  const code = err.code ?? '';
  const message = err.message ?? 'Unknown error';
  if (code === '28000') return new MembersError('auth', message);
  if (code === '42501') {
    // Both owner-only and not-a-member surface as 42501. The message is
    // the only disambiguator — callers that care can inspect `kind`, but
    // for the portal UI owner-only is the common case so default there.
    if (/not a member/i.test(message)) {
      return new MembersError('not-member', message);
    }
    return new MembersError('not-owner', message);
  }
  if (code === 'P0002') return new MembersError('not-found', message);
  if (code === '22023') return new MembersError('invalid', message);
  return new Error(message);
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
   * path produces the 5% lifetime credit rebate (with a 1-credit
   * goodwill floor on the referrer's FIRST rebate from each referee) —
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

// ============================================================================
// Audit surface (PortalAuditApi)
// ============================================================================
//
// Wave 9 — unified practice event log with filters + pagination. The portal's
// `/audit` page routes through this class exclusively; direct table reads
// are a layering violation.
//
// The backing RPC is `list_practice_audit(p_practice_id, p_offset, p_limit,
// p_kinds[], p_actor, p_from, p_to)` — SECURITY DEFINER, membership-gated,
// unions plan_issuances + credit_ledger + referral_rebate_ledger + clients +
// practice_members + practice_invite_codes + audit_events. The RPC emits a
// window `total_count` on every row so pagination doesn't need a second
// round-trip.
//
// SCHEMA NOTE: credit_ledger has no trainer_id column, so credit rows surface
// with `trainerId`/`email`/`fullName` all null. The portal renders those as
// "—". Plan publishes and member joins DO carry the actor.

/** Canonical event kinds emitted by the RPC. Kept in sync with the SQL
 *  `CASE` branches in `schema_milestone_t_audit_expansion.sql`. The portal
 *  uses these as chip keys; ad-hoc audit_events rows can emit new kinds and
 *  the portal falls back to the grey "neutral" palette. */
export const AUDIT_EVENT_KINDS = [
  'plan.publish',
  'credit.consumption',
  'credit.purchase',
  'credit.refund',
  'credit.adjustment',
  'credit.signup_bonus',
  'credit.referral_signup_bonus',
  'referral.rebate',
  'client.create',
  'client.delete',
  'client.restore',
  'member.join',
  'member.role_change',
  'member.remove',
  // Wave 14: invite.mint / invite.claim / invite.revoke retired with the
  // invite-code flow. The audit page's label + description maps keep
  // fallback copy for any stale audit_events rows with those kinds, but
  // they no longer surface as filter chips.
  'practice.rename',
] as const;

export type AuditEventKind = (typeof AUDIT_EVENT_KINDS)[number];

/** Chip colour bucket. Kept here (not in a component) so the mobile twin can
 *  reuse the same palette when porting. */
export type AuditChipTone = 'coral' | 'sage' | 'red' | 'grey';

/** Maps a kind string (including unknown future kinds) to a chip tone. Any
 *  kind not in the table falls back to 'grey' — safe neutral default. */
export function auditChipTone(kind: string): AuditChipTone {
  switch (kind) {
    case 'plan.publish':
    case 'credit.consumption':
      return 'coral';
    case 'credit.purchase':
    case 'credit.signup_bonus':
    case 'credit.referral_signup_bonus':
    case 'referral.rebate':
      return 'sage';
    case 'credit.refund':
    case 'client.delete':
    case 'member.remove':
    // Wave 14: invite.revoke kept only for the defensive grey-fallback
    // on legacy audit_events rows; no new emissions after Wave 5 retired.
    case 'invite.revoke':
      return 'red';
    default:
      return 'grey';
  }
}

/** A single row emitted by `list_practice_audit`. The jsonb `meta` bag is
 *  kind-specific; callers key into it defensively. */
export type AuditRow = {
  ts: string;
  kind: string;
  trainerId: string | null;
  email: string | null;
  fullName: string | null;
  title: string | null;
  creditsDelta: number | null;
  balanceAfter: number | null;
  refId: string | null;
  meta: Record<string, unknown> | null;
};

/** Page of audit rows + total matching-filter count (same value on every
 *  row in the RPC output; the portal uses it for "Showing N–M of T" +
 *  pagination). */
export type AuditPage = {
  rows: AuditRow[];
  totalCount: number;
};

export type AuditListOptions = {
  /** Zero-based offset into the filtered result set. Default 0. */
  offset?: number;
  /** Page size. Default 50. Capped at 5000 server-side by convention. */
  limit?: number;
  /** Filter: include only these exact kinds. Omit or empty → all kinds. */
  kinds?: string[];
  /** Filter: only events by this actor uuid. Null/omitted → all actors. */
  actor?: string | null;
  /** Filter: ts >= this ISO timestamp. */
  from?: string | null;
  /** Filter: ts <= this ISO timestamp. */
  to?: string | null;
};

/** Wraps the `list_practice_audit` RPC surface. Separate class from
 *  [PortalApi] so the audit feature is self-contained and easy to move
 *  later if the portal ever splits into domain bundles. */
export class PortalAuditApi {
  constructor(private readonly supabase: CompatSupabase) {}

  /**
   * List practice audit events, filtered + paginated. Returns an empty page
   * on any RPC error — the portal is display-safe (the table renders the
   * "no events match these filters" empty state). Callers that need to
   * distinguish "truly empty" from "RPC failed" should surface errors
   * from a separate health check, not this method.
   */
  async listAudit(
    practiceId: string,
    opts: AuditListOptions = {},
  ): Promise<AuditPage> {
    const { data, error } = await this.supabase.rpc('list_practice_audit', {
      p_practice_id: practiceId,
      p_offset: opts.offset ?? 0,
      p_limit: opts.limit ?? 50,
      // RPC treats NULL as "no filter" — unwrap empty arrays so a blank
      // kinds filter doesn't accidentally match zero rows.
      p_kinds:
        opts.kinds && opts.kinds.length > 0 ? opts.kinds : undefined,
      p_actor: opts.actor ?? undefined,
      p_from: opts.from ?? undefined,
      p_to: opts.to ?? undefined,
    });
    if (error || !data) {
      return { rows: [], totalCount: 0 };
    }
    const rows = (data as unknown as Array<Record<string, unknown>>) ?? [];
    const totalCount =
      rows.length > 0 ? Number(rows[0]?.total_count ?? 0) : 0;
    return {
      rows: rows.map(mapAuditRow),
      totalCount: Number.isFinite(totalCount) ? totalCount : 0,
    };
  }
}

/** Construct a [PortalAuditApi] bound to the given Supabase client. */
export function createPortalAuditApi(
  supabase: CompatSupabase,
): PortalAuditApi {
  return new PortalAuditApi(supabase);
}

// ----------------------------------------------------------------------------
// Audit helpers
// ----------------------------------------------------------------------------

function mapAuditRow(r: Record<string, unknown>): AuditRow {
  const meta = r.meta;
  return {
    ts: String(r.ts ?? ''),
    kind: String(r.kind ?? ''),
    trainerId: r.trainer_id ? String(r.trainer_id) : null,
    email: r.email ? String(r.email) : null,
    fullName: r.full_name ? String(r.full_name) : null,
    title: r.title ? String(r.title) : null,
    creditsDelta: coerceNumberOrNull(r.credits_delta),
    balanceAfter: coerceNumberOrNull(r.balance_after),
    refId: r.ref_id ? String(r.ref_id) : null,
    meta:
      meta && typeof meta === 'object' && !Array.isArray(meta)
        ? (meta as Record<string, unknown>)
        : null,
  };
}

/** Numeric columns come back as strings (Postgres numeric type) in the JSON
 *  payload. Coerce to number, but preserve null vs 0 — many audit rows
 *  legitimately have null credit deltas (e.g. plan.publish). */
function coerceNumberOrNull(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v === 'string') {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

// ============================================================================
// Referral surface (PortalReferralApi)
// ============================================================================
//
// Separate class so the referral feature is self-contained. Wraps the
// SECURITY DEFINER RPCs landed in `supabase/schema_milestone_f_referral_loop.sql`.
// Defensive mock-fallbacks are preserved for cases where a fresh deploy
// hits the page before the migration has run; they're effectively dead
// code in steady state but harmless and self-documenting.
//
// All RPCs use the same Database typing as PortalApi via the
// `CompatSupabase` alias, so the existing factories can be reused.

export type ReferralLandingMeta = {
  /** Display name of the inviting practice, or null if they haven't consented to be named publicly. */
  inviter_display_name: string | null;
  /** True if the code corresponds to an active referral code. */
  code_valid: boolean;
};

export type ReferralDashboardStats = {
  /** Credits earned but not yet burned on publishes. */
  rebate_balance_credits: number;
  /** Lifetime rebate credits earned across all referees. */
  lifetime_rebate_credits: number;
  /** Number of practices that joined via this code. */
  referee_count: number;
  /** Total qualifying PayFast spend (ZAR) across the network. */
  qualifying_spend_total_zar: number;
};

export type ReferralRefereeRow = {
  /** Either the real practice name (if consented) or an anonymised label like "Practice 3". */
  referee_label: string;
  /** Null when referee hasn't consented to being named. */
  referee_practice_id: string | null;
  joined_at: string; // ISO timestamp
  qualifying_spend_zar: number;
  rebate_earned_credits: number;
  is_named: boolean;
};

export class PortalReferralApi {
  constructor(private readonly supabase: CompatSupabase) {}

  /** Generate or fetch the practice's referral code. Idempotent. */
  async generateCode(practiceId: string): Promise<string | null> {
    const { data, error } = await this.supabase.rpc('generate_referral_code', {
      p_practice_id: practiceId,
    });
    if (error) {
      if (isMissingRpc(error)) return mockCodeFor(practiceId);
      return null;
    }
    return typeof data === 'string' ? data : null;
  }

  /**
   * Rotate the practice's referral code. The old code stops working
   * immediately. Used by the dashboard regenerate flow (R-01 undo SnackBar).
   */
  async revokeCode(practiceId: string): Promise<boolean> {
    const { data, error } = await this.supabase.rpc('revoke_referral_code', {
      p_practice_id: practiceId,
    });
    if (error) {
      if (isMissingRpc(error)) return true;
      return false;
    }
    return data === true;
  }

  /**
   * Called from the signup completion path. Fails silently — the portal
   * never blocks signup on a dodgy referral code.
   */
  async claimCode(
    code: string,
    refereePracticeId: string,
    consentToNaming: boolean,
  ): Promise<boolean> {
    const { data, error } = await this.supabase.rpc('claim_referral_code', {
      p_code: code,
      p_referee_practice_id: refereePracticeId,
      p_consent_to_naming: consentToNaming,
    });
    if (error) {
      if (isMissingRpc(error)) return false;
      return false;
    }
    return data === true;
  }

  /** Dashboard stats — 4 numbers shown on the Network earnings card. */
  async dashboardStats(practiceId: string): Promise<ReferralDashboardStats> {
    const { data, error } = await this.supabase.rpc('referral_dashboard_stats', {
      p_practice_id: practiceId,
    });
    if (error || !data) {
      return {
        rebate_balance_credits: 0,
        lifetime_rebate_credits: 0,
        referee_count: 0,
        qualifying_spend_total_zar: 0,
      };
    }
    const row = Array.isArray(data) ? data[0] : data;
    return {
      rebate_balance_credits: toNumber(row?.rebate_balance_credits),
      lifetime_rebate_credits: toNumber(row?.lifetime_rebate_credits),
      referee_count: toNumber(row?.referee_count),
      qualifying_spend_total_zar: toNumber(row?.qualifying_spend_total_zar),
    };
  }

  /** Rows for the scrollable referee list. Default-sort: most-recent join. */
  async refereesList(practiceId: string): Promise<ReferralRefereeRow[]> {
    const { data, error } = await this.supabase.rpc('referral_referees_list', {
      p_practice_id: practiceId,
    });
    if (error || !data) return [];
    const rows = Array.isArray(data) ? data : [];
    return rows.map(
      (r: Record<string, unknown>): ReferralRefereeRow => ({
        referee_label: String(r.referee_label ?? 'Practice'),
        referee_practice_id:
          typeof r.referee_practice_id === 'string'
            ? r.referee_practice_id
            : null,
        joined_at: String(r.joined_at ?? ''),
        qualifying_spend_zar: toNumber(r.qualifying_spend_zar),
        rebate_earned_credits: toNumber(r.rebate_earned_credits),
        is_named: Boolean(r.is_named),
      }),
    );
  }

  /**
   * Public landing-page metadata for `/r/{code}`. Called from the server
   * component + the OG image renderer. No auth required.
   */
  async landingMeta(code: string): Promise<ReferralLandingMeta> {
    const { data, error } = await this.supabase.rpc('referral_landing_meta', {
      p_code: code,
    });
    if (error || !data) {
      return { inviter_display_name: null, code_valid: true };
    }
    const row = Array.isArray(data) ? data[0] : data;
    return {
      inviter_display_name:
        typeof row?.inviter_display_name === 'string'
          ? row.inviter_display_name
          : null,
      code_valid: Boolean(row?.code_valid ?? true),
    };
  }
}

/** Construct a `PortalReferralApi` bound to the given Supabase client. */
export function createPortalReferralApi(
  supabase: CompatSupabase,
): PortalReferralApi {
  return new PortalReferralApi(supabase);
}

// ----------------------------------------------------------------------------
// Referral helpers
// ----------------------------------------------------------------------------

function toNumber(v: unknown): number {
  if (typeof v === 'number') return v;
  if (typeof v === 'string') {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

/** Postgrest returns 404-ish errors when the function isn't defined. */
function isMissingRpc(err: { code?: string; message?: string }): boolean {
  if (!err) return false;
  if (err.code === 'PGRST202' || err.code === '42883') return true;
  const msg = err.message ?? '';
  return /function .* does not exist|could not find the function/i.test(msg);
}

/**
 * Normalise the `video_consent` jsonb returned by Supabase into the typed
 * `ClientVideoConsent` shape. Any coercion happens here — callers always
 * receive a well-formed object with `line_drawing === true` (the RPC
 * layer enforces that it can't be false). Unknown jsonb shapes fall back
 * to the conservative default (line drawing only).
 */
function normaliseConsent(raw: unknown): ClientVideoConsent {
  if (raw && typeof raw === 'object') {
    const obj = raw as Record<string, unknown>;
    return {
      line_drawing: true,
      grayscale: Boolean(obj.grayscale),
      original: Boolean(obj.original),
    };
  }
  return { line_drawing: true, grayscale: false, original: false };
}

/**
 * Shared row mapper between `list_practice_sessions` and
 * `list_sessions_for_client` — the two RPCs return the same columns so
 * there's no need to duplicate the string-coercion ritual.
 */
function mapPracticeSessionRow(r: Record<string, unknown>): PracticeSession {
  return {
    id: String(r.id ?? ''),
    title: String(r.title ?? ''),
    clientName: r.client_name ? String(r.client_name) : null,
    trainerId: r.trainer_id ? String(r.trainer_id) : '',
    trainerEmail: r.trainer_email ? String(r.trainer_email) : null,
    version: Number(r.version ?? 0),
    lastPublishedAt: r.last_published_at ? String(r.last_published_at) : null,
    firstOpenedAt: r.first_opened_at ? String(r.first_opened_at) : null,
    issuanceCount: Number(r.issuance_count ?? 0),
    exerciseCount: Number(r.exercise_count ?? 0),
    isOwnSession: Boolean(r.is_own_session),
  };
}

/** Stable 6-char code derived from a uuid. Mock-only fallback. */
function mockCodeFor(practiceId: string): string {
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  let hash = 0;
  for (let i = 0; i < practiceId.length; i++) {
    hash = (hash * 31 + practiceId.charCodeAt(i)) >>> 0;
  }
  let out = '';
  for (let i = 0; i < 6; i++) {
    out += alphabet[hash % alphabet.length];
    hash = Math.floor(hash / alphabet.length) + practiceId.charCodeAt(i % practiceId.length);
  }
  return out;
}

// ============================================================================
// Share-kit analytics surface (PortalShareKitApi) — Wave 10 Phase 3
// ============================================================================
//
// The `/network` page exposes four share channels (WhatsApp 1:1, WhatsApp
// broadcast, Email, PNG share card) with up to three actions each (copy,
// open-intent, download, clipboard-image). Each action fires fire-and-forget
// against `log_share_event(practice_id, channel, event_kind, meta)`, a
// SECURITY DEFINER RPC on the `share_events` append-only table (milestone S).
//
// This class lives here so the analytics surface uses the same single-
// enumerated-surface convention as the rest of the portal (see
// docs/DATA_ACCESS_LAYER.md). Previously I considered folding it into
// PortalReferralApi since both surfaces live on /network — but the channels
// include code_copy and link_copy which aren't referral-specific, so a
// dedicated class reads cleaner on the caller side.
//
// The single RPC takes: practice_id, channel ∈ (whatsapp_one_to_one,
// whatsapp_broadcast, email, png_download, png_clipboard, tagline_copy,
// code_copy, link_copy), event_kind ∈ (copy, open_intent, download,
// clipboard_image), and optional meta jsonb.
//
// Callers should fire-and-forget via `void api.logEvent(...)` — the analytics
// value of a single event is low, so we never block the UX on its success.

/** Channel the event was fired from. Matches the CHECK on share_events.channel. */
export type ShareEventChannel =
  | 'whatsapp_one_to_one'
  | 'whatsapp_broadcast'
  | 'email'
  | 'png_download'
  | 'png_clipboard'
  | 'tagline_copy'
  | 'code_copy'
  | 'link_copy';

/** Action that was taken. Matches the CHECK on share_events.event_kind. */
export type ShareEventKind =
  | 'copy'
  | 'open_intent'
  | 'download'
  | 'clipboard_image';

/**
 * PortalShareKitApi — the single enumerated write surface for share
 * telemetry. Wraps the `log_share_event` SECURITY DEFINER RPC.
 *
 * All callers should use this class instead of raw `supabase.rpc(...)`
 * calls so the channel / kind enums stay type-safe. The wrapper returns
 * nothing and swallows errors — analytics is fire-and-forget per the
 * Wave 10 brief.
 */
export class PortalShareKitApi {
  constructor(private readonly supabase: CompatSupabase) {}

  /**
   * Append a share_events row. Never throws; errors are silent so a flaky
   * analytics path doesn't break the share-kit UX. Caller convention is
   * `void api.logEvent(...)` from a click handler.
   *
   * `meta` is optional — reserve it for payloads the dashboard will care
   * about (e.g. `{ colleague_name_substituted: true }` for the 1:1 card
   * when the user filled in a first name, or `{ code: 'K3JT7QR' }` when
   * the action is tied to a specific referral code revision).
   */
  async logEvent(
    practiceId: string,
    channel: ShareEventChannel,
    eventKind: ShareEventKind,
    meta?: Record<string, unknown>,
  ): Promise<void> {
    try {
      await this.supabase.rpc('log_share_event', {
        p_practice_id: practiceId,
        p_channel: channel,
        p_event_kind: eventKind,
        p_meta: meta ? (meta as never) : undefined,
      });
    } catch {
      // Swallow — analytics must never break the share UX. If the RPC is
      // down the user's copy/download still works, they just don't show
      // up in the funnel dashboard.
    }
  }
}

/** Construct a `PortalShareKitApi` bound to the given Supabase client. */
export function createPortalShareKitApi(
  supabase: CompatSupabase,
): PortalShareKitApi {
  return new PortalShareKitApi(supabase);
}
