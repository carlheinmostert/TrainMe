// PayFast signature + URL helpers.
//
// PayFast reference: https://developers.payfast.co.za/docs
//
// Signature algorithm (gotcha-heavy — see comments below):
//   1. Build a list of [key, value] pairs in the SAME ORDER that fields will
//      appear in the outgoing form / querystring. Crucially: NOT alpha sorted.
//      PayFast re-signs on their side using the order they receive the fields
//      in. If you sort alphabetically you'll get `signature mismatch` errors.
//   2. Exclude the `signature` field itself, and any empty / undefined values.
//   3. URL-encode each value using RFC1738 (application/x-www-form-urlencoded
//      style — space becomes `+`, not `%20`). PHP's `http_build_query` is the
//      reference implementation. JavaScript's `URLSearchParams.toString()`
//      matches this behaviour; `encodeURIComponent` does NOT (it uses %20).
//   4. Join as `key=value&key=value`.
//   5. If a passphrase is set on the merchant account, append
//      `&passphrase=<url-encoded passphrase>`. If the passphrase is empty,
//      omit this step entirely — appending `&passphrase=` produces a wrong
//      signature.
//   6. MD5 hash the resulting string and output lowercase hex.
//
// The ITN webhook recomputes the signature on the POST body it receives, in
// the order the fields arrive. Same algorithm, same helper.

import crypto from 'node:crypto';

export type PayFastField =
  | 'merchant_id'
  | 'merchant_key'
  | 'return_url'
  | 'cancel_url'
  | 'notify_url'
  | 'name_first'
  | 'name_last'
  | 'email_address'
  | 'm_payment_id'
  | 'amount'
  | 'item_name'
  | 'item_description'
  | 'custom_str1'
  | 'custom_str2'
  | 'custom_str3'
  | 'custom_str4'
  | 'custom_str5'
  | 'custom_int1'
  | 'custom_int2'
  | 'custom_int3'
  | 'custom_int4'
  | 'custom_int5'
  | 'email_confirmation'
  | 'confirmation_address'
  | 'payment_method';

export type PayFastPayload = Partial<Record<PayFastField, string>>;

/**
 * RFC1738 URL encoding — matches PHP's `http_build_query` which is what
 * PayFast uses on their side. Spaces become `+`, everything else matches
 * `encodeURIComponent`.
 */
export function rfc1738Encode(value: string): string {
  return encodeURIComponent(value)
    .replace(/%20/g, '+')
    // encodeURIComponent leaves ! ' ( ) * alone; RFC1738 encodes them.
    .replace(/!/g, '%21')
    .replace(/'/g, '%27')
    .replace(/\(/g, '%28')
    .replace(/\)/g, '%29')
    .replace(/\*/g, '%2A');
}

/**
 * Build the `key=value&key=value` string used for BOTH the signature base
 * and the redirect querystring. Order is significant — we iterate the
 * object's own keys, which in JS preserves insertion order.
 */
export function buildSignatureBase(
  payload: PayFastPayload,
  passphrase?: string,
): string {
  const parts: string[] = [];
  for (const [key, value] of Object.entries(payload)) {
    if (key === 'signature') continue;
    if (value === undefined || value === null) continue;
    const stringValue = String(value).trim();
    if (stringValue === '') continue;
    parts.push(`${key}=${rfc1738Encode(stringValue)}`);
  }
  let base = parts.join('&');
  if (passphrase && passphrase.trim() !== '') {
    base += `&passphrase=${rfc1738Encode(passphrase.trim())}`;
  }
  return base;
}

/** MD5 hex of the signature base string. Lowercase. */
export function computeSignature(
  payload: PayFastPayload,
  passphrase?: string,
): string {
  const base = buildSignatureBase(payload, passphrase);
  return crypto.createHash('md5').update(base).digest('hex');
}

/**
 * Build the full redirect URL the browser should be sent to. The signature
 * is derived from the payload EXCLUDING the signature itself, then appended
 * as the final field. PayFast accepts both `?key=val&...` on the process URL
 * and a POSTed form; we use GET because it's easier to test locally.
 */
export function buildCheckoutUrl(
  payload: PayFastPayload,
  opts: { sandbox?: boolean; passphrase?: string },
): string {
  const endpoint = opts.sandbox
    ? 'https://sandbox.payfast.co.za/eng/process'
    : 'https://www.payfast.co.za/eng/process';
  const signature = computeSignature(payload, opts.passphrase);
  const signed: PayFastPayload & { signature: string } = {
    ...payload,
    signature,
  };
  // Re-serialise using the same RFC1738 encoder so the browser's redirect
  // URL and PayFast's signature base use the same encoding for every value.
  const parts: string[] = [];
  for (const [key, value] of Object.entries(signed)) {
    if (value === undefined || value === null) continue;
    const stringValue = String(value).trim();
    if (stringValue === '') continue;
    parts.push(`${key}=${rfc1738Encode(stringValue)}`);
  }
  return `${endpoint}?${parts.join('&')}`;
}

/** Per PayFast docs — sandbox + production server IPs for ITN source checks. */
export const PAYFAST_IP_BLOCKS = [
  // Production
  '197.97.145.144/28',
  '41.74.179.192/27',
  '102.216.183.0/25',
  '102.216.183.128/25',
  '144.126.193.139/32',
  // Sandbox / testing
  '41.74.179.194/32',
  '41.74.179.195/32',
] as const;

export function isSandboxEnabled(): boolean {
  const flag = (process.env.PAYFAST_SANDBOX ?? 'true').toLowerCase();
  return flag !== 'false' && flag !== '0' && flag !== 'no';
}

/** Merchant config — falls back to PayFast's public sandbox creds. */
export function getMerchantConfig(): {
  merchantId: string;
  merchantKey: string;
  passphrase: string;
  sandbox: boolean;
} {
  const sandbox = isSandboxEnabled();
  return {
    merchantId:
      process.env.PAYFAST_MERCHANT_ID ?? (sandbox ? '10000100' : ''),
    merchantKey:
      process.env.PAYFAST_MERCHANT_KEY ?? (sandbox ? '46f0cd694581a' : ''),
    passphrase: process.env.PAYFAST_PASSPHRASE ?? '',
    sandbox,
  };
}

export function getAppUrl(): string {
  return (
    process.env.APP_URL ??
    process.env.NEXT_PUBLIC_APP_URL ??
    'http://localhost:3000'
  );
}
