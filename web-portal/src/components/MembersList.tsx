'use client';

import { useEffect, useRef, useState, useTransition, type FormEvent } from 'react';
import { useRouter } from 'next/navigation';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalMembersApi,
  MembersError,
  type AddMemberResult,
  type MemberProfile,
  type PendingMember,
} from '@/lib/supabase/api';

type Props = {
  practiceId: string;
  initialMembers: MemberProfile[];
  initialPending: PendingMember[];
  isOwner: boolean;
};

type Toast =
  | { kind: 'ok'; text: string }
  | { kind: 'err'; text: string }
  | { kind: 'pending-note'; text: string };

/**
 * Interactive members + pending table — Wave 14 rewrite of the Wave 5
 * MembersList (which shipped an invite-code mint button + clipboard
 * toast). The new flow is owner-driven and invitee-passive: owner
 * types an email, clicks Add, and the RPC dispatches on whether an
 * auth.users row already exists for that email.
 *
 * Design compliance (Wave 14 + project rules):
 *
 * - R-01 (no modal confirms): Add + Remove-pending fire immediately.
 *   Members-remove + Leave stay on the Wave-5 pattern (hard action
 *   with an inline toast, no "Are you sure?").
 * - R-06 (practitioner vocabulary): copy uses "practitioner" / "member" /
 *   "owner" throughout. No "trainer" / "coach" in user-visible strings.
 * - R-09 (obvious defaults): the Add form is the primary CTA at the
 *   top of the section, not buried in a <details> disclosure.
 *
 * Interactions:
 *   - Add by email (owner-only) → RPC dispatches; success toast varies
 *     by `kind`:
 *       - added          → "Added {email} to this practice."
 *       - already_member → "{email} is already in this practice."
 *       - pending        → "Saved — {email} will join automatically
 *                          when they sign up."
 *   - Remove pending (owner-only) → hard delete the pending row.
 *   - Role change (owner-only, non-self) → instant RPC, toast on success.
 *     The DB rejects last-owner demote + self-change; we surface those
 *     as inline toast errors.
 *   - Remove (owner-only, non-self) → hard delete + toast. No undo yet.
 *   - Leave (own row) → RPC + redirect to `/` on success.
 */
export function MembersList({
  practiceId,
  initialMembers,
  initialPending,
  isOwner,
}: Props) {
  const router = useRouter();
  const [members, setMembers] = useState<MemberProfile[]>(initialMembers);
  const [pending, setPending] = useState<PendingMember[]>(initialPending);
  const [email, setEmail] = useState('');
  const [toast, setToast] = useState<Toast | null>(null);
  const [addPending, startAddTransition] = useTransition();
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    setMembers(initialMembers);
  }, [initialMembers]);
  useEffect(() => {
    setPending(initialPending);
  }, [initialPending]);

  useEffect(() => {
    return () => {
      if (toastTimer.current) clearTimeout(toastTimer.current);
    };
  }, []);

  function fireToast(next: Toast, ttlMs = 5000) {
    setToast(next);
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(null), ttlMs);
  }

  async function handleAdd(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (!isOwner) return;
    const trimmed = email.trim();
    if (trimmed.length === 0) {
      fireToast({ kind: 'err', text: 'Enter an email.' });
      return;
    }
    startAddTransition(async () => {
      try {
        const supabase = getBrowserClient();
        const api = createPortalMembersApi(supabase);
        const result = await api.addMemberByEmail(practiceId, trimmed);
        handleAddSuccess(result);
        setEmail('');
        router.refresh();
      } catch (err) {
        fireToast({ kind: 'err', text: mapError(err) });
      }
    });
  }

  function handleAddSuccess(result: AddMemberResult) {
    if (result.kind === 'added') {
      // Optimistically insert so the new row is visible before
      // router.refresh() finishes its round-trip.
      setMembers((prev) => {
        if (prev.some((m) => m.trainerId === result.trainerId)) return prev;
        return [
          ...prev,
          {
            trainerId: result.trainerId,
            email: result.email,
            fullName: result.fullName,
            role: result.role,
            joinedAt: new Date().toISOString(),
            isCurrentUser: false,
          },
        ];
      });
      fireToast({
        kind: 'ok',
        text: `Added ${result.email} to this practice.`,
      });
      return;
    }
    if (result.kind === 'already_member') {
      fireToast({
        kind: 'ok',
        text: `${result.email} is already in this practice.`,
      });
      return;
    }
    // pending
    setPending((prev) => {
      const filtered = prev.filter(
        (p) => p.email.toLowerCase() !== result.email.toLowerCase(),
      );
      return [
        ...filtered,
        {
          email: result.email,
          addedBy: null, // the RPC doesn't echo added_by; refresh() fills it in.
          addedAt: new Date().toISOString(),
        },
      ];
    });
    fireToast(
      {
        kind: 'pending-note',
        text: `Saved — ${result.email} will join automatically when they sign up.`,
      },
      8000,
    );
  }

  async function handleRemovePending(row: PendingMember) {
    // Optimistic hide so the row disappears immediately.
    const previous = pending;
    setPending((prev) =>
      prev.filter((p) => p.email.toLowerCase() !== row.email.toLowerCase()),
    );
    try {
      const supabase = getBrowserClient();
      const api = createPortalMembersApi(supabase);
      await api.removePendingMember(practiceId, row.email);
      fireToast({ kind: 'ok', text: `Removed ${row.email} from pending.` });
      router.refresh();
    } catch (err) {
      setPending(previous);
      fireToast({ kind: 'err', text: mapError(err) });
    }
  }

  async function handleRoleChange(
    member: MemberProfile,
    next: 'owner' | 'practitioner',
  ) {
    if (member.role === next) return;
    const previous = member.role;
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
    } catch (err) {
      setMembers((prev) =>
        prev.map((m) =>
          m.trainerId === member.trainerId ? { ...m, role: previous } : m,
        ),
      );
      fireToast({ kind: 'err', text: mapError(err) });
    }
  }

  async function handleRemove(member: MemberProfile) {
    const previous = members;
    setMembers((prev) => prev.filter((m) => m.trainerId !== member.trainerId));
    try {
      const supabase = getBrowserClient();
      const api = createPortalMembersApi(supabase);
      await api.removeMember(practiceId, member.trainerId);
      fireToast({ kind: 'ok', text: `${displayName(member)} removed.` });
      router.refresh();
    } catch (err) {
      setMembers(previous);
      fireToast({ kind: 'err', text: mapError(err) });
    }
  }

  async function handleLeave() {
    try {
      const supabase = getBrowserClient();
      const api = createPortalMembersApi(supabase);
      await api.leavePractice(practiceId);
      window.location.assign('/');
    } catch (err) {
      fireToast({ kind: 'err', text: mapError(err) });
    }
  }

  return (
    <>
      {isOwner && (
        <form
          onSubmit={handleAdd}
          className="mt-6 flex flex-wrap items-end gap-3 rounded-lg border border-surface-border bg-surface-base p-5"
        >
          <div className="flex-1 min-w-[220px]">
            <label
              htmlFor="add-member-email"
              className="mb-1 block text-xs font-medium text-ink-muted"
            >
              Add a practitioner by email
            </label>
            <input
              id="add-member-email"
              type="email"
              autoComplete="off"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              disabled={addPending}
              placeholder="colleague@practice.co.za"
              className="w-full rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-dim focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand disabled:cursor-not-allowed disabled:opacity-60"
            />
          </div>
          <button
            type="submit"
            disabled={addPending}
            className="inline-flex items-center gap-2 rounded-md bg-brand px-4 py-2 text-sm font-semibold text-surface-bg transition hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-60"
          >
            {addPending ? 'Adding…' : 'Add'}
          </button>
          <p className="w-full text-xs text-ink-dim">
            If they already have an account, they&rsquo;ll appear under
            Members immediately. Otherwise they&rsquo;ll be saved under
            Pending and join automatically when they sign up.
          </p>
        </form>
      )}

      <section className="mt-6">
        <header className="flex flex-wrap items-center justify-between gap-3">
          <h2 className="font-heading text-sm font-semibold uppercase tracking-wider text-ink-muted">
            Members
          </h2>
          <p className="text-xs text-ink-dim">
            {members.length === 1 ? '1 member' : `${members.length} members`}
          </p>
        </header>

        {members.length === 0 ? (
          <p className="mt-3 rounded-lg border border-surface-border bg-surface-base p-8 text-center text-ink-muted">
            No members found for this practice.
          </p>
        ) : (
          <div className="mt-3 overflow-hidden rounded-lg border border-surface-border bg-surface-base">
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
        )}
      </section>

      {isOwner && (
        <section className="mt-8">
          <header className="flex flex-wrap items-center justify-between gap-3">
            <h2 className="font-heading text-sm font-semibold uppercase tracking-wider text-ink-muted">
              Pending
            </h2>
            <p className="text-xs text-ink-dim">
              {pending.length === 1
                ? '1 pending invite'
                : `${pending.length} pending invites`}
            </p>
          </header>

          {pending.length === 0 ? (
            <p className="mt-3 rounded-lg border border-surface-border bg-surface-base p-6 text-center text-sm text-ink-muted">
              Nobody&rsquo;s waiting for a homefit.studio account yet. Add
              an email above to queue a colleague.
            </p>
          ) : (
            <div className="mt-3 overflow-hidden rounded-lg border border-surface-border bg-surface-base">
              <table className="w-full text-left text-sm">
                <thead className="bg-surface-raised text-xs uppercase tracking-wider text-ink-dim">
                  <tr>
                    <th className="px-5 py-3 font-medium">Email</th>
                    <th className="px-5 py-3 font-medium">Queued</th>
                    <th className="px-5 py-3 font-medium text-right">
                      Actions
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-surface-border">
                  {pending.map((p) => (
                    <tr key={p.email} className="align-middle">
                      <td className="px-5 py-3 text-ink">
                        <span className="break-all">{p.email}</span>
                        <span className="ml-2 rounded-full bg-surface-raised px-2 py-0.5 text-xs text-ink-muted">
                          pending signup
                        </span>
                      </td>
                      <td className="px-5 py-3 text-ink-dim">
                        {p.addedAt
                          ? new Date(p.addedAt).toLocaleDateString('en-ZA', {
                              dateStyle: 'medium',
                            })
                          : '—'}
                      </td>
                      <td className="px-5 py-3 text-right">
                        <button
                          type="button"
                          onClick={() => handleRemovePending(p)}
                          className="text-xs font-semibold uppercase tracking-wider text-error transition hover:text-error/80"
                        >
                          Remove
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      )}

      {toast && <ToastBanner toast={toast} onDismiss={() => setToast(null)} />}
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
  if (toast.kind === 'pending-note') {
    return (
      <div
        role="status"
        className="mt-6 flex flex-wrap items-start justify-between gap-3 rounded-md border border-brand/40 bg-brand/10 px-4 py-3 text-sm text-ink"
      >
        <div>
          <p className="font-semibold text-brand">Queued for signup</p>
          <p className="mt-1 text-xs text-ink-muted">{toast.text}</p>
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
        // owner" or "invalid email" — surface them directly so the owner
        // knows exactly what rule kicked in.
        return e.message;
      case 'auth':
        return 'Your session expired. Sign in again.';
    }
  }
  const msg = e instanceof Error ? e.message : 'Something went wrong.';
  return msg;
}
