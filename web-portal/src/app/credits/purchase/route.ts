import { NextResponse } from 'next/server';
import { randomUUID } from 'node:crypto';
import { getServerClient } from '@/lib/supabase-server';
import { createAdminApi, createPortalApi } from '@/lib/supabase/api';
import { getBundle, formatAmountZar } from '@/lib/bundles';
import {
  buildCheckoutUrl,
  getAppUrl,
  getMerchantConfig,
  type PayFastPayload,
} from '@/lib/payfast';

// Milestone D4: PayFast checkout.
//
// Flow:
//   1. Verify the caller is authenticated and a member of the target practice.
//   2. Look up the bundle's price + credits from the shared catalog.
//   3. Insert a `pending_payments` row as the server-side intent record —
//      this is the source of truth the ITN webhook matches against. We use
//      the service role because the browser-side anon session can only write
//      to its own practice's ledger, and `pending_payments` INSERT is service
//      role only by design (webhook writes to it later too).
//   4. Build the PayFast payload in the ORDER that matches PayFast's docs
//      (merchant → URLs → buyer → transaction → item). Order matters: the
//      signature base preserves insertion order.
//   5. Compute the MD5 signature over that payload and return a full URL
//      the client can redirect to.
//
// We accept BOTH JSON and form-encoded bodies so the /credits page's plain
// `<form action="/credits/purchase" method="post">` works without JS, and
// future XHR callers can post JSON too.

export async function POST(request: Request) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.json({ error: 'unauthenticated' }, { status: 401 });
  }

  // Parse either JSON or form body.
  const contentType = request.headers.get('content-type') ?? '';
  let bundleKey = '';
  let practiceId = '';
  if (contentType.includes('application/json')) {
    const body = (await request.json().catch(() => ({}))) as {
      bundleKey?: string;
      bundle?: string;
      practiceId?: string;
      practice?: string;
    };
    bundleKey = body.bundleKey ?? body.bundle ?? '';
    practiceId = body.practiceId ?? body.practice ?? '';
  } else {
    const form = await request.formData();
    bundleKey = String(form.get('bundle') ?? form.get('bundleKey') ?? '');
    practiceId = String(form.get('practice') ?? form.get('practiceId') ?? '');
  }

  const bundle = getBundle(bundleKey);
  if (!bundle) {
    return NextResponse.json({ error: 'unknown bundle' }, { status: 400 });
  }
  if (!practiceId) {
    return NextResponse.json({ error: 'practice required' }, { status: 400 });
  }

  // Verify the user is an OWNER of this practice before we spend a
  // pending_payments row on them. Per CLAUDE.md tenancy model: owners
  // buy credits, practitioners consume them. Practitioner-or-null role
  // both fall through to 403.
  //
  // /credits/page.tsx gates the UI so the Buy buttons don't render for
  // practitioners; this is belt-and-braces against direct POSTs (or
  // a Buy-button click that survived a server render race).
  const api = createPortalApi(supabase);
  const role = await api.getCurrentUserRole(practiceId, user.id);
  if (role !== 'owner') {
    return NextResponse.json({ error: 'owner role required' }, { status: 403 });
  }

  // Record intent server-side using the service role. The anon key can't
  // insert into pending_payments by design (webhook-only table).
  let admin;
  try {
    admin = await createAdminApi();
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : 'admin init failed' },
      { status: 500 },
    );
  }

  const mPaymentId = randomUUID();
  try {
    await admin.insertPendingPayment({
      id: mPaymentId,
      practice_id: practiceId,
      credits: bundle.credits,
      amount_zar: bundle.priceZar,
      status: 'pending',
      bundle_key: bundle.key,
    });
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : 'insert failed' },
      { status: 500 },
    );
  }

  const appUrl = getAppUrl();
  const { merchantId, merchantKey, passphrase, sandbox } = getMerchantConfig();
  if (!merchantId || !merchantKey) {
    return NextResponse.json(
      { error: 'PayFast merchant credentials not configured' },
      { status: 500 },
    );
  }

  // Notify URL points at the Supabase edge function (not the Next app) so
  // ITNs survive redeploys and so the service-role key stays off the portal.
  const supabaseUrl =
    process.env.NEXT_PUBLIC_SUPABASE_URL ??
    'https://yrwcofhovrcydootivjx.supabase.co';
  const notifyUrl = `${supabaseUrl.replace(/\/$/, '')}/functions/v1/payfast-webhook`;

  // ORDER MATTERS. Keep this in the exact order PayFast documents.
  const payload: PayFastPayload = {
    merchant_id: merchantId,
    merchant_key: merchantKey,
    return_url: `${appUrl}/credits/return?pid=${mPaymentId}`,
    cancel_url: `${appUrl}/credits/cancel?pid=${mPaymentId}`,
    notify_url: notifyUrl,
    // Buyer fields are optional but PayFast pre-fills them when present.
    email_address: user.email ?? '',
    m_payment_id: mPaymentId,
    amount: formatAmountZar(bundle.priceZar),
    item_name: `homefit.studio ${bundle.name} Bundle`,
    item_description: `${bundle.credits} plan credits`,
    // Echo the bundle + practice back on the ITN for defence-in-depth; the
    // webhook still looks up from pending_payments as the source of truth.
    custom_str1: bundle.key,
    custom_str2: practiceId,
  };

  const checkoutUrl = buildCheckoutUrl(payload, { sandbox, passphrase });
  return NextResponse.json({ checkoutUrl });
}

// GET remains a simple healthcheck so ops can probe the route.
export async function GET() {
  const { sandbox } = getMerchantConfig();
  return NextResponse.json({
    status: 'ok',
    sandbox,
    milestone: 'D4',
  });
}
