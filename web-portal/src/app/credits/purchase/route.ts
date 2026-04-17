import { NextResponse } from 'next/server';
import { getServerClient } from '@/lib/supabase-server';

// Milestone D4 TODO:
//   1. Validate the signed-in user belongs to the target practice.
//   2. Look up the bundle price from a bundles table (not hardcoded).
//   3. Build a signed PayFast request (merchant_id + merchant_key +
//      passphrase MD5 signature) and redirect to the PayFast hosted
//      checkout URL.
//   4. Write an inflight `credit_ledger` row (`type='purchase'`, `delta=0`
//      or similar "pending" marker) and credit the final delta from the
//      PayFast ITN webhook only. Never trust the browser round-trip.
//   5. Redirect to a /credits/success page on return_url and /credits?cancel
//      on cancel_url.

export async function POST(request: Request) {
  const supabase = await getServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.redirect(new URL('/', request.url), { status: 303 });
  }

  // Stub — echoing the inputs back into a redirect so the happy path is
  // visible in the UI during development.
  const form = await request.formData();
  const bundle = String(form.get('bundle') ?? '');
  const practice = String(form.get('practice') ?? '');

  const stubCheckoutUrl = `about:blank#todo-payfast-d4?bundle=${encodeURIComponent(
    bundle,
  )}&practice=${encodeURIComponent(practice)}`;

  return NextResponse.json({ checkoutUrl: stubCheckoutUrl });
}

// GET returns JSON for easy debugging / healthcheck.
export async function GET() {
  return NextResponse.json({
    status: 'stub',
    message: 'Milestone D4 TODO — PayFast integration pending.',
  });
}
