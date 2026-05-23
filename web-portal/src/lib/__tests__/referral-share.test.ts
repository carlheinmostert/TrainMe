import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

// Mock the env module so tests don't need NEXT_PUBLIC_APP_URL set.
vi.mock('../env', () => ({
  appUrl: () => 'https://manage.homefit.studio',
  supabaseUrl: () => 'https://test.supabase.co',
  supabaseAnonKey: () => 'test-anon-key',
  webPlayerBaseUrl: () => 'https://session.homefit.studio',
  requireEnv: (name: string, value: string | undefined) => {
    if (!value) throw new Error(`${name} is not set`);
    return value;
  },
}));

import {
  referralUrl,
  shareMessage,
  shareEmailSubject,
  shareEmailBody,
  whatsappHref,
  imessageHref,
  mailtoHref,
} from '../referral-share';

const TEST_CODE = 'K3JT7QR';
const BASE_URL = 'https://manage.homefit.studio';

describe('referralUrl', () => {
  it('builds a URL at the portal domain', () => {
    expect(referralUrl(TEST_CODE)).toBe(`${BASE_URL}/r/${TEST_CODE}`);
  });

  it('includes the code verbatim', () => {
    const code = 'ABCDE12';
    expect(referralUrl(code)).toContain(code);
  });
});

describe('shareMessage', () => {
  it('contains the referral URL', () => {
    const msg = shareMessage(TEST_CODE);
    expect(msg).toContain(referralUrl(TEST_CODE));
  });

  it('mentions homefit.studio', () => {
    expect(shareMessage(TEST_CODE)).toContain('homefit.studio');
  });

  it('is a non-empty string', () => {
    expect(shareMessage(TEST_CODE).length).toBeGreaterThan(0);
  });
});

describe('shareEmailSubject', () => {
  it('returns a non-empty subject line', () => {
    expect(shareEmailSubject().length).toBeGreaterThan(0);
  });

  it('mentions homefit.studio', () => {
    expect(shareEmailSubject().toLowerCase()).toContain('homefit.studio');
  });
});

describe('shareEmailBody', () => {
  it('contains the referral URL', () => {
    const body = shareEmailBody(TEST_CODE);
    expect(body).toContain(referralUrl(TEST_CODE));
  });

  it('is a multi-line string', () => {
    expect(shareEmailBody(TEST_CODE)).toContain('\n');
  });

  it('does not contain marketing words', () => {
    const body = shareEmailBody(TEST_CODE).toLowerCase();
    const disallowed = ['earn', 'commission', 'reward', 'cash', 'payout'];
    for (const word of disallowed) {
      expect(body).not.toContain(word);
    }
  });
});

describe('whatsappHref', () => {
  it('starts with wa.me', () => {
    expect(whatsappHref(TEST_CODE)).toMatch(/^https:\/\/wa\.me\//);
  });

  it('contains a URL-encoded text parameter', () => {
    expect(whatsappHref(TEST_CODE)).toContain('text=');
  });

  it('encodes the referral URL', () => {
    const href = whatsappHref(TEST_CODE);
    // The URL itself will be percent-encoded inside the href
    expect(href).toContain(encodeURIComponent(BASE_URL));
  });
});

describe('imessageHref', () => {
  it('starts with sms:', () => {
    expect(imessageHref(TEST_CODE)).toMatch(/^sms:/);
  });

  it('contains a body parameter', () => {
    expect(imessageHref(TEST_CODE)).toContain('body=');
  });
});

describe('mailtoHref', () => {
  it('starts with mailto:', () => {
    expect(mailtoHref(TEST_CODE)).toMatch(/^mailto:/);
  });

  it('includes subject and body parameters', () => {
    const href = mailtoHref(TEST_CODE);
    expect(href).toContain('subject=');
    expect(href).toContain('body=');
  });

  it('encodes special characters in body', () => {
    const href = mailtoHref(TEST_CODE);
    // Spaces and newlines must be percent-encoded
    expect(href).not.toMatch(/body=[^%]*\s/);
  });
});
