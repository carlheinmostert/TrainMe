'use client';

import {
  forwardRef,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import { ChevronDown } from 'lucide-react';
import type { PracticeWithRole } from '@/lib/supabase/api';

/**
 * HeaderIdentityStack — replaces the Wave 40 chip cluster.
 *
 * Renders a two-line right-aligned identity block:
 *
 *   Signed in as {email}
 *   In practice {Practice Name} ⌄
 *   Sign out
 *
 * Design rationale (cosmetic pass, 2026-05-22):
 *   - The chip-style switcher + account dropdown crowded the header and
 *     duplicated affordances that now live in tiles (Account settings →
 *     the Account dashboard tile). With Account moved into a tile, the
 *     dropdown can collapse to a plain "Sign out" text link.
 *   - The practice-name chevron is hidden when the practitioner belongs
 *     to a single practice (no menu to open). Owners with multiple
 *     practices get the same dark popover as the old
 *     PracticeContextLine.SwitchPopover — lifted into this file so the
 *     dashboard surface no longer needs a duplicate context line.
 *   - R-02 (header purity) preserved: identity + tenant context only,
 *     no page titles or action buttons.
 */
export type HeaderIdentityStackProps = {
  email: string;
  practices: PracticeWithRole[];
  selectedId: string | null;
};

export function HeaderIdentityStack({
  email,
  practices,
  selectedId,
}: HeaderIdentityStackProps) {
  const selected =
    selectedId !== null
      ? practices.find((p) => p.id === selectedId) ?? practices[0] ?? null
      : null;

  return (
    <div className="flex flex-col items-end gap-0.5 text-xs leading-snug">
      <div className="truncate text-ink-muted">
        <span className="text-ink-dim">Signed in as </span>
        <span
          className="font-medium text-ink"
          title={email || undefined}
        >
          {email || 'unknown'}
        </span>
      </div>

      {selected && (
        <PracticeLine practices={practices} selected={selected} />
      )}

      <SignOutLink />
    </div>
  );
}

/* ---------------------------------------------------------------------- */
/*  Practice line — name + chevron-switcher (hidden if only one practice) */
/* ---------------------------------------------------------------------- */

function PracticeLine({
  practices,
  selected,
}: {
  practices: PracticeWithRole[];
  selected: PracticeWithRole;
}) {
  const hasMany = practices.length > 1;

  // Single-practice case: render as plain prose with no affordance —
  // there's nothing to switch to.
  if (!hasMany) {
    return (
      <div className="truncate text-ink-muted">
        <span className="text-ink-dim">In practice </span>
        <span className="font-medium text-ink">{selected.name}</span>
      </div>
    );
  }

  return <PracticeSwitchTrigger practices={practices} selectedId={selected.id} />;
}

function PracticeSwitchTrigger({
  practices,
  selectedId,
}: {
  practices: PracticeWithRole[];
  selectedId: string;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const [open, setOpen] = useState(false);
  const [triggerRect, setTriggerRect] = useState<DOMRect | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const popoverRef = useRef<HTMLDivElement | null>(null);

  const selected = useMemo(
    () => practices.find((p) => p.id === selectedId) ?? practices[0],
    [practices, selectedId],
  );

  const close = useCallback(() => {
    setOpen(false);
    setTriggerRect(null);
  }, []);

  useEffect(() => {
    if (!open) return;
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
  }, [open, close]);

  function toggle() {
    if (open) {
      close();
      return;
    }
    const rect = triggerRef.current?.getBoundingClientRect() ?? null;
    if (!rect) return;
    setTriggerRect(rect);
    setOpen(true);
  }

  function switchTo(nextId: string) {
    if (nextId === selectedId) {
      close();
      return;
    }
    const params = new URLSearchParams(search?.toString() ?? '');
    params.set('practice', nextId);
    close();
    router.push(`${pathname}?${params.toString()}`);
  }

  const ordered = orderActiveFirst(practices, selectedId);

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        onClick={toggle}
        aria-haspopup="menu"
        aria-expanded={open}
        title={`Active practice: ${selected.name} — click to switch`}
        className="inline-flex max-w-[260px] items-center gap-1 truncate rounded-sm text-ink-muted transition hover:text-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 sm:max-w-[320px]"
      >
        <span className="text-ink-dim">In practice </span>
        <span className="truncate font-medium text-ink">{selected.name}</span>
        <ChevronDown
          aria-hidden="true"
          className="ml-0.5 h-3 w-3 shrink-0 text-ink-dim"
          strokeWidth={1.75}
        />
      </button>

      {open && triggerRect && (
        <PopoverCard ref={popoverRef} triggerRect={triggerRect} alignRight>
          <ul
            role="menu"
            className="flex flex-col divide-y divide-surface-border/60"
          >
            {ordered.map((p) => (
              <PracticeRow
                key={p.id}
                practice={p}
                active={p.id === selectedId}
                onPick={() => switchTo(p.id)}
              />
            ))}
          </ul>
        </PopoverCard>
      )}
    </>
  );
}

function orderActiveFirst(
  practices: PracticeWithRole[],
  selectedId: string,
): PracticeWithRole[] {
  const active = practices.find((p) => p.id === selectedId);
  const others = practices.filter((p) => p.id !== selectedId);
  return active ? [active, ...others] : practices;
}

function PracticeRow({
  practice,
  active,
  onPick,
}: {
  practice: PracticeWithRole;
  active: boolean;
  onPick: () => void;
}) {
  const subtitle = practice.role === 'owner' ? 'Owner' : 'Practitioner';

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
/*  Sign-out link                                                         */
/* ---------------------------------------------------------------------- */

function SignOutLink() {
  function handleClick(e: React.MouseEvent<HTMLAnchorElement>) {
    e.preventDefault();
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = '/auth/sign-out';
    document.body.appendChild(form);
    form.submit();
  }
  return (
    <a
      href="/auth/sign-out"
      onClick={handleClick}
      className="text-xs text-ink-dim transition hover:text-brand focus-visible:outline-none focus-visible:text-brand"
    >
      Sign out
    </a>
  );
}

/* ---------------------------------------------------------------------- */
/*  PopoverCard — viewport-anchored, right-aligned for the header cluster */
/* ---------------------------------------------------------------------- */

const PopoverCard = forwardRef<
  HTMLDivElement,
  {
    triggerRect: DOMRect;
    alignRight?: boolean;
    children: React.ReactNode;
  }
>(function PopoverCardInner({ triggerRect, alignRight, children }, ref) {
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);

  useEffect(() => {
    const WIDTH = 240;
    const GAP = 6;
    const PAD = 8;
    const viewportW = window.innerWidth;
    let left: number;
    if (alignRight) {
      const rawLeft = triggerRect.right - WIDTH;
      left = Math.max(PAD, Math.min(rawLeft, viewportW - WIDTH - PAD));
    } else {
      const rawLeft = triggerRect.left;
      left = Math.max(PAD, Math.min(rawLeft, viewportW - WIDTH - PAD));
    }
    const top = triggerRect.bottom + GAP;
    setPos({ top, left });
  }, [triggerRect, alignRight]);

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
