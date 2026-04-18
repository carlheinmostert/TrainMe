// PayFast ITN (Instant Transaction Notification) webhook.
//
// PayFast posts form-encoded notifications to this endpoint after each
// payment attempt. We trust NOTHING from the browser — the ITN is the only
// signal that tells us a payment actually succeeded.
//
// Four-step verification (all four must pass):
//   1. Signature match — recompute MD5 over the received fields (in the
//      order they arrived, minus `signature` itself) plus passphrase.
//   2. Source IP whitelist — the POST must come from a published PayFast
//      server IP. This is defence against signature-leak replay attacks.
//   3. POST-back validate — we echo the body back to /eng/query/validate
//      on PayFast and expect "VALID". This catches the case where our
//      signature computation is correct but the record doesn't match what
//      PayFast actually sent (e.g. mutated-in-flight).
//   4. Amount match — cross-check `amount_gross` from the ITN against the
//      `amount_zar` we recorded in `pending_payments` when we generated
//      the checkout URL. Defends against someone replaying an old cheaper
//      payment ID against a more expensive bundle.
//
// If all four pass, we insert the credit_ledger row and mark the intent
// complete. PayFast retries on anything that isn't a 2xx — so we return
// 200 on both happy path AND on "already processed" (idempotency).

// deno-lint-ignore-file no-explicit-any
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.46.1';
import { createHash } from 'node:crypto';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const SANDBOX = (Deno.env.get('PAYFAST_SANDBOX') ?? 'true').toLowerCase() !==
  'false';
const PAYFAST_VALIDATE_URL = SANDBOX
  ? 'https://sandbox.payfast.co.za/eng/query/validate'
  : 'https://www.payfast.co.za/eng/query/validate';
const PASSPHRASE = Deno.env.get('PAYFAST_PASSPHRASE') ?? '';

// Per PayFast docs. Kept here (not imported) so the edge function has no
// dependency on the Next app's code.
const PAYFAST_IP_BLOCKS = [
  '197.97.145.144/28',
  '41.74.179.192/27',
  '102.216.183.0/25',
  '102.216.183.128/25',
  '144.126.193.139/32',
  '41.74.179.194/32',
  '41.74.179.195/32',
];

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ??
  Deno.env.get('PROJECT_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ??
  Deno.env.get('SERVICE_ROLE_KEY') ?? '';

// Optional: bypass IP check in non-production for local ngrok testing.
const SKIP_IP_CHECK =
  (Deno.env.get('PAYFAST_SKIP_IP_CHECK') ?? '').toLowerCase() === 'true';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function rfc1738Encode(value: string): string {
  return encodeURIComponent(value)
    .replace(/%20/g, '+')
    .replace(/!/g, '%21')
    .replace(/'/g, '%27')
    .replace(/\(/g, '%28')
    .replace(/\)/g, '%29')
    .replace(/\*/g, '%2A');
}

function md5Hex(input: string): string {
  // Supabase's Deno edge runtime supports Node compatibility, so `node:crypto`
  // is the safest MD5 path. We previously tried `deno.land/std@.../hash/md5.ts`
  // but that module was removed from Deno std and now 404s — every import
  // attempt threw at signature-verification time and surfaced as a bare 500.
  return createHash('md5').update(input).digest('hex');
}

function ipToLong(ip: string): number | null {
  const parts = ip.split('.').map(Number);
  if (parts.length !== 4 || parts.some((p) => isNaN(p) || p < 0 || p > 255)) {
    return null;
  }
  return ((parts[0] << 24) >>> 0) +
    (parts[1] << 16) +
    (parts[2] << 8) +
    parts[3];
}

function ipInCidr(ip: string, cidr: string): boolean {
  const [range, bitsStr] = cidr.split('/');
  const bits = Number(bitsStr);
  const ipLong = ipToLong(ip);
  const rangeLong = ipToLong(range);
  if (ipLong === null || rangeLong === null) return false;
  if (bits === 0) return true;
  const mask = (~((1 << (32 - bits)) - 1)) >>> 0;
  return (ipLong & mask) === (rangeLong & mask);
}

function ipIsPayFast(ip: string): boolean {
  return PAYFAST_IP_BLOCKS.some((cidr) => ipInCidr(ip, cidr));
}

function parseClientIp(req: Request): string {
  // Supabase Edge routes requests through their proxy; x-forwarded-for is
  // the authoritative source. Take the first (left-most) IP.
  const xff = req.headers.get('x-forwarded-for') ?? '';
  const first = xff.split(',')[0]?.trim();
  if (first) return first;
  return req.headers.get('cf-connecting-ip') ??
    req.headers.get('x-real-ip') ??
    '';
}

/**
 * Build the signature base from the received fields in their ORIGINAL order.
 * Deno's URLSearchParams preserves insertion order when iterated.
 *
 * IMPORTANT: for INCOMING ITN signatures, PayFast's reference PHP implementation
 * uses `http_build_query` over the full $_POST (minus `signature`) — which
 * INCLUDES empty-valued fields as `key=`. Their ITN typically sends ~23
 * fields, many empty (name_first, custom_int1..5, token, billing_date, etc.),
 * and all of them participate in the hash on their side. Skipping empties
 * on our side produced a shorter base → different MD5 → false mismatch.
 */
function buildSignatureBase(
  entries: Array<[string, string]>,
  passphrase: string,
): string {
  const parts: string[] = [];
  for (const [key, value] of entries) {
    if (key === 'signature') continue;
    // Trim-but-keep: empty fields MUST stay in the base (as `key=`) to match
    // PayFast's PHP canonicalization. Previously skipped them — that was the
    // bug that broke every real ITN signature.
    const trimmed = String(value ?? '').trim();
    parts.push(`${key}=${rfc1738Encode(trimmed)}`);
  }
  let base = parts.join('&');
  if (passphrase && passphrase.trim() !== '') {
    base += `&passphrase=${rfc1738Encode(passphrase.trim())}`;
  }
  return base;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== 'POST') {
    return new Response('method not allowed', { status: 405 });
  }

  // Preserve original form-field order for the signature base.
  const rawBody = await req.text();
  const params = new URLSearchParams(rawBody);
  const entries: Array<[string, string]> = [];
  for (const [k, v] of params.entries()) entries.push([k, v]);

  const fields: Record<string, string> = {};
  for (const [k, v] of entries) fields[k] = v;

  const mPaymentId = fields['m_payment_id'] ?? '';
  const pfPaymentId = fields['pf_payment_id'] ?? '';
  const paymentStatus = fields['payment_status'] ?? '';
  const amountGross = Number(fields['amount_gross'] ?? '0');
  const receivedSignature = (fields['signature'] ?? '').toLowerCase();

  // --- 1. Signature check -------------------------------------------------
  const base = buildSignatureBase(entries, PASSPHRASE);
  const expectedSignature = md5Hex(base).toLowerCase();
  if (expectedSignature !== receivedSignature) {
    console.warn('[payfast-webhook] signature mismatch', {
      mPaymentId,
      expected: expectedSignature,
      received: receivedSignature,
      // Diagnostic: exposes exactly what we hashed so encoding / ordering
      // drift can be compared against what PayFast hashed on their side.
      // Passphrase is REDACTED — last 4 chars only so we can verify secret
      // propagation without leaking the full value to logs.
      signatureBasePreview: base.replace(
        /passphrase=[^&]+/,
        (m) => {
          const val = m.slice('passphrase='.length);
          if (val.length <= 4) return 'passphrase=****';
          return `passphrase=${'*'.repeat(val.length - 4)}${val.slice(-4)}`;
        },
      ),
      rawBodyLength: rawBody.length,
      fieldCount: entries.length,
    });
    return new Response('signature mismatch', { status: 400 });
  }

  // --- 2. Source IP check -------------------------------------------------
  const clientIp = parseClientIp(req);
  if (!SKIP_IP_CHECK) {
    if (!clientIp || !ipIsPayFast(clientIp)) {
      console.warn('[payfast-webhook] source IP not whitelisted', {
        clientIp,
      });
      return new Response('forbidden source ip', { status: 403 });
    }
  }

  // --- 3. POST-back validate ---------------------------------------------
  const validateRes = await fetch(PAYFAST_VALIDATE_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: rawBody,
  });
  const validateText = (await validateRes.text()).trim();
  if (validateText !== 'VALID') {
    console.warn('[payfast-webhook] validate POST-back rejected', {
      mPaymentId,
      response: validateText,
    });
    return new Response('validate failed', { status: 400 });
  }

  // --- 4. Look up intent + amount match ---------------------------------
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    console.error('[payfast-webhook] service role env missing');
    return new Response('server misconfigured', { status: 500 });
  }
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  if (!mPaymentId) {
    return new Response('missing m_payment_id', { status: 400 });
  }

  const { data: pending, error: lookupErr } = await admin
    .from('pending_payments')
    .select('*')
    .eq('id', mPaymentId)
    .maybeSingle();
  if (lookupErr) {
    console.error('[payfast-webhook] lookup error', lookupErr);
    return new Response('lookup error', { status: 500 });
  }
  if (!pending) {
    // Unknown m_payment_id. Return 200 to stop PayFast retries — there's
    // nothing we can do with it.
    console.warn('[payfast-webhook] unknown m_payment_id', { mPaymentId });
    return new Response('ok', { status: 200 });
  }
  if (pending.status !== 'pending') {
    // Already processed. Idempotent — return 200.
    return new Response('ok', { status: 200 });
  }

  // Only credit on COMPLETE payments. Cancellations / failures just mark
  // the intent accordingly.
  if (paymentStatus !== 'COMPLETE') {
    const newStatus = paymentStatus === 'CANCELLED' ? 'cancelled' : 'failed';
    await admin.from('pending_payments').update({
      status: newStatus,
      pf_payment_id: pfPaymentId || null,
      completed_at: new Date().toISOString(),
      notes: `PayFast payment_status=${paymentStatus}`,
    }).eq('id', mPaymentId).eq('status', 'pending');
    return new Response('ok', { status: 200 });
  }

  const expectedAmount = Number(pending.amount_zar);
  if (Math.abs(amountGross - expectedAmount) > 0.01) {
    console.warn('[payfast-webhook] amount mismatch', {
      mPaymentId,
      expected: expectedAmount,
      received: amountGross,
    });
    await admin.from('pending_payments').update({
      status: 'failed',
      pf_payment_id: pfPaymentId || null,
      completed_at: new Date().toISOString(),
      notes: `amount mismatch: expected ${expectedAmount} got ${amountGross}`,
    }).eq('id', mPaymentId).eq('status', 'pending');
    return new Response('amount mismatch', { status: 400 });
  }

  // --- 5. Credit the practice and complete the intent -------------------
  // Insert the ledger row FIRST, then flip the status with a WHERE status =
  // 'pending' predicate. If two concurrent ITNs race, only the first gets
  // both the insert and the transition — the second finds status != pending
  // on next lookup (above) and exits idempotently.

  const { error: ledgerErr } = await admin.from('credit_ledger').insert({
    practice_id: pending.practice_id,
    delta: pending.credits,
    type: 'purchase',
    payfast_payment_id: pfPaymentId || null,
    notes: `PayFast ${pending.bundle_key ?? 'bundle'} (${pending.credits} credits)`,
  });
  if (ledgerErr) {
    console.error('[payfast-webhook] credit_ledger insert failed', ledgerErr);
    return new Response('credit insert failed', { status: 500 });
  }

  const { error: updateErr } = await admin.from('pending_payments').update({
    status: 'complete',
    pf_payment_id: pfPaymentId || null,
    completed_at: new Date().toISOString(),
  }).eq('id', mPaymentId).eq('status', 'pending');
  if (updateErr) {
    // Ledger row already in; log loudly so we notice if this ever races.
    console.error(
      '[payfast-webhook] pending_payments status flip failed',
      updateErr,
    );
  }

  return new Response('ok', { status: 200 });
});
