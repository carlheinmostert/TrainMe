import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import {
  rfc1738Encode,
  buildSignatureBase,
  computeSignature,
  buildCheckoutUrl,
  isSandboxEnabled,
  getMerchantConfig,
  type PayFastPayload,
} from '@/lib/payfast';

// ── rfc1738Encode ─────────────────────────────────────────────────────────────

describe('rfc1738Encode', () => {
  it('encodes spaces as +', () => {
    expect(rfc1738Encode('hello world')).toBe('hello+world');
  });

  it('leaves unreserved chars alone', () => {
    expect(rfc1738Encode('abc123')).toBe('abc123');
  });

  it('encodes special characters', () => {
    expect(rfc1738Encode("it's a test!")).toContain('%27');
    expect(rfc1738Encode("it's a test!")).toContain('%21');
  });

  it('encodes parentheses and asterisk', () => {
    expect(rfc1738Encode('(test)')).toBe('%28test%29');
    expect(rfc1738Encode('a*b')).toBe('a%2Ab');
  });
});

// ── buildSignatureBase ────────────────────────────────────────────────────────

describe('buildSignatureBase', () => {
  it('joins key=value pairs with &', () => {
    const payload: PayFastPayload = {
      merchant_id: '10000100',
      merchant_key: '46f0cd694581a',
      amount: '250.00',
    };
    const base = buildSignatureBase(payload);
    expect(base).toBe(
      'merchant_id=10000100&merchant_key=46f0cd694581a&amount=250.00',
    );
  });

  it('excludes undefined and empty values', () => {
    const payload: PayFastPayload = {
      merchant_id: '10000100',
      name_first: '',
      amount: '250.00',
    };
    const base = buildSignatureBase(payload);
    expect(base).not.toContain('name_first');
    expect(base).toContain('merchant_id=10000100');
    expect(base).toContain('amount=250.00');
  });

  it('appends passphrase when set', () => {
    const payload: PayFastPayload = { merchant_id: '10000100' };
    const base = buildSignatureBase(payload, 'secret');
    expect(base).toContain('&passphrase=secret');
  });

  it('omits passphrase when empty string', () => {
    const payload: PayFastPayload = { merchant_id: '10000100' };
    const base = buildSignatureBase(payload, '');
    expect(base).not.toContain('passphrase');
  });

  it('preserves insertion order (not alphabetical)', () => {
    const payload: PayFastPayload = {
      amount: '100.00',
      merchant_id: '10000100',
    };
    const base = buildSignatureBase(payload);
    const amountPos = base.indexOf('amount');
    const merchantPos = base.indexOf('merchant_id');
    expect(amountPos).toBeLessThan(merchantPos);
  });
});

// ── computeSignature ─────────────────────────────────────────────────────────

describe('computeSignature', () => {
  it('returns a 32-char lowercase hex string', () => {
    const sig = computeSignature({ merchant_id: '10000100', amount: '250.00' });
    expect(sig).toMatch(/^[0-9a-f]{32}$/);
  });

  it('is deterministic for the same payload', () => {
    const payload: PayFastPayload = { merchant_id: '10000100', amount: '250.00' };
    expect(computeSignature(payload)).toBe(computeSignature(payload));
  });

  it('changes when payload changes', () => {
    const a = computeSignature({ merchant_id: '10000100', amount: '250.00' });
    const b = computeSignature({ merchant_id: '10000100', amount: '251.00' });
    expect(a).not.toBe(b);
  });

  it('changes when passphrase changes', () => {
    const payload: PayFastPayload = { merchant_id: '10000100' };
    const withPass = computeSignature(payload, 'secret');
    const withoutPass = computeSignature(payload);
    expect(withPass).not.toBe(withoutPass);
  });
});

// ── buildCheckoutUrl ─────────────────────────────────────────────────────────

describe('buildCheckoutUrl', () => {
  it('uses sandbox endpoint when sandbox=true', () => {
    const url = buildCheckoutUrl({ merchant_id: '10000100' }, { sandbox: true });
    expect(url).toContain('sandbox.payfast.co.za');
  });

  it('uses production endpoint when sandbox=false', () => {
    const url = buildCheckoutUrl({ merchant_id: '10000100' }, { sandbox: false });
    expect(url).toContain('www.payfast.co.za');
  });

  it('includes a signature query param', () => {
    const url = buildCheckoutUrl({ merchant_id: '10000100' }, { sandbox: true });
    expect(url).toContain('signature=');
  });
});

// ── isSandboxEnabled ─────────────────────────────────────────────────────────

describe('isSandboxEnabled', () => {
  const original = process.env.PAYFAST_SANDBOX;

  afterEach(() => {
    if (original === undefined) {
      delete process.env.PAYFAST_SANDBOX;
    } else {
      process.env.PAYFAST_SANDBOX = original;
    }
  });

  it('defaults to sandbox when env var is unset', () => {
    delete process.env.PAYFAST_SANDBOX;
    expect(isSandboxEnabled()).toBe(true);
  });

  it('returns false when set to "false"', () => {
    process.env.PAYFAST_SANDBOX = 'false';
    expect(isSandboxEnabled()).toBe(false);
  });

  it('returns false when set to "0"', () => {
    process.env.PAYFAST_SANDBOX = '0';
    expect(isSandboxEnabled()).toBe(false);
  });

  it('returns false when set to "no"', () => {
    process.env.PAYFAST_SANDBOX = 'no';
    expect(isSandboxEnabled()).toBe(false);
  });

  it('returns true when set to "true"', () => {
    process.env.PAYFAST_SANDBOX = 'true';
    expect(isSandboxEnabled()).toBe(true);
  });
});

// ── getMerchantConfig ────────────────────────────────────────────────────────

describe('getMerchantConfig', () => {
  const savedVars = {
    PAYFAST_SANDBOX: process.env.PAYFAST_SANDBOX,
    PAYFAST_MERCHANT_ID: process.env.PAYFAST_MERCHANT_ID,
    PAYFAST_MERCHANT_KEY: process.env.PAYFAST_MERCHANT_KEY,
    PAYFAST_PASSPHRASE: process.env.PAYFAST_PASSPHRASE,
  };

  afterEach(() => {
    for (const [k, v] of Object.entries(savedVars)) {
      if (v === undefined) {
        delete process.env[k];
      } else {
        process.env[k] = v;
      }
    }
  });

  it('returns sandbox fallback credentials when sandbox=true and no env vars set', () => {
    process.env.PAYFAST_SANDBOX = 'true';
    delete process.env.PAYFAST_MERCHANT_ID;
    delete process.env.PAYFAST_MERCHANT_KEY;
    const config = getMerchantConfig();
    expect(config.sandbox).toBe(true);
    expect(config.merchantId).toBe('10000100');
    expect(config.merchantKey).toBe('46f0cd694581a');
  });

  it('uses provided env vars in sandbox mode', () => {
    process.env.PAYFAST_SANDBOX = 'true';
    process.env.PAYFAST_MERCHANT_ID = 'my_sandbox_id';
    process.env.PAYFAST_MERCHANT_KEY = 'my_sandbox_key';
    const config = getMerchantConfig();
    expect(config.merchantId).toBe('my_sandbox_id');
    expect(config.merchantKey).toBe('my_sandbox_key');
  });

  it('throws when production mode and PAYFAST_MERCHANT_ID is missing', () => {
    process.env.PAYFAST_SANDBOX = 'false';
    delete process.env.PAYFAST_MERCHANT_ID;
    process.env.PAYFAST_MERCHANT_KEY = 'some_key';
    expect(() => getMerchantConfig()).toThrow(/PAYFAST_MERCHANT_ID/);
  });

  it('throws when production mode and PAYFAST_MERCHANT_KEY is missing', () => {
    process.env.PAYFAST_SANDBOX = 'false';
    process.env.PAYFAST_MERCHANT_ID = 'some_id';
    delete process.env.PAYFAST_MERCHANT_KEY;
    expect(() => getMerchantConfig()).toThrow(/PAYFAST_MERCHANT_KEY/);
  });

  it('returns production credentials when both env vars are set and sandbox=false', () => {
    process.env.PAYFAST_SANDBOX = 'false';
    process.env.PAYFAST_MERCHANT_ID = 'prod_id';
    process.env.PAYFAST_MERCHANT_KEY = 'prod_key';
    const config = getMerchantConfig();
    expect(config.sandbox).toBe(false);
    expect(config.merchantId).toBe('prod_id');
    expect(config.merchantKey).toBe('prod_key');
  });
});
