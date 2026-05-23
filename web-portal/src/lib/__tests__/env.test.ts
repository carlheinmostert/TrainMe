import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { requireEnv } from '../env';

describe('requireEnv', () => {
  const originalPhase = process.env.NEXT_PHASE;

  afterEach(() => {
    process.env.NEXT_PHASE = originalPhase;
  });

  it('returns the value when set and non-empty', () => {
    expect(requireEnv('MY_VAR', 'https://example.com')).toBe('https://example.com');
  });

  it('throws when value is undefined at runtime', () => {
    process.env.NEXT_PHASE = undefined;
    expect(() => requireEnv('MY_VAR', undefined)).toThrow('MY_VAR is not set');
  });

  it('throws when value is an empty string at runtime', () => {
    process.env.NEXT_PHASE = undefined;
    expect(() => requireEnv('MY_VAR', '')).toThrow('MY_VAR is not set');
  });

  it('returns the placeholder during next build phase when value is missing', () => {
    process.env.NEXT_PHASE = 'phase-production-build';
    const result = requireEnv('MY_VAR', undefined, 'build-placeholder');
    expect(result).toBe('build-placeholder');
  });

  it('still returns value during build phase when value is present', () => {
    process.env.NEXT_PHASE = 'phase-production-build';
    const result = requireEnv('MY_VAR', 'real-value', 'build-placeholder');
    expect(result).toBe('real-value');
  });

  it('throws during build phase when value is missing and no placeholder given', () => {
    process.env.NEXT_PHASE = 'phase-production-build';
    expect(() => requireEnv('MY_VAR', undefined)).toThrow('MY_VAR is not set');
  });

  it('error message mentions the variable name', () => {
    process.env.NEXT_PHASE = undefined;
    expect(() => requireEnv('SOME_SECRET', undefined)).toThrow('SOME_SECRET is not set');
  });

  it('error message points to env config docs', () => {
    process.env.NEXT_PHASE = undefined;
    expect(() => requireEnv('VAR', undefined)).toThrow('HARDCODED-AUDIT');
  });
});
