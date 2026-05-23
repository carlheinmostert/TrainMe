import { describe, it, expect } from 'vitest';
import { ACTIVE_PRACTICE_COOKIE, UUID_RE } from '../active-practice';

describe('ACTIVE_PRACTICE_COOKIE', () => {
  it('is the expected constant string', () => {
    expect(ACTIVE_PRACTICE_COOKIE).toBe('hf_active_practice');
  });
});

describe('UUID_RE', () => {
  it('matches a valid lowercase UUID v4', () => {
    expect(UUID_RE.test('550e8400-e29b-41d4-a716-446655440000')).toBe(true);
  });

  it('matches a valid uppercase UUID', () => {
    expect(UUID_RE.test('550E8400-E29B-41D4-A716-446655440000')).toBe(true);
  });

  it('matches a mixed-case UUID', () => {
    expect(UUID_RE.test('550e8400-E29B-41d4-A716-446655440000')).toBe(true);
  });

  it('rejects a UUID missing a segment', () => {
    expect(UUID_RE.test('550e8400-e29b-41d4-a716')).toBe(false);
  });

  it('rejects an empty string', () => {
    expect(UUID_RE.test('')).toBe(false);
  });

  it('rejects a UUID with extra characters', () => {
    expect(UUID_RE.test('550e8400-e29b-41d4-a716-446655440000-extra')).toBe(false);
  });

  it('rejects a non-hex segment', () => {
    expect(UUID_RE.test('550e8400-e29b-41d4-a716-ZZZZZZZZZZZZ')).toBe(false);
  });

  it('rejects a string with wrong segment lengths', () => {
    expect(UUID_RE.test('550e840-e29b-41d4-a716-446655440000')).toBe(false);
  });
});
