import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { requireEnv } from '@/lib/env';

describe('requireEnv', () => {
  const originalPhase = process.env.NEXT_PHASE;

  afterEach(() => {
    if (originalPhase === undefined) {
      delete process.env.NEXT_PHASE;
    } else {
      process.env.NEXT_PHASE = originalPhase;
    }
  });

  beforeEach(() => {
    delete process.env.NEXT_PHASE;
  });

  it('returns the value when provided and non-empty', () => {
    expect(requireEnv('MY_VAR', 'https://example.supabase.co')).toBe(
      'https://example.supabase.co',
    );
  });

  it('throws when value is undefined at runtime', () => {
    expect(() => requireEnv('MY_VAR', undefined)).toThrow('MY_VAR is not set');
  });

  it('throws when value is empty string at runtime', () => {
    expect(() => requireEnv('MY_VAR', '')).toThrow('MY_VAR is not set');
  });

  it('includes the var name in the error message', () => {
    expect(() => requireEnv('NEXT_PUBLIC_SUPABASE_URL', undefined)).toThrow(
      'NEXT_PUBLIC_SUPABASE_URL is not set',
    );
  });

  it('returns the build-phase placeholder during next build', () => {
    process.env.NEXT_PHASE = 'phase-production-build';
    const result = requireEnv(
      'MY_VAR',
      undefined,
      'https://missing-placeholder.invalid',
    );
    expect(result).toBe('https://missing-placeholder.invalid');
  });

  it('throws during next build when no placeholder is supplied', () => {
    process.env.NEXT_PHASE = 'phase-production-build';
    expect(() => requireEnv('MY_VAR', undefined)).toThrow('MY_VAR is not set');
  });

  it('returns the real value even during build phase when value is set', () => {
    process.env.NEXT_PHASE = 'phase-production-build';
    expect(requireEnv('MY_VAR', 'real-value')).toBe('real-value');
  });
});
