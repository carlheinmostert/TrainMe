import { describe, it, expect, vi, beforeEach } from 'vitest';

/**
 * Unit tests for `resolvePracticeId`.
 *
 * `next/headers` is a Next.js server-only API that throws outside the App
 * Router request context. We mock it here so the resolution logic can be
 * tested without a running Next.js server. The mock models the real API:
 * a `cookies()` function that returns an object with a `get(name)` method.
 *
 * `resolvePracticeId` encapsulates the three-line pattern that was
 * previously copy-pasted across 7 server-component pages:
 *
 *   const cookieStore = await cookies();
 *   const cookiePractice = cookieStore.get(ACTIVE_PRACTICE_COOKIE)?.value ?? '';
 *   const practiceId = params.practice ?? cookiePractice;
 *
 * The function is the single definition — all pages import and call it.
 */

// Mock next/headers before importing the module under test so the
// import-time resolution doesn't hit the real Next.js runtime.
const mockGet = vi.fn();
vi.mock('next/headers', () => ({
  cookies: () => Promise.resolve({ get: mockGet }),
}));

// Import after mock registration.
const { resolvePracticeId } = await import('../resolve-practice-id');

const COOKIE_NAME = 'hf_active_practice';
const EXAMPLE_UUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
const OTHER_UUID = 'b2c3d4e5-f6a7-8901-bcde-f01234567891';

beforeEach(() => {
  mockGet.mockReset();
});

describe('resolvePracticeId', () => {
  describe('when a search-param value is present', () => {
    it('returns the search-param value without reading the cookie', async () => {
      mockGet.mockReturnValue(undefined);
      const result = await resolvePracticeId(EXAMPLE_UUID);
      expect(result).toBe(EXAMPLE_UUID);
      expect(mockGet).not.toHaveBeenCalled();
    });

    it('prefers the search-param over the cookie when both are set', async () => {
      mockGet.mockReturnValue({ name: COOKIE_NAME, value: OTHER_UUID });
      const result = await resolvePracticeId(EXAMPLE_UUID);
      expect(result).toBe(EXAMPLE_UUID);
    });
  });

  describe('when no search-param is present', () => {
    it('returns the cookie value when the cookie is set', async () => {
      mockGet.mockReturnValue({ name: COOKIE_NAME, value: EXAMPLE_UUID });
      const result = await resolvePracticeId(undefined);
      expect(result).toBe(EXAMPLE_UUID);
      expect(mockGet).toHaveBeenCalledWith(COOKIE_NAME);
    });

    it('returns null when the cookie is also absent', async () => {
      mockGet.mockReturnValue(undefined);
      const result = await resolvePracticeId(undefined);
      expect(result).toBeNull();
    });

    it('returns null when given an empty string param (treated as absent)', async () => {
      mockGet.mockReturnValue(undefined);
      // An empty string is falsy — callers pass `params.practice` which
      // can be an empty string from an empty query param; falsy check
      // falls through to cookie.
      const result = await resolvePracticeId('');
      expect(result).toBeNull();
    });
  });
});
