'use client';

import {
  forwardRef,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useTransition,
} from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import { getBrowserClient } from '@/lib/supabase-browser';
import {
  createPortalApi,
  RenamePracticeError,
  type PracticeWithRole,
} from '@/lib/supabase/api';

/**
 * Practice-context line on the dashboard.
 *
 * Layout (all on one line, wrap on narrow screens):
 *
 *     In practice: {EditableName}   ⇄ Switch
 *
 * Replaces the pre-R-12 native <select>. Reasoning:
 *   - The practice name is the tenant boundary — R-06 voice wants a
 *     prose sentence, not a form widget.
 *   - Inline rename mirrors [ClientDetailPanel]'s EditableClientName
 *     pattern so practitioners learn one editing idiom.
 *   - The Switch affordance is a custom dark popover (no native select)
 *     to match the dark-mode visual language and to fit the credit-
 *     balance chip alongside each row.
 *
 * Props:
 *   - `practices` — every practice the caller belongs to (with role).
 *   - `selectedId` — the currently-active practice (drives the name).
 *   - `isOwner` — whether the caller is the OWNER of the active practice.
 *     Gates the rename affordance only; the switch popover is always
 *     available regardless of role.
 *   - `balancesById` — optional map of practice id → current credit
 *     balance, rendered under each row in the popover to disambiguate
 *     practices with similar names. Omit to show only names.
 */
export type PracticeContextLineProps = {
  practices: PracticeWithRole[];
  selectedId: string;
  isOwner: boolean;
  balancesById?: Record<string, number>;
};

export function PracticeContextLine({
  practices,
  selectedId,
  isOwner,
  balancesById,
}: PracticeContextLineProps) {
  const [displayName, setDisplayName] = useState<string>(
    () =>
      practices.find((p) => p.id === selectedId)?.name ??
      practices[0]?.name ??
      '',
  );

  // Keep displayName in sync when the server re-renders with a fresh
  // list (e.g. after a switch). Without this, renaming practice A then
  // switching to practice B would leave the old A name stuck.
  useEffect(() => {
    const next = practices.find((p) => p.id === selectedId)?.name;
    if (next !== undefined) setDisplayName(next);
  }, [selectedId, practices]);

  const hasMany = practices.length > 1;

  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-ink-muted">
      <span>In practice:</span>
      <EditablePracticeName
        practiceId={selectedId}
        name={displayName}
        canEdit={isOwner}
        onRenamed={setDisplayName}
      />
      {hasMany && (
        <SwitchPopover
          practices={practices}
          selectedId={selectedId}
          balancesById={balancesById}
        />
      )}
    </div>
  );
}

/* ---------------------------------------------------------------------- */
/*  EditablePracticeName — dashed-underline inline edit (R-01 compliant)  */
/* ---------------------------------------------------------------------- */

/**
 * Inline-rename control. Matches [ClientDetailPanel.EditableClientName]
 * visually + behaviourally: dashed underline hint, click/Enter to edit,
 * Enter to commit, Esc to cancel, blur to commit, inline error below
 * the input, focus+select-all on entering edit mode.
 *
 * When `canEdit` is false (practitioner role on the active practice)
 * the control renders as plain text with a tooltip explaining why
 * editing is disabled. Owners get the full affordance.
 */
function EditablePracticeName({
  practiceId,
  name,
  canEdit,
  onRenamed,
}: {
  practiceId: string;
  name: string;
  canEdit: boolean;
  onRenamed: (newName: string) => void;
}) {
  const router = useRouter();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(name);
  const [error, setError] = useState<string | null>(null);
  const [saving, startSave] = useTransition();
  const [toast, setToast] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);

  // Focus + select on entering edit mode so the ugly default
  // `{email} Practice` is one keystroke away from being replaced.
  useEffect(() => {
    if (editing && inputRef.current) {
      inputRef.current.focus();
      inputRef.current.select();
    }
  }, [editing]);

  // Resync draft when parent name changes (e.g. after a practice switch).
  useEffect(() => {
    setDraft(name);
  }, [name]);

  // Dismiss toast after a short delay. Auto-cleared on each new toast.
  useEffect(() => {
    if (!toast) return;
    const id = window.setTimeout(() => setToast(null), 2500);
    return () => window.clearTimeout(id);
  }, [toast]);

  function startEditing() {
    if (!canEdit) return;
    setDraft(name);
    setError(null);
    setEditing(true);
  }

  function cancel() {
    setDraft(name);
    setError(null);
    setEditing(false);
  }

  function commit() {
    const trimmed = draft.trim();
    if (trimmed === name) {
      // No-op; just exit edit mode.
      setEditing(false);
      setError(null);
      return;
    }
    if (trimmed === '') {
      setError('Name can’t be empty.');
      return;
    }
    startSave(async () => {
      try {
        const supabase = getBrowserClient();
        const api = createPortalApi(supabase);
        await api.renamePractice(practiceId, trimmed);
        onRenamed(trimmed);
        setError(null);
        setEditing(false);
        setToast('Practice renamed.');
        // Refresh server data (BrandHeader subtitles, dashboard tiles,
        // anything else that reads `practices.name`). `router.refresh`
        // reruns the server component without a full navigation.
        router.refresh();
      } catch (e) {
        if (e instanceof RenamePracticeError) {
          if (e.kind === 'too-long') {
            setError('Name’s a bit long — keep it under 60 characters.');
          } else if (e.kind === 'empty') {
            setError('Name can’t be empty.');
          } else if (e.kind === 'not-owner') {
            setError('Only the practice owner can rename it.');
          } else {
            setError('Practice not found. Try refreshing.');
          }
        } else {
          const msg = e instanceof Error ? e.message : 'Something went wrong.';
          setError(`Couldn’t rename — ${msg}`);
        }
        // Stay in edit mode so the owner can fix + retry.
      }
    });
  }

  if (!canEdit) {
    // Read-only fallback for practitioners. No dashed underline (which
    // would imply editability), and a title attribute as the tooltip.
    return (
      <span
        className="font-heading text-base font-semibold text-ink"
        title="Only the practice owner can rename."
      >
        {name}
      </span>
    );
  }

  if (!editing) {
    return (
      <>
        <span
          role="button"
          tabIndex={0}
          onClick={startEditing}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              startEditing();
            }
          }}
          title="Click to rename"
          className="inline-block cursor-text border-b border-dashed border-ink-muted font-heading text-base font-semibold text-ink transition hover:border-brand focus-visible:border-brand focus-visible:outline-none"
        >
          {name}
        </span>
        <Toast text={toast} />
      </>
    );
  }

  return (
    <>
      <span className="inline-flex flex-col">
        <label htmlFor="practice-name-input" className="sr-only">
          Practice name
        </label>
        <input
          ref={inputRef}
          id="practice-name-input"
          type="text"
          value={draft}
          onChange={(e) => {
            setDraft(e.target.value);
            if (error) setError(null);
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              commit();
            } else if (e.key === 'Escape') {
              e.preventDefault();
              cancel();
            }
          }}
          onBlur={() => {
            if (!saving) commit();
          }}
          disabled={saving}
          maxLength={60}
          aria-invalid={error !== null}
          aria-describedby={error ? 'practice-name-error' : undefined}
          className={`min-w-[12rem] rounded-md border bg-surface-base px-2 py-1 font-heading text-base font-semibold text-ink focus:outline-none disabled:opacity-60 ${
            error
              ? 'border-error focus:border-error'
              : 'border-brand focus:border-brand'
          }`}
        />
        {error ? (
          <span
            id="practice-name-error"
            role="alert"
            className="mt-1 text-xs text-error"
          >
            {error}
          </span>
        ) : (
          <span className="mt-1 text-[11px] text-ink-dim">
            Enter to save · Esc to cancel
          </span>
        )}
      </span>
      <Toast text={toast} />
    </>
  );
}

/* ---------------------------------------------------------------------- */
/*  SwitchPopover — custom dark popover, replaces the old <select>        */
/* ---------------------------------------------------------------------- */

type PopoverState =
  | { open: false }
  | { open: true; triggerRect: DOMRect };

function SwitchPopover({
  practices,
  selectedId,
  balancesById,
}: {
  practices: PracticeWithRole[];
  selectedId: string;
  balancesById?: Record<string, number>;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const [state, setState] = useState<PopoverState>({ open: false });
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const popoverRef = useRef<HTMLDivElement | null>(null);

  const close = useCallback(() => setState({ open: false }), []);

  // Close on outside-click + Escape. Anchored to the trigger rect so we
  // can position the popover just under the link without a portal / a
  // floating-UI dependency.
  useEffect(() => {
    if (!state.open) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') close();
    }
    function onClick(e: MouseEvent) {
      const t = e.target as Node;
      if (popoverRef.current?.contains(t)) return;
      if (triggerRef.current?.contains(t)) return;
      close();
    }
    window.addEventListener('keydown', onKey);
    window.addEventListener('mousedown', onClick);
    return () => {
      window.removeEventListener('keydown', onKey);
      window.removeEventListener('mousedown', onClick);
    };
  }, [state.open, close]);

  function toggle() {
    if (state.open) {
      close();
      return;
    }
    const rect = triggerRef.current?.getBoundingClientRect();
    if (!rect) return;
    setState({ open: true, triggerRect: rect });
  }

  function switchTo(nextId: string) {
    if (nextId === selectedId) return;
    const params = new URLSearchParams(search?.toString() ?? '');
    params.set('practice', nextId);
    close();
    router.push(`${pathname}?${params.toString()}`);
  }

  // Memoised sort: active practice FIRST, then others in original order.
  // Keeps the active row anchored at the top regardless of membership
  // insertion order.
  const ordered = useMemo(() => {
    const active = practices.find((p) => p.id === selectedId);
    const others = practices.filter((p) => p.id !== selectedId);
    return active ? [active, ...others] : practices;
  }, [practices, selectedId]);

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        onClick={toggle}
        aria-haspopup="menu"
        aria-expanded={state.open}
        className="group inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-sm text-ink-muted transition hover:text-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40"
      >
        <SwitchGlyph />
        <span>Switch</span>
      </button>

      {state.open && (
        <PopoverCard
          ref={popoverRef}
          triggerRect={state.triggerRect}
          onClose={close}
        >
          <ul
            role="menu"
            className="flex flex-col divide-y divide-surface-border/60"
          >
            {ordered.map((p) => (
              <PracticeRow
                key={p.id}
                practice={p}
                active={p.id === selectedId}
                credits={balancesById?.[p.id]}
                onPick={() => switchTo(p.id)}
              />
            ))}
          </ul>
        </PopoverCard>
      )}
    </>
  );
}

/**
 * Popover card — positioned absolutely relative to the viewport, fade +
 * slide-up via Tailwind animation classes. Constrained to ≤240px wide
 * per the brief. Auto-clamps to the viewport so we don't overflow the
 * right edge on narrow layouts.
 *
 * Positioning strategy: fixed, top = triggerBottom + 6px, left = aligned
 * to the trigger's left edge but clamped so (left + width) ≤ viewportW
 * - 8px. Simple enough to not need floating-ui.
 */
const PopoverCard = forwardRef<
  HTMLDivElement,
  {
    triggerRect: DOMRect;
    onClose: () => void;
    children: React.ReactNode;
  }
>(function PopoverCardInner({ triggerRect, children }, ref) {
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);

  useEffect(() => {
    const WIDTH = 240;
    const GAP = 6;
    const PAD = 8;
    const viewportW = window.innerWidth;
    const rawLeft = triggerRect.left;
    const maxLeft = viewportW - WIDTH - PAD;
    const left = Math.max(PAD, Math.min(rawLeft, maxLeft));
    const top = triggerRect.bottom + GAP;
    setPos({ top, left });
  }, [triggerRect]);

  if (!pos) return null;

  return (
    <div
      ref={ref}
      role="dialog"
      aria-label="Switch practice"
      style={{
        position: 'fixed',
        top: pos.top,
        left: pos.left,
        width: 240,
        zIndex: 50,
      }}
      className="animate-[fadeSlideUp_150ms_ease-out] overflow-hidden rounded-lg border border-surface-border bg-surface-raised shadow-[0_8px_24px_rgba(0,0,0,0.35)]"
    >
      {children}
    </div>
  );
});

function PracticeRow({
  practice,
  active,
  credits,
  onPick,
}: {
  practice: PracticeWithRole;
  active: boolean;
  credits: number | undefined;
  onPick: () => void;
}) {
  const subtitle =
    credits === undefined
      ? practice.role === 'owner'
        ? 'Owner'
        : 'Practitioner'
      : `${credits} ${credits === 1 ? 'credit' : 'credits'}`;

  if (active) {
    return (
      <li role="none">
        <div
          role="menuitem"
          aria-current="true"
          aria-disabled="true"
          className="flex cursor-default items-start justify-between gap-3 px-3 py-2.5 text-left"
        >
          <div className="min-w-0">
            <p className="truncate text-sm font-semibold text-ink">
              {practice.name}
            </p>
            <p className="text-xs text-ink-muted">{subtitle}</p>
          </div>
          <span
            aria-hidden="true"
            className="mt-0.5 inline-flex h-4 w-4 items-center justify-center text-brand"
            title="Active"
          >
            <CheckGlyph />
          </span>
        </div>
      </li>
    );
  }

  return (
    <li role="none">
      <button
        type="button"
        role="menuitem"
        onClick={onPick}
        className="flex w-full cursor-pointer items-start justify-between gap-3 px-3 py-2.5 text-left transition hover:bg-surface-base focus-visible:bg-surface-base focus-visible:outline-none"
      >
        <div className="min-w-0">
          <p className="truncate text-sm font-medium text-ink">
            {practice.name}
          </p>
          <p className="text-xs text-ink-muted">{subtitle}</p>
        </div>
      </button>
    </li>
  );
}

/* ---------------------------------------------------------------------- */
/*  Glyphs + toast                                                        */
/* ---------------------------------------------------------------------- */

function SwitchGlyph() {
  // ⇄-style horizontal swap arrows. Inline SVG so it picks up
  // `currentColor` + resists icon-font loading jitter.
  return (
    <svg
      viewBox="0 0 20 20"
      fill="none"
      aria-hidden="true"
      className="h-3.5 w-3.5"
    >
      <path
        d="M4 7h11l-3-3M16 13H5l3 3"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function CheckGlyph() {
  return (
    <svg
      viewBox="0 0 20 20"
      fill="none"
      aria-hidden="true"
      className="h-4 w-4"
    >
      <path
        d="M4 10l3.5 3.5L16 6"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/**
 * Lightweight confirmation toast — same visual language as the client-
 * detail toast, but scoped to the rename affordance so we don't have
 * to plumb a global toast provider into the dashboard. R-01: inline,
 * not a modal.
 */
function Toast({ text }: { text: string | null }) {
  if (!text) return null;
  return (
    <div
      role="status"
      aria-live="polite"
      className="pointer-events-none fixed inset-x-0 bottom-6 z-50 flex justify-center px-4"
    >
      <div className="pointer-events-auto rounded-md border border-surface-border bg-surface-raised px-4 py-3 text-sm text-ink shadow-focus-ring">
        {text}
      </div>
    </div>
  );
}
