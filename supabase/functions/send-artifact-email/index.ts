// Send Artifact Email — Wave 5 (2026-05-26)
//
// Edge function invoked from the Studio share sheet's "Send by email" path.
// Looks up the practitioner's brand identity, sends a branded email via
// Resend's HTTP API containing the live workout-handout link
// (https://session.homefit.studio/h/{plan_id}), and stamps the typed
// recipient address on the clients row via the set_client_email RPC so
// the practitioner doesn't have to re-type next time.
//
// Skips the set_client_email step when the existing email is verified
// (clients.email_verified_at IS NOT NULL) — the typed-email path will
// NOT overwrite a verified address per ADR 0024.
//
// Auth contract:
//   * Caller MUST present a Supabase JWT (Authorization: Bearer ...).
//   * Caller MUST be a member of the client's practice.
//   * plan_id MUST belong to the named client_id.
// Failing any of these returns 4xx; we do not silently swallow.
//
// Required env vars on the function:
//   * SUPABASE_URL                 — auto-injected
//   * SUPABASE_SERVICE_ROLE_KEY    — auto-injected
//   * RESEND_API_KEY               — Carl sets via supabase secrets set
//
// Optional env vars (defaults match docs/RESEND_SETUP.md):
//   * SEND_ARTIFACT_FROM           — default 'noreply@homefit.studio'
//   * SEND_ARTIFACT_FROM_NAME      — default 'homefit team'
//   * APP_URL_PLAYER               — default 'https://session.homefit.studio'

// deno-lint-ignore-file no-explicit-any
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.46.1';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY') ?? '';
const FROM_ADDRESS =
  Deno.env.get('SEND_ARTIFACT_FROM') ?? 'noreply@homefit.studio';
const FROM_NAME =
  Deno.env.get('SEND_ARTIFACT_FROM_NAME') ?? 'homefit team';
const PLAYER_BASE =
  Deno.env.get('APP_URL_PLAYER') ?? 'https://session.homefit.studio';

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

// Email syntactic check — match the RPC's regex so caller + DB agree.
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

// ---------------------------------------------------------------------------
// HTTP entry
// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      status: 200,
      headers: corsHeaders(),
    });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ ok: false, reason: 'method_not_allowed' }, 405);
  }

  // ---- 1. JWT extraction + verification ----
  const authHeader = req.headers.get('Authorization') ?? '';
  const jwt = authHeader.toLowerCase().startsWith('bearer ')
    ? authHeader.slice(7).trim()
    : '';

  if (!jwt) {
    return jsonResponse({ ok: false, reason: 'unauthenticated' }, 401);
  }

  const { data: userRes, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userRes?.user) {
    return jsonResponse({ ok: false, reason: 'unauthenticated' }, 401);
  }
  const callerId = userRes.user.id;

  // ---- 2. Payload parsing ----
  let payload: {
    plan_id?: string;
    client_id?: string;
    to?: string;
    message?: string;
  };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ ok: false, reason: 'bad_json' }, 400);
  }

  const planId = String(payload.plan_id ?? '').trim();
  const clientId = String(payload.client_id ?? '').trim();
  const to = String(payload.to ?? '').trim().toLowerCase();
  const message = typeof payload.message === 'string' ? payload.message.trim() : '';

  if (!planId || !clientId || !to) {
    return jsonResponse(
      { ok: false, reason: 'missing_field', detail: 'plan_id, client_id, to required' },
      400,
    );
  }

  if (!EMAIL_RE.test(to) || to.length > 254) {
    return jsonResponse({ ok: false, reason: 'invalid_email' }, 400);
  }

  if (message.length > 2000) {
    return jsonResponse(
      { ok: false, reason: 'message_too_long', detail: 'max 2000 chars' },
      400,
    );
  }

  // ---- 3. Resolve plan + client + practice; enforce membership ----
  let plan: {
    id: string;
    practice_id: string;
    client_id: string | null;
    title: string | null;
    version: number;
  } | null = null;
  try {
    const { data, error } = await admin
      .from('plans')
      .select('id, practice_id, client_id, title, version')
      .eq('id', planId)
      .is('deleted_at', null)
      .maybeSingle();
    if (error) throw error;
    plan = data as any;
  } catch (e) {
    return jsonResponse(
      { ok: false, reason: 'plan_lookup_failed', detail: String((e as Error)?.message ?? e) },
      500,
    );
  }
  if (!plan) {
    return jsonResponse({ ok: false, reason: 'plan_not_found' }, 404);
  }
  if (plan.client_id !== clientId) {
    return jsonResponse({ ok: false, reason: 'client_mismatch' }, 400);
  }

  // Caller must be a member of plan.practice_id.
  try {
    const { count, error } = await admin
      .from('practice_members')
      .select('practice_id', { head: true, count: 'exact' })
      .eq('practice_id', plan.practice_id)
      .eq('trainer_id', callerId);
    if (error) throw error;
    if (!count || count < 1) {
      return jsonResponse({ ok: false, reason: 'forbidden' }, 403);
    }
  } catch (e) {
    return jsonResponse(
      { ok: false, reason: 'membership_check_failed', detail: String((e as Error)?.message ?? e) },
      500,
    );
  }

  // ---- 4. Resolve client + practice brand identity ----
  let client: {
    id: string;
    name: string;
    email: string | null;
    email_verified_at: string | null;
  } | null = null;
  try {
    const { data, error } = await admin
      .from('clients')
      .select('id, name, email, email_verified_at')
      .eq('id', clientId)
      .is('deleted_at', null)
      .maybeSingle();
    if (error) throw error;
    client = data as any;
  } catch (e) {
    return jsonResponse(
      { ok: false, reason: 'client_lookup_failed', detail: String((e as Error)?.message ?? e) },
      500,
    );
  }
  if (!client) {
    return jsonResponse({ ok: false, reason: 'client_not_found' }, 404);
  }

  let practice: {
    id: string;
    name: string;
    brand_color: string | null;
    tagline: string | null;
    public_logo_url: string | null;
  } | null = null;
  try {
    const { data, error } = await admin
      .from('practices')
      .select('id, name, brand_color, tagline, public_logo_url')
      .eq('id', plan.practice_id)
      .maybeSingle();
    if (error) throw error;
    practice = data as any;
  } catch (e) {
    return jsonResponse(
      { ok: false, reason: 'practice_lookup_failed', detail: String((e as Error)?.message ?? e) },
      500,
    );
  }
  if (!practice) {
    return jsonResponse({ ok: false, reason: 'practice_not_found' }, 404);
  }

  // ---- 5. Send the email ----
  const handoutUrl = `${PLAYER_BASE.replace(/\/+$/, '')}/h/${encodeURIComponent(planId)}`;
  const planTitle = (plan.title ?? '').trim() || 'Your workout';
  const practitionerBrand = (practice.name ?? '').trim() || 'your practitioner';
  // brand_color is hex-validated by the practices table check constraint;
  // fall back to coral if absent.
  const accentColor = (practice.brand_color ?? '').trim() || '#FF6B35';

  let resendId: string | null = null;
  try {
    resendId = await sendBrandedEmail({
      to,
      clientName: client.name,
      planTitle,
      practitionerBrand,
      accentColor,
      handoutUrl,
      message,
      tagline: practice.tagline,
    });
  } catch (e) {
    return jsonResponse(
      {
        ok: false,
        reason: 'send_failed',
        detail: String((e as Error)?.message ?? e),
      },
      502,
    );
  }

  // ---- 6. Stamp clients.email via the RPC (skip if already verified) ----
  // We sit on top of the service-role connection but call set_client_email
  // with the CALLER's JWT so the RPC's membership check uses the right
  // auth.uid(). The RPC handles the verified-email refusal by virtue of
  // ALWAYS clearing email_verified_at on write — but we want the verified
  // address to stay verified, so we skip the call entirely when one exists.
  let emailStamped = false;
  if (!client.email_verified_at) {
    try {
      const callerClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
        auth: { persistSession: false },
        global: {
          headers: { Authorization: `Bearer ${jwt}` },
        },
      });
      const { data, error } = await callerClient.rpc('set_client_email', {
        p_client_id: clientId,
        p_email: to,
      });
      if (error) {
        // The send succeeded; the stamp didn't. Surface but don't fail.
        console.warn(
          `send-artifact-email: set_client_email failed plan=${planId} client=${clientId} err=${error.message}`,
        );
      } else {
        const okFlag = (data as any)?.ok === true;
        emailStamped = okFlag;
        if (!okFlag) {
          console.warn(
            `send-artifact-email: set_client_email returned ${JSON.stringify(data)}`,
          );
        }
      }
    } catch (e) {
      console.warn(
        `send-artifact-email: set_client_email threw plan=${planId} client=${clientId} err=${e}`,
      );
    }
  }

  return jsonResponse({
    ok: true,
    message_id: resendId,
    email_stamped: emailStamped,
    verified_email_preserved: !!client.email_verified_at,
  });
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
async function sendBrandedEmail(args: {
  to: string;
  clientName: string;
  planTitle: string;
  practitionerBrand: string;
  accentColor: string;
  handoutUrl: string;
  message: string;
  tagline: string | null;
}): Promise<string> {
  if (!RESEND_API_KEY) {
    throw new Error('RESEND_API_KEY missing');
  }
  const subject = `${args.planTitle} — your plan from ${args.practitionerBrand}`;

  const greetingName = (args.clientName ?? '').trim();
  const greeting = greetingName ? `Hi ${escapeHtml(greetingName)},` : 'Hi,';

  const html = `<!DOCTYPE html>
<html lang="en">
  <body style="margin:0;padding:0;background:#0F1117;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;color:#F0F0F5;">
    <div style="max-width:600px;margin:0 auto;background:#1A1D27;padding:32px 28px;border-radius:16px;margin-top:24px;margin-bottom:24px;">
      <div style="font-size:11px;letter-spacing:1.4px;text-transform:uppercase;color:${escapeHtml(args.accentColor)};font-weight:700;margin-bottom:8px;">
        ${escapeHtml(args.practitionerBrand)}
      </div>
      <h1 style="font-family:'Montserrat',-apple-system,sans-serif;font-weight:700;font-size:22px;color:#FFFFFF;margin:0 0 20px;letter-spacing:-0.2px;">
        Your workout is ready
      </h1>
      <div style="font-size:15px;line-height:1.55;color:#D1D5DB;margin-bottom:20px;">
        ${greeting}
      </div>
      <div style="font-size:15px;line-height:1.55;color:#D1D5DB;margin-bottom:24px;">
        ${escapeHtml(args.practitionerBrand)} has shared
        <strong style="color:#F0F0F5;">${escapeHtml(args.planTitle)}</strong>
        with you. Tap the button below to open it on any device — no app, no sign-in.
      </div>
      ${
        args.message
          ? `<div style="background:#242733;border-left:3px solid ${escapeHtml(args.accentColor)};padding:14px 16px;border-radius:8px;margin-bottom:24px;">
              <div style="font-size:11px;letter-spacing:1px;text-transform:uppercase;color:#9CA3AF;font-weight:600;margin-bottom:6px;">
                Your practitioner says
              </div>
              <div style="font-size:14px;line-height:1.55;color:#F0F0F5;white-space:pre-wrap;">${escapeHtml(args.message)}</div>
            </div>`
          : ''
      }
      <div style="text-align:center;margin:32px 0 24px;">
        <a href="${escapeAttr(args.handoutUrl)}" style="display:inline-block;background:${escapeHtml(args.accentColor)};color:#FFFFFF;font-family:'Montserrat',-apple-system,sans-serif;font-weight:700;font-size:14px;letter-spacing:0.3px;text-decoration:none;padding:14px 28px;border-radius:12px;box-shadow:0 6px 16px rgba(0,0,0,0.32);">
          Open your workout
        </a>
      </div>
      <div style="font-size:12px;color:#6B7280;line-height:1.5;margin-bottom:8px;">
        Or paste this link into your browser:
      </div>
      <div style="font-size:12px;color:#9CA3AF;word-break:break-all;font-family:ui-monospace,'SF Mono',Menlo,monospace;background:#0F1117;padding:10px 12px;border-radius:8px;border:1px solid #2E3140;">
        ${escapeHtml(args.handoutUrl)}
      </div>
      ${
        args.tagline
          ? `<div style="margin-top:24px;font-size:12px;color:#9CA3AF;font-style:italic;text-align:center;">
              "${escapeHtml(args.tagline)}"
            </div>`
          : ''
      }
    </div>
    <div style="max-width:600px;margin:0 auto;text-align:center;font-size:11px;color:#6B7280;padding-bottom:32px;">
      Sent by homefit.studio on behalf of ${escapeHtml(args.practitionerBrand)}.
    </div>
  </body>
</html>`;

  const textParts = [
    `${args.practitionerBrand} has shared a workout with you.`,
    '',
    `Plan: ${args.planTitle}`,
    '',
    args.message ? `Your practitioner says:\n${args.message}\n` : '',
    `Open your workout: ${args.handoutUrl}`,
    '',
    '— homefit.studio',
  ].filter((s) => s !== '');
  const text = textParts.join('\n');

  const body = {
    from: `${FROM_NAME} <${FROM_ADDRESS}>`,
    to: [args.to],
    subject,
    html,
    text,
  };

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    throw new Error(`resend status=${response.status} body=${detail}`);
  }
  const json = (await response.json().catch(() => null)) as
    | { id?: string }
    | null;
  return json?.id ?? '';
}

function jsonResponse(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders() },
  });
}

function corsHeaders(): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers':
      'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
}

function escapeHtml(s: string): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) =>
    (
      {
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;',
      } as Record<string, string>
    )[c],
  );
}

function escapeAttr(s: string): string {
  // URLs go into href; HTML escape covers it, but we add belt-and-braces
  // for the few extra attr-context bytes.
  return escapeHtml(s);
}
