import { describe, it, expect } from 'vitest';
import {
  auditChipTone,
  coerceNumberOrNull,
  normaliseConsent,
  mapMemberProfileRow,
  mapPracticeSessionRow,
} from '../api';

// ---------------------------------------------------------------------------
// auditChipTone
// ---------------------------------------------------------------------------

describe('auditChipTone', () => {
  it('returns coral for plan.publish', () => {
    expect(auditChipTone('plan.publish')).toBe('coral');
  });

  it('returns coral for credit.consumption', () => {
    expect(auditChipTone('credit.consumption')).toBe('coral');
  });

  it('returns sage for plan.opened', () => {
    expect(auditChipTone('plan.opened')).toBe('sage');
  });

  it('returns sage for credit.purchase', () => {
    expect(auditChipTone('credit.purchase')).toBe('sage');
  });

  it('returns sage for credit.signup_bonus', () => {
    expect(auditChipTone('credit.signup_bonus')).toBe('sage');
  });

  it('returns sage for credit.referral_signup_bonus', () => {
    expect(auditChipTone('credit.referral_signup_bonus')).toBe('sage');
  });

  it('returns sage for referral.rebate', () => {
    expect(auditChipTone('referral.rebate')).toBe('sage');
  });

  it('returns sage for client.consent.update', () => {
    expect(auditChipTone('client.consent.update')).toBe('sage');
  });

  it('returns red for credit.refund', () => {
    expect(auditChipTone('credit.refund')).toBe('red');
  });

  it('returns red for client.delete', () => {
    expect(auditChipTone('client.delete')).toBe('red');
  });

  it('returns red for member.remove', () => {
    expect(auditChipTone('member.remove')).toBe('red');
  });

  it('returns red for invite.revoke', () => {
    expect(auditChipTone('invite.revoke')).toBe('red');
  });

  it('returns grey for unknown kinds', () => {
    expect(auditChipTone('unknown.event')).toBe('grey');
    expect(auditChipTone('')).toBe('grey');
    expect(auditChipTone('PLAN.PUBLISH')).toBe('grey'); // case-sensitive
  });
});

// ---------------------------------------------------------------------------
// coerceNumberOrNull
// ---------------------------------------------------------------------------

describe('coerceNumberOrNull', () => {
  it('returns null for null', () => {
    expect(coerceNumberOrNull(null)).toBeNull();
  });

  it('returns null for undefined', () => {
    expect(coerceNumberOrNull(undefined)).toBeNull();
  });

  it('returns the number for a finite number', () => {
    expect(coerceNumberOrNull(42)).toBe(42);
    expect(coerceNumberOrNull(0)).toBe(0);
    expect(coerceNumberOrNull(-3.14)).toBe(-3.14);
  });

  it('returns null for non-finite numbers', () => {
    expect(coerceNumberOrNull(NaN)).toBeNull();
    expect(coerceNumberOrNull(Infinity)).toBeNull();
    expect(coerceNumberOrNull(-Infinity)).toBeNull();
  });

  it('coerces numeric strings', () => {
    expect(coerceNumberOrNull('5')).toBe(5);
    expect(coerceNumberOrNull('3.14')).toBe(3.14);
    expect(coerceNumberOrNull('-10')).toBe(-10);
    expect(coerceNumberOrNull('0')).toBe(0);
  });

  it('returns null for non-numeric strings', () => {
    expect(coerceNumberOrNull('hello')).toBeNull();
    expect(coerceNumberOrNull('1e999')).toBeNull(); // Infinity string
  });

  it('returns 0 for empty string (Number("") === 0 in JS)', () => {
    // This is the expected JavaScript coercion behaviour — an empty Postgres
    // numeric column would arrive as null, not "", so this edge case is benign.
    expect(coerceNumberOrNull('')).toBe(0);
  });

  it('returns null for non-number, non-string types', () => {
    expect(coerceNumberOrNull(true)).toBeNull();
    expect(coerceNumberOrNull({})).toBeNull();
    expect(coerceNumberOrNull([])).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// normaliseConsent
// ---------------------------------------------------------------------------

describe('normaliseConsent', () => {
  it('returns the conservative default for null input', () => {
    expect(normaliseConsent(null)).toEqual({
      line_drawing: true,
      grayscale: false,
      original: false,
      avatar: false,
    });
  });

  it('returns the conservative default for undefined input', () => {
    expect(normaliseConsent(undefined)).toEqual({
      line_drawing: true,
      grayscale: false,
      original: false,
      avatar: false,
    });
  });

  it('always sets line_drawing to true even if input says false', () => {
    const result = normaliseConsent({ line_drawing: false, grayscale: true, original: true, avatar: true });
    expect(result.line_drawing).toBe(true);
  });

  it('maps truthy fields correctly', () => {
    const result = normaliseConsent({ grayscale: true, original: true, avatar: true });
    expect(result.grayscale).toBe(true);
    expect(result.original).toBe(true);
    expect(result.avatar).toBe(true);
  });

  it('maps falsy fields to false', () => {
    const result = normaliseConsent({ grayscale: false, original: 0, avatar: null });
    expect(result.grayscale).toBe(false);
    expect(result.original).toBe(false);
    expect(result.avatar).toBe(false);
  });

  it('handles missing keys with false defaults', () => {
    const result = normaliseConsent({});
    expect(result).toEqual({
      line_drawing: true,
      grayscale: false,
      original: false,
      avatar: false,
    });
  });

  it('returns conservative default for a non-object primitive', () => {
    expect(normaliseConsent('invalid')).toEqual({
      line_drawing: true,
      grayscale: false,
      original: false,
      avatar: false,
    });
    expect(normaliseConsent(42)).toEqual({
      line_drawing: true,
      grayscale: false,
      original: false,
      avatar: false,
    });
  });
});

// ---------------------------------------------------------------------------
// mapMemberProfileRow
// ---------------------------------------------------------------------------

describe('mapMemberProfileRow', () => {
  const validRow = {
    trainer_id: 'user-123',
    email: 'coach@example.com',
    full_name: 'Jane Coach',
    role: 'owner',
    joined_at: '2026-01-15T09:00:00Z',
    is_current_user: true,
  };

  it('maps a valid row correctly', () => {
    expect(mapMemberProfileRow(validRow)).toEqual({
      trainerId: 'user-123',
      email: 'coach@example.com',
      fullName: 'Jane Coach',
      role: 'owner',
      joinedAt: '2026-01-15T09:00:00Z',
      isCurrentUser: true,
    });
  });

  it('defaults role to practitioner for any non-owner value', () => {
    expect(mapMemberProfileRow({ ...validRow, role: 'admin' }).role).toBe('practitioner');
    expect(mapMemberProfileRow({ ...validRow, role: null }).role).toBe('practitioner');
    expect(mapMemberProfileRow({ ...validRow, role: 'practitioner' }).role).toBe('practitioner');
  });

  it('falls back to empty strings for missing string fields', () => {
    const row = { is_current_user: false };
    const result = mapMemberProfileRow(row);
    expect(result.trainerId).toBe('');
    expect(result.email).toBe('');
    expect(result.fullName).toBe('');
    expect(result.joinedAt).toBe('');
  });

  it('coerces is_current_user to boolean', () => {
    expect(mapMemberProfileRow({ ...validRow, is_current_user: 0 }).isCurrentUser).toBe(false);
    expect(mapMemberProfileRow({ ...validRow, is_current_user: 1 }).isCurrentUser).toBe(true);
    expect(mapMemberProfileRow({ ...validRow, is_current_user: null }).isCurrentUser).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// mapPracticeSessionRow
// ---------------------------------------------------------------------------

describe('mapPracticeSessionRow', () => {
  const validRow = {
    id: 'plan-abc',
    title: 'Morning Routine',
    client_name: 'Alice',
    trainer_id: 'trainer-xyz',
    trainer_email: 'pt@example.com',
    version: 3,
    last_published_at: '2026-05-01T12:00:00Z',
    first_opened_at: '2026-05-02T08:00:00Z',
    issuance_count: 2,
    exercise_count: 8,
    is_own_session: true,
  };

  it('maps a complete row correctly', () => {
    expect(mapPracticeSessionRow(validRow)).toEqual({
      id: 'plan-abc',
      title: 'Morning Routine',
      clientName: 'Alice',
      trainerId: 'trainer-xyz',
      trainerEmail: 'pt@example.com',
      version: 3,
      lastPublishedAt: '2026-05-01T12:00:00Z',
      firstOpenedAt: '2026-05-02T08:00:00Z',
      issuanceCount: 2,
      exerciseCount: 8,
      isOwnSession: true,
    });
  });

  it('maps null nullable fields to null', () => {
    const row = { ...validRow, client_name: null, trainer_email: null, last_published_at: null, first_opened_at: null };
    const result = mapPracticeSessionRow(row);
    expect(result.clientName).toBeNull();
    expect(result.trainerEmail).toBeNull();
    expect(result.lastPublishedAt).toBeNull();
    expect(result.firstOpenedAt).toBeNull();
  });

  it('defaults numeric fields to 0 when missing', () => {
    const row = {};
    const result = mapPracticeSessionRow(row);
    expect(result.version).toBe(0);
    expect(result.issuanceCount).toBe(0);
    expect(result.exerciseCount).toBe(0);
  });

  it('coerces is_own_session to boolean', () => {
    expect(mapPracticeSessionRow({ ...validRow, is_own_session: 0 }).isOwnSession).toBe(false);
    expect(mapPracticeSessionRow({ ...validRow, is_own_session: 1 }).isOwnSession).toBe(true);
  });

  it('falls back to empty string for missing id/title', () => {
    const result = mapPracticeSessionRow({});
    expect(result.id).toBe('');
    expect(result.title).toBe('');
    expect(result.trainerId).toBe('');
  });
});
