// Typed Supabase surface for the web portal.
//
// Referral-flow RPCs live behind this file. If a sister backend agent
// hasn't shipped an RPC yet the call returns sensible mock data so the
// UI still renders — look for `TODO(backend-agent)` comments below.
//
// Wiring pattern mirrors the guidance in docs/DATA_ACCESS_LAYER.md:
// one enumerated surface per client runtime, typed contracts, never
// direct table queries from pages.

import type { SupabaseClient } from '@supabase/supabase-js';

/* -------------------------------------------------------------------------- */
/*  Contracts                                                                 */
/* -------------------------------------------------------------------------- */

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

/* -------------------------------------------------------------------------- */
/*  Surface                                                                   */
/* -------------------------------------------------------------------------- */

export class PortalReferralApi {
  constructor(private readonly supabase: SupabaseClient) {}

  /**
   * Generate or fetch the practice's referral code. Idempotent —
   * repeat calls return the existing code.
   */
  async generateCode(practiceId: string): Promise<string | null> {
    const { data, error } = await this.supabase.rpc('generate_referral_code', {
      p_practice_id: practiceId,
    });
    if (error) {
      // TODO(backend-agent): RPC pending. Mock — returns a deterministic
      // 6-char code derived from the practice id so the UI stays stable
      // across page loads.
      if (isMissingRpc(error)) return mockCodeFor(practiceId);
      return null;
    }
    return typeof data === 'string' ? data : null;
  }

  /**
   * Rotate the practice's referral code. The old code stops working
   * immediately. Returns true on success. Called from the dashboard
   * regenerate flow (guarded by an undo SnackBar per R-01).
   */
  async revokeCode(practiceId: string): Promise<boolean> {
    const { data, error } = await this.supabase.rpc('revoke_referral_code', {
      p_practice_id: practiceId,
    });
    if (error) {
      // TODO(backend-agent): RPC pending. Mock success so the UI
      // regen flow doesn't jam during pre-backend dev.
      if (isMissingRpc(error)) return true;
      return false;
    }
    return data === true;
  }

  /**
   * Called from the signup completion path. Silently failures — the
   * portal never blocks signup on a dodgy referral code.
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
      if (isMissingRpc(error)) return false; // TODO(backend-agent): RPC pending.
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
      // TODO(backend-agent): RPC pending. Mock so the UI renders a
      // realistic-looking empty state during pre-backend dev.
      return {
        rebate_balance_credits: 0,
        lifetime_rebate_credits: 0,
        referee_count: 0,
        qualifying_spend_total_zar: 0,
      };
    }
    // RPC may return a single row or an array of one; normalise.
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
    if (error || !data) {
      // TODO(backend-agent): RPC pending.
      return [];
    }
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
   * Public landing-page metadata for `/r/{code}`. Called from the
   * server component + the OG image renderer. No auth required.
   */
  async landingMeta(code: string): Promise<ReferralLandingMeta> {
    const { data, error } = await this.supabase.rpc('referral_landing_meta', {
      p_code: code,
    });
    if (error || !data) {
      // TODO(backend-agent): RPC pending. Treat every code as valid with
      // no inviter name — the page will fall back to "a colleague".
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

/* -------------------------------------------------------------------------- */
/*  Helpers                                                                   */
/* -------------------------------------------------------------------------- */

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

/** Stable 6-char code derived from a uuid. Mock-only — backend generates its own. */
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
