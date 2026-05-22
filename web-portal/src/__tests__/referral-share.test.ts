import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

// We mock the env module so referralUrl() doesn't need NEXT_PUBLIC_APP_URL.
vi.mock('@/lib/env', () => ({
  appUrl: () => 'https://manage.homefit.studio',
}));

// Import after mock is declared so the mock is applied.
const { referralUrl, shareMessage, whatsappHref, imessageHref, mailtoHref } =
  await import('@/lib/referral-share');

describe('referralUrl', () => {
  it('builds the /r/{code} URL under the portal base', () => {
    expect(referralUrl('ABC1234')).toBe(
      'https://manage.homefit.studio/r/ABC1234',
    );
  });

  it('URI-encodes nothing for a clean 7-char code', () => {
    const url = referralUrl('XYZ9876');
    expect(url).not.toContain('%');
  });
});

describe('shareMessage', () => {
  it('contains the referral URL', () => {
    const msg = shareMessage('ABC1234');
    expect(msg).toContain('https://manage.homefit.studio/r/ABC1234');
  });

  it('contains homefit.studio in the copy', () => {
    const msg = shareMessage('ABC1234');
    expect(msg).toContain('homefit.studio');
  });

  it('does not use earning/commission/reward language (R-06)', () => {
    const msg = shareMessage('ABC1234').toLowerCase();
    expect(msg).not.toContain('earn');
    expect(msg).not.toContain('commission');
    expect(msg).not.toContain('reward');
    expect(msg).not.toContain('cash');
  });
});

describe('whatsappHref', () => {
  it('starts with the WhatsApp deep-link scheme', () => {
    expect(whatsappHref('ABC1234')).toMatch(/^https:\/\/wa\.me\/\?text=/);
  });

  it('URL-encodes the message body', () => {
    const href = whatsappHref('ABC1234');
    expect(href).toContain('%3A'); // encoded ':'
  });
});

describe('imessageHref', () => {
  it('starts with sms: scheme', () => {
    expect(imessageHref('ABC1234')).toMatch(/^sms:/);
  });

  it('includes the encoded message body', () => {
    const href = imessageHref('ABC1234');
    expect(href).toContain('body=');
  });
});

describe('mailtoHref', () => {
  it('starts with mailto: scheme', () => {
    expect(mailtoHref('ABC1234')).toMatch(/^mailto:/);
  });

  it('includes an encoded subject', () => {
    const href = mailtoHref('ABC1234');
    expect(href).toContain('subject=');
  });

  it('includes an encoded body', () => {
    const href = mailtoHref('ABC1234');
    expect(href).toContain('body=');
  });

  it('includes the referral URL in the body', () => {
    const href = mailtoHref('ABC1234');
    const body = decodeURIComponent(href.split('body=')[1]);
    expect(body).toContain('https://manage.homefit.studio/r/ABC1234');
  });
});
