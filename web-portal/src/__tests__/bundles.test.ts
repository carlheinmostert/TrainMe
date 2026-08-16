import { describe, it, expect } from 'vitest';
import { BUNDLES, getBundle, zar, formatAmountZar } from '@/lib/bundles';

describe('BUNDLES catalog', () => {
  it('has exactly three bundles', () => {
    expect(BUNDLES).toHaveLength(3);
  });

  it('has keys starter, practice, clinic in that order', () => {
    expect(BUNDLES.map((b) => b.key)).toEqual(['starter', 'practice', 'clinic']);
  });

  it('each bundle has a positive credit count', () => {
    BUNDLES.forEach((b) => expect(b.credits).toBeGreaterThan(0));
  });

  it('each bundle has a positive price', () => {
    BUNDLES.forEach((b) => expect(b.priceZar).toBeGreaterThan(0));
  });

  it('starter is the cheapest bundle', () => {
    const sorted = [...BUNDLES].sort((a, b) => a.priceZar - b.priceZar);
    expect(sorted[0].key).toBe('starter');
  });

  it('clinic is the most expensive bundle', () => {
    const sorted = [...BUNDLES].sort((a, b) => b.priceZar - a.priceZar);
    expect(sorted[0].key).toBe('clinic');
  });
});

describe('getBundle', () => {
  it('returns the starter bundle', () => {
    const bundle = getBundle('starter');
    expect(bundle).toBeDefined();
    expect(bundle!.credits).toBe(10);
    expect(bundle!.priceZar).toBe(250);
  });

  it('returns the practice bundle', () => {
    const bundle = getBundle('practice');
    expect(bundle).toBeDefined();
    expect(bundle!.credits).toBe(50);
    expect(bundle!.priceZar).toBe(1125);
  });

  it('returns the clinic bundle', () => {
    const bundle = getBundle('clinic');
    expect(bundle).toBeDefined();
    expect(bundle!.credits).toBe(200);
    expect(bundle!.priceZar).toBe(4000);
  });

  it('returns undefined for an unknown key', () => {
    expect(getBundle('unknown')).toBeUndefined();
  });

  it('returns undefined for an empty key', () => {
    expect(getBundle('')).toBeUndefined();
  });
});

describe('formatAmountZar', () => {
  it('formats whole rand amounts with two decimal places', () => {
    expect(formatAmountZar(250)).toBe('250.00');
  });

  it('formats 1125 correctly', () => {
    expect(formatAmountZar(1125)).toBe('1125.00');
  });

  it('formats 4000 correctly', () => {
    expect(formatAmountZar(4000)).toBe('4000.00');
  });

  it('preserves two decimal places when amount has sub-rand cents', () => {
    expect(formatAmountZar(99.9)).toBe('99.90');
  });

  it('represents sub-cent amounts as two decimal places (JS float behaviour: 1.005 rounds down)', () => {
    // JavaScript floating-point: 1.005 is stored as ~1.00499999...,
    // so toFixed(2) produces '1.00'. This is expected JS behaviour;
    // PayFast amounts are always whole-rand (no sub-rand values in practice).
    expect(formatAmountZar(1.005)).toBe('1.00');
  });
});

describe('zar', () => {
  it('formats as ZAR currency with no decimal places', () => {
    const result = zar(250);
    expect(result).toContain('250');
    expect(result).toMatch(/R|ZAR/);
  });

  it('returns a string', () => {
    expect(typeof zar(1125)).toBe('string');
  });
});
