'use client';

import {
  forwardRef,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import Link from 'next/link';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import type { PracticeWithRole } from '@/lib/supabase/api';

/**
 * HeaderRightCluster — Wave 40 P2 + P3 right-side header cluster.
 *
 * Renders, right-to-left:
 *   [Practice: {Name} ⇄]   [{email} ▾]
 *
 * Design rationale (Wave 40):
 *   - P1 retires the duplicated nav links (Clients · Credits · Network · …);
 *     the dashboard tiles ARE the menu. The header becomes a thin chrome
 *     band with logo + identity context only.
 *   - P2: the signed-in email is visible at a glance — no hover required.
 *     Tap opens an account-menu dropdown (Account settings, Sign out).
 *   - P3: practice switcher sits to the LEFT of the email chip and reuses
 *     the existing Milestone N popover model (no new modal). The chip
 *     renders only when the caller has > 1 practice; single-practice users
 *     see static text.
 *
 * Both controls are unconditionally present even on pages without a
 * resolved practice (e.g. /sign-up before bootstrap). In that edge case,
 * the practice chip is skipped and only the account chip surfaces.
 */
export type HeaderRightClusterProps = {
  email: string;
  practices: PracticeWithRole[];
  selectedId: string | null;
  /** Path to the Account page. Caller threads the `?practice=` qs in. */
  accountHref: string;
};

export function HeaderRightCluster({
  email,
  practices,
  selectedId,
  accountHref,
}: HeaderRightClusterProps) {
  const hasPractice = selectedId !== null && practices.length > 0;
  const selected = hasPractice
    ? practices.find((p) => p.id === selectedId) ?? practices[0]
    : null;

  return (
    <div className="flex items-center gap-2">
      {selected && (
        <PracticeSwitcherChip
          practices={practices}
          selectedId={selected.id}
          selectedName={selected.name}
        />
      )}
      <AccountMenuChip email={email} accountHref={accountHref} />
    </div>
  );
}

/* ---------------------------------------------------------------------- */
/*  PracticeSwitcherChip                                                  */
/* ---------------------------------------------------------------------- */

function PracticeSwitcherChip({
  practices,
  selectedId,
  selectedName,
}: {
  practices: PracticeWithRole[];
  selectedId: string;
  selectedName: string;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const [open, setOpen] = useState(false);
  const [triggerRect, setTriggerRect] = useState<DOMRect | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const popoverRef = useRef<HTMLDivElement | null>(null);

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

  const hasMany = practices.length > 1;

  function toggle() {
    if (!hasMany) return;
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
    if (nextId === selectedId) return;
    const params = new URLSearchParams(search?.toString() ?? '');
    params.set('practice', nextId);
    close();
    router.push(`${pathname}?${params.toString()}`);
  }

  // Single-practice fallback — render as static text, no chrome.
  if (!hasMany) {
    return (
      <span
        className="hidden truncate rounded-md px-2.5 py-1.5 text-xs text-ink-muted sm:inline-flex sm:max-w-[200px]"
        title={`Active practice: ${selectedName}`}
      >
        <span className="truncate">{selectedName}</span>
      </span>
    );
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
        title={`Active practice: ${selectedName} — click to switch`}
        className="inline-flex max-w-[180px] items-center gap-1.5 rounded-md border border-surface-border bg-surface-raised px-2.5 py-1.5 text-xs text-ink transition hover:border-brand hover:text-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 sm:max-w-[220px]"
      >
        <span className="truncate font-medium">{selectedName}</span>
        <SwitchGlyph />
      </button>

      {open && triggerRect && (
        <PopoverCard ref={popoverRef} triggerRect={triggerRect}>
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
/*  AccountMenuChip — email + dropdown                                    */
/* ---------------------------------------------------------------------- */

function AccountMenuChip({
  email,
  accountHref,
}: {
  email: string;
  accountHref: string;
}) {
  const [open, setOpen] = useState(false);
  const [triggerRect, setTriggerRect] = useState<DOMRect | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const popoverRef = useRef<HTMLDivElement | null>(null);

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

  // The signed-in email is the chip label. Truncate on narrow viewports
  // so the cluster doesn't shove the logo off-screen on iPhone-sized
  // browsers; the title attr exposes the full address on hover.
  const displayLabel = useMemo(() => email || 'Account', [email]);

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        onClick={toggle}
        aria-haspopup="menu"
        aria-expanded={open}
        title={email}
        className="inline-flex max-w-[180px] items-center gap-1.5 rounded-md border border-surface-border bg-surface-raised px-2.5 py-1.5 text-xs text-ink transition hover:border-brand hover:text-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 sm:max-w-[260px]"
      >
        <span className="truncate font-medium">{displayLabel}</span>
        <CaretGlyph />
      </button>

      {open && triggerRect && (
        <PopoverCard ref={popoverRef} triggerRect={triggerRect} alignRight>
          <ul role="menu" className="flex flex-col">
            <li role="none">
              <Link
                role="menuitem"
                href={accountHref}
                onClick={close}
                className="block px-3 py-2.5 text-sm text-ink transition hover:bg-surface-base focus-visible:bg-surface-base focus-visible:outline-none"
              >
                Account settings
              </Link>
            </li>
            <li role="none" className="border-t border-surface-border/60">
              <SignOutMenuItem />
            </li>
          </ul>
        </PopoverCard>
      )}
    </>
  );
}

/**
 * Sign-out menu item — fires the existing `/auth/sign-out` POST route via
 * a programmatic form submit. The route handler clears the cookie + 303s
 * back to `/`. No undo here (the dashboard / Account page surfaces still
 * own the R-01 undo flow); this is a fast-path one-click sign-out for
 * shared-machine scenarios.
 */
function SignOutMenuItem() {
  function handleClick() {
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = '/auth/sign-out';
    document.body.appendChild(form);
    form.submit();
  }
  return (
    <button
      type="button"
      role="menuitem"
      onClick={handleClick}
      className="block w-full px-3 py-2.5 text-left text-sm text-ink-muted transition hover:bg-surface-base hover:text-ink focus-visible:bg-surface-base focus-visible:outline-none"
    >
      Sign out
    </button>
  );
}

/* ---------------------------------------------------------------------- */
/*  PopoverCard — shared between switcher + account menu                  */
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
      // Align the popover's right edge with the trigger's right edge —
      // the email chip sits at the far right of the header, so a
      // left-aligned popover would stick into negative space.
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
      aria-label="Menu"
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

/* ---------------------------------------------------------------------- */
/*  Glyphs                                                                */
/* ---------------------------------------------------------------------- */

function SwitchGlyph() {
  return (
    <svg
      viewBox="0 0 20 20"
      fill="none"
      aria-hidden="true"
      className="h-3 w-3 shrink-0"
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

function CaretGlyph() {
  return (
    <svg
      viewBox="0 0 12 12"
      fill="none"
      aria-hidden="true"
      className="h-2.5 w-2.5 shrink-0"
    >
      <path
        d="M3 4.5l3 3 3-3"
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
