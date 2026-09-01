import { describe, it, expect } from 'vitest';
import {
  BUNDLES,
  getBundle,
  zar,
  formatAmountZar,
  type BundleKey,
} from '../bundles';

describe('BUNDLES catalog', () => {
  it('contains exactly three bundles', () => {
    expect(BUNDLES).toHaveLength(3);
  });

  it('has unique keys', () => {
    const keys = BUNDLES.map((b) => b.key);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it('all bundles have positive credits and price', () => {
    for (const b of BUNDLES) {
      expect(b.credits).toBeGreaterThan(0);
      expect(b.priceZar).toBeGreaterThan(0);
    }
  });

  it('credits scale with price (no bundle is worse value per credit)', () => {
    const sorted = [...BUNDLES].sort((a, b) => a.credits - b.credits);
    for (let i = 1; i < sorted.length; i++) {
      const prev = sorted[i - 1];
      const curr = sorted[i];
      const prevRate = prev.priceZar / prev.credits;
      const currRate = curr.priceZar / curr.credits;
      expect(currRate).toBeLessThanOrEqual(prevRate);
    }
  });

  it('known bundle values match spec (10/250, 50/1125, 200/4000)', () => {
    const starter = BUNDLES.find((b) => b.key === 'starter');
    const practice = BUNDLES.find((b) => b.key === 'practice');
    const clinic = BUNDLES.find((b) => b.key === 'clinic');

    expect(starter?.credits).toBe(10);
    expect(starter?.priceZar).toBe(250);
    expect(practice?.credits).toBe(50);
    expect(practice?.priceZar).toBe(1125);
    expect(clinic?.credits).toBe(200);
    expect(clinic?.priceZar).toBe(4000);
  });
});

describe('getBundle', () => {
  it('returns the matching bundle for a valid key', () => {
    const b = getBundle('starter');
    expect(b).toBeDefined();
    expect(b?.key).toBe('starter');
  });

  it('returns undefined for an unknown key', () => {
    expect(getBundle('unknown')).toBeUndefined();
  });

  it('returns undefined for an empty string', () => {
    expect(getBundle('')).toBeUndefined();
  });

  it.each([
    ['starter', 'starter'],
    ['practice', 'practice'],
    ['clinic', 'clinic'],
  ] as [string, BundleKey][])('getBundle("%s") returns key "%s"', (input, expected) => {
    expect(getBundle(input)?.key).toBe(expected);
  });
});

describe('zar', () => {
  it('formats whole-rand amounts as ZAR currency', () => {
    // en-ZA locale: R symbol + space + number, maximumFractionDigits=0
    const result = zar(250);
    expect(result).toContain('250');
    expect(result).toMatch(/R/i);
  });

  it('rounds fractions when formatting', () => {
    const result = zar(250.7);
    expect(result).not.toContain('.7');
  });

  it('formats zero', () => {
    const result = zar(0);
    expect(result).toContain('0');
  });
});

describe('formatAmountZar', () => {
  it('formats with exactly two decimal places', () => {
    expect(formatAmountZar(250)).toBe('250.00');
    expect(formatAmountZar(1125)).toBe('1125.00');
    expect(formatAmountZar(4000)).toBe('4000.00');
  });

  it('formats zero as "0.00"', () => {
    expect(formatAmountZar(0)).toBe('0.00');
  });

  it('preserves two decimals for fractional inputs', () => {
    expect(formatAmountZar(99.5)).toBe('99.50');
    expect(formatAmountZar(99.99)).toBe('99.99');
  });

  it('does not include thousands separators', () => {
    expect(formatAmountZar(4000)).not.toContain(',');
  });
});
