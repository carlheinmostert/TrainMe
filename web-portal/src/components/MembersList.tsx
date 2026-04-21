'use client';

import { useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalMembersApi,
  MembersError,
  type MemberProfile,
} from '@/lib/supabase/api';

type Props = {
  practiceId: string;
  initialMembers: MemberProfile[];
  isOwner: boolean;
};

type Toast =
  | { kind: 'ok'; text: string }
  | { kind: 'err'; text: string }
  | { kind: 'code'; code: string };

/**
 * Interactive members table — rewrites the prior "truncated UUID + disabled
 * invite form" scaffold.
 *
 * Design compliance (Wave 5 + project rules):
 *
 * - R-01 (no modal confirms): destructive actions fire immediately. Remove
 *   and leave both surface an auto-dismissing toast instead of "Are you
 *   sure?". Undo is deferred to a follow-up wave — Wave 5 ships hard
 *   remove with a success toast.
 * - R-06 (practitioner vocabulary): copy uses "practitioner" / "member" /
 *   "owner" throughout. No "trainer" / "coach" in user-visible strings.
 * - R-09 (obvious defaults): the Invite button is the primary CTA at the
 *   top of the section, not buried in a <details> disclosure.
 *
 * Interactions:
 *   - Invite (owner-only) → mint fresh code → copy to clipboard → surface
 *     a toast with the code + join URL for manual share.
 *   - Role change (owner-only, non-self) → instant RPC, toast on success.
 *     The DB rejects last-owner demote + self-change; we surface those as
 *     inline toast errors.
 *   - Remove (owner-only, non-self) → hard delete + toast. No undo yet.
 *   - Leave (own row) → RPC + redirect to `/` on success (the remaining
 *     practice context is re-derived by the home-page default flow).
 */
export function MembersList({ practiceId, initialMembers, isOwner }: Props) {
  const router = useRouter();
  const [members, setMembers] = useState<MemberProfile[]>(initialMembers);
  const [toast, setToast] = useState<Toast | null>(null);
  const [pending, startTransition] = useTransition();
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    setMembers(initialMembers);
  }, [initialMembers]);

  useEffect(() => {
    return () => {
      if (toastTimer.current) clearTimeout(toastTimer.current);
    };
  }, []);

  function fireToast(next: Toast, ttlMs = 5000) {
    setToast(next);
    if (toastTimer.current) clearTimeout(toastTimer.current);
    // The "code" toast stays a bit longer — the user needs time to copy
    // it again if the clipboard write failed silently.
    toastTimer.current = setTimeout(() => setToast(null), ttlMs);
  }

  async function handleInvite() {
    if (!isOwner) return;
    startTransition(async () => {
      try {
        const supabase = getBrowserClient();
        const api = createPortalMembersApi(supabase);
        const code = await api.mintInviteCode(practiceId);
        // Best-effort clipboard write. Safari requires the writeText call
        // to happen inside a user gesture — the click handler above
        // satisfies that, but the call can still fail silently on some
        // embedded browser contexts. Regardless, the toast surfaces the
        // code so it's never lost.
        try {
          await navigator.clipboard?.writeText(code);
        } catch {
          // ignore — toast still shows the code
        }
        fireToast({ kind: 'code', code }, 12000);
      } catch (e) {
        fireToast({ kind: 'err', text: mapError(e) });
      }
    });
  }

  async function handleRoleChange(
    member: MemberProfile,
    next: 'owner' | 'practitioner',
  ) {
    if (member.role === next) return;
    const previous = member.role;
    // Optimistic — flip locally, roll back on failure.
    setMembers((prev) =>
      prev.map((m) =>
        m.trainerId === member.trainerId ? { ...m, role: next } : m,
      ),
    );
    try {
      const supabase = getBrowserClient();
      const api = createPortalMembersApi(supabase);
      await api.setMemberRole(practiceId, member.trainerId, next);
      fireToast({
        kind: 'ok',
        text: `${displayName(member)} is now a${next === 'owner' ? 'n owner' : ' practitioner'}.`,
      });
      router.refresh();
    } catch (e) {
      // Roll back the optimistic flip.
      setMembers((prev) =>
        prev.map((m) =>
          m.trainerId === member.trainerId ? { ...m, role: previous } : m,
        ),
      );
      fireToast({ kind: 'err', text: mapError(e) });
    }
  }

  async function handleRemove(member: MemberProfile) {
    // Optimistic hide.
    const previous = members;
    setMembers((prev) => prev.filter((m) => m.trainerId !== member.trainerId));
    try {
      const supabase = getBrowserClient();
      const api = createPortalMembersApi(supabase);
      await api.removeMember(practiceId, member.trainerId);
      fireToast({ kind: 'ok', text: `${displayName(member)} removed.` });
      router.refresh();
    } catch (e) {
      setMembers(previous);
      fireToast({ kind: 'err', text: mapError(e) });
    }
  }

  async function handleLeave() {
    try {
      const supabase = getBrowserClient();
      const api = createPortalMembersApi(supabase);
      await api.leavePractice(practiceId);
      // After leaving, we have no business staying on this page. The
      // home path resolves to the user's remaining practices (or a
      // create-new-practice prompt if there are none).
      window.location.assign('/');
    } catch (e) {
      fireToast({ kind: 'err', text: mapError(e) });
    }
  }

  return (
    <>
      <div className="mt-6 flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-ink-muted">
          {members.length === 1
            ? '1 member'
            : `${members.length} members`}
        </p>
        {isOwner && (
          <button
            type="button"
            onClick={handleInvite}
            disabled={pending}
            className="inline-flex items-center gap-2 rounded-md bg-brand px-4 py-2 text-sm font-semibold text-surface-bg transition hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-60"
          >
            {pending ? 'Generating…' : 'Invite a practitioner'}
          </button>
        )}
      </div>

      <div className="mt-4 overflow-hidden rounded-lg border border-surface-border bg-surface-base">
        <table className="w-full text-left text-sm">
          <thead className="bg-surface-raised text-xs uppercase tracking-wider text-ink-dim">
            <tr>
              <th className="px-5 py-3 font-medium">Email</th>
              <th className="px-5 py-3 font-medium">Name</th>
              <th className="px-5 py-3 font-medium">Role</th>
              <th className="px-5 py-3 font-medium">Joined</th>
              <th className="px-5 py-3 font-medium text-right">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-surface-border">
            {members.map((m) => (
              <tr key={m.trainerId} className="align-middle">
                <td className="px-5 py-3 text-ink">
                  <span className="break-all">{m.email || '—'}</span>
                  {m.isCurrentUser && (
                    <span className="ml-2 rounded-full bg-surface-raised px-2 py-0.5 text-xs text-ink-muted">
                      you
                    </span>
                  )}
                </td>
                <td className="px-5 py-3 text-ink-muted">
                  {m.fullName || <span className="text-ink-dim">—</span>}
                </td>
                <td className="px-5 py-3">
                  {isOwner && !m.isCurrentUser ? (
                    <select
                      value={m.role}
                      onChange={(e) =>
                        handleRoleChange(
                          m,
                          e.target.value as 'owner' | 'practitioner',
                        )
                      }
                      className="rounded-md border border-surface-border bg-surface-raised px-2 py-1 text-xs font-semibold uppercase text-ink"
                      aria-label={`Set role for ${displayName(m)}`}
                    >
                      <option value="owner">OWNER</option>
                      <option value="practitioner">PRACTITIONER</option>
                    </select>
                  ) : (
                    <span
                      className={
                        m.role === 'owner'
                          ? 'rounded-full bg-brand/15 px-3 py-1 text-xs font-semibold uppercase text-brand'
                          : 'rounded-full bg-surface-raised px-3 py-1 text-xs font-semibold uppercase text-ink-muted'
                      }
                    >
                      {m.role}
                    </span>
                  )}
                </td>
                <td className="px-5 py-3 text-ink-dim">
                  {m.joinedAt
                    ? new Date(m.joinedAt).toLocaleDateString('en-ZA', {
                        dateStyle: 'medium',
                      })
                    : '—'}
                </td>
                <td className="px-5 py-3 text-right">
                  {m.isCurrentUser ? (
                    <button
                      type="button"
                      onClick={handleLeave}
                      className="text-xs font-semibold uppercase tracking-wider text-error transition hover:text-error/80"
                    >
                      Leave practice
                    </button>
                  ) : isOwner ? (
                    <button
                      type="button"
                      onClick={() => handleRemove(m)}
                      className="text-xs font-semibold uppercase tracking-wider text-error transition hover:text-error/80"
                    >
                      Remove
                    </button>
                  ) : (
                    <span className="text-xs text-ink-dim">—</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {toast && (
        <ToastBanner toast={toast} onDismiss={() => setToast(null)} />
      )}
    </>
  );
}

function ToastBanner({
  toast,
  onDismiss,
}: {
  toast: Toast;
  onDismiss: () => void;
}) {
  if (toast.kind === 'code') {
    const href =
      typeof window !== 'undefined'
        ? `${window.location.origin}/join/${toast.code}`
        : `/join/${toast.code}`;
    return (
      <div
        role="status"
        className="mt-6 flex flex-wrap items-start justify-between gap-3 rounded-md border border-brand/40 bg-brand/10 px-4 py-3 text-sm text-ink"
      >
        <div>
          <p className="font-semibold text-brand">Invite code copied</p>
          <p className="mt-1 text-xs text-ink-muted">
            Share this link via WhatsApp or email:
          </p>
          <p className="mt-1 break-all font-mono text-sm text-ink">{href}</p>
        </div>
        <button
          type="button"
          onClick={onDismiss}
          className="text-xs font-semibold uppercase text-ink-muted transition hover:text-ink"
        >
          Dismiss
        </button>
      </div>
    );
  }
  return (
    <div
      role="status"
      aria-live={toast.kind === 'err' ? 'assertive' : 'polite'}
      className={
        toast.kind === 'ok'
          ? 'mt-6 rounded-md border border-success/40 bg-success/10 px-4 py-3 text-sm text-success'
          : 'mt-6 rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error'
      }
    >
      {toast.text}
    </div>
  );
}

function displayName(m: MemberProfile): string {
  if (m.fullName) return m.fullName;
  if (m.email) return m.email;
  return 'This member';
}

function mapError(e: unknown): string {
  if (e instanceof MembersError) {
    switch (e.kind) {
      case 'not-owner':
        return 'Only practice owners can do that.';
      case 'not-member':
        return "You're not a member of this practice.";
      case 'not-found':
        return 'Not found — maybe already removed.';
      case 'invalid':
        // The DB returns specific messages like "cannot demote the last
        // owner" — surface them directly so the owner knows exactly
        // what rule kicked in.
        return e.message;
      case 'auth':
        return 'Your session expired. Sign in again.';
    }
  }
  const msg = e instanceof Error ? e.message : 'Something went wrong.';
  return msg;
}
