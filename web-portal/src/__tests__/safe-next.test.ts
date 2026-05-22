import { describe, it, expect } from 'vitest';
import { safeNext } from '@/lib/safe-next';

describe('safeNext', () => {
  it('returns fallback for null', () => {
    expect(safeNext(null)).toBe('/dashboard');
  });

  it('returns fallback for undefined', () => {
    expect(safeNext(undefined)).toBe('/dashboard');
  });

  it('returns fallback for empty string', () => {
    expect(safeNext('')).toBe('/dashboard');
  });

  it('returns the path for a valid same-origin path', () => {
    expect(safeNext('/clients')).toBe('/clients');
  });

  it('returns the path for a deep same-origin path', () => {
    expect(safeNext('/clients/abc-123')).toBe('/clients/abc-123');
  });

  it('returns fallback for a protocol-relative URL', () => {
    expect(safeNext('//evil.example.com')).toBe('/dashboard');
  });

  it('returns fallback for an absolute https URL', () => {
    expect(safeNext('https://evil.example.com')).toBe('/dashboard');
  });

  it('returns fallback for an absolute http URL', () => {
    expect(safeNext('http://evil.example.com')).toBe('/dashboard');
  });

  it('honours a custom fallback argument', () => {
    expect(safeNext(null, '/sign-in')).toBe('/sign-in');
  });

  it('does not apply the custom fallback when the path is valid', () => {
    expect(safeNext('/credits', '/sign-in')).toBe('/credits');
  });

  it('returns fallback for a path with newline (header-injection guard)', () => {
    // Doesn't start with '/', so collapses to fallback.
    expect(safeNext('\n/dashboard')).toBe('/dashboard');
  });
});
