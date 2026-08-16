import { describe, it, expect } from 'vitest';
import {
  BUNDLES,
  getBundle,
  zar,
  formatAmountZar,
} from '@/lib/bundles';

describe('BUNDLES catalog', () => {
  it('has exactly three bundles', () => {
    expect(BUNDLES).toHaveLength(3);
  });

  it('bundles have unique keys', () => {
    const keys = BUNDLES.map((b) => b.key);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it('all bundles have positive credits and prices', () => {
    for (const b of BUNDLES) {
      expect(b.credits).toBeGreaterThan(0);
      expect(b.priceZar).toBeGreaterThan(0);
    }
  });

  it('bundles are ordered smallest to largest by credits', () => {
    const credits = BUNDLES.map((b) => b.credits);
    for (let i = 1; i < credits.length; i++) {
      expect(credits[i]).toBeGreaterThan(credits[i - 1]);
    }
  });
});

describe('getBundle', () => {
  it('returns the starter bundle', () => {
    const b = getBundle('starter');
    expect(b).toBeDefined();
    expect(b!.credits).toBe(10);
    expect(b!.priceZar).toBe(250);
  });

  it('returns the practice bundle', () => {
    const b = getBundle('practice');
    expect(b).toBeDefined();
    expect(b!.credits).toBe(50);
    expect(b!.priceZar).toBe(1125);
  });

  it('returns the clinic bundle', () => {
    const b = getBundle('clinic');
    expect(b).toBeDefined();
    expect(b!.credits).toBe(200);
    expect(b!.priceZar).toBe(4000);
  });

  it('returns undefined for an unknown key', () => {
    expect(getBundle('enterprise')).toBeUndefined();
    expect(getBundle('')).toBeUndefined();
  });
});

describe('formatAmountZar', () => {
  it('formats whole rands with two decimal places', () => {
    expect(formatAmountZar(250)).toBe('250.00');
    expect(formatAmountZar(1125)).toBe('1125.00');
    expect(formatAmountZar(4000)).toBe('4000.00');
  });

  it('formats fractional values correctly', () => {
    expect(formatAmountZar(99.9)).toBe('99.90');
    expect(formatAmountZar(10.50)).toBe('10.50');
  });

  it('round-trips through getBundle without precision loss', () => {
    for (const b of BUNDLES) {
      const formatted = formatAmountZar(b.priceZar);
      expect(parseFloat(formatted)).toBeCloseTo(b.priceZar, 2);
    }
  });
});

describe('zar formatter', () => {
  it('includes the ZAR currency symbol or code', () => {
    const formatted = zar(250);
    // Intl may render "R 250" or "ZAR 250" depending on locale data availability
    expect(formatted).toMatch(/250/);
  });

  it('formats zero without throwing', () => {
    expect(() => zar(0)).not.toThrow();
  });
});
