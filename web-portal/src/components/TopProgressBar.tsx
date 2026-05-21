'use client';

import { usePathname } from 'next/navigation';
import { useEffect, useRef, useState } from 'react';

/**
 * TopProgressBar — a thin coral progress bar fixed to the top of the
 * viewport that animates on every client-side navigation. App Router
 * streams pages, so a Link click can take a beat before paint; this
 * bar closes the perception gap.
 *
 * Triggers:
 *   - pathname change (covers Link clicks, router.push, back/forward)
 *   - click on any <a href> with an internal URL (instant feedback
 *     before pathname changes, killing the awkward gap)
 *
 * Sequence: show -> slide 0% -> 70% (held) -> snap to 100% -> fade out.
 * Pure CSS transitions, no dependency on nprogress or similar.
 */
export function TopProgressBar() {
  const pathname = usePathname();
  const [visible, setVisible] = useState(false);
  const [width, setWidth] = useState(0);
  // F-H4 fix (synthesis 2026-05-21): the click handler primes the bar
  // to 40% for instant feedback; on instant-paint routes the pathname
  // effect fires the same tick and snaps width back to 0 before the
  // animation can play, producing a visible flicker. Track whether
  // the click already primed the bar so the pathname effect can pick
  // up at 70% instead of resetting.
  const primedByClickRef = useRef(false);

  // Instant feedback: catch internal anchor clicks before navigation.
  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.shiftKey) return;
      const a = (e.target as HTMLElement | null)?.closest('a');
      if (!a) return;
      const href = a.getAttribute('href');
      if (!href || href.startsWith('#') || a.target === '_blank') return;
      if (/^[a-z]+:\/\//i.test(href) && !href.startsWith(location.origin)) return;
      setVisible(true);
      setWidth(40);
      primedByClickRef.current = true;
    }
    document.addEventListener('click', onClick, true);
    return () => document.removeEventListener('click', onClick, true);
  }, []);

  // Run the animate-to-completion sequence on every pathname change.
  useEffect(() => {
    setVisible(true);
    // If the click handler already primed the bar (visible + width=40),
    // skip the reset-to-0 and jump straight to 70% so the animation
    // continues smoothly. Otherwise (programmatic router.push, back/
    // forward), do the full 0 -> 70 -> 100 ramp.
    const wasPrimed = primedByClickRef.current;
    primedByClickRef.current = false;
    if (!wasPrimed) setWidth(0);
    const toMid = setTimeout(() => setWidth(70), wasPrimed ? 0 : 16);
    const toFull = setTimeout(() => setWidth(100), 500);
    const toHide = setTimeout(() => {
      setVisible(false);
      setWidth(0);
    }, 850);
    return () => {
      clearTimeout(toMid);
      clearTimeout(toFull);
      clearTimeout(toHide);
    };
  }, [pathname]);

  return (
    <div
      aria-hidden
      style={{
        position: 'fixed',
        top: 0,
        left: 0,
        height: '2px',
        width: `${width}%`,
        background: '#ff6b35',
        boxShadow: '0 0 8px rgba(255, 107, 53, 0.6)',
        opacity: visible ? 1 : 0,
        transition:
          'width 400ms cubic-bezier(0.16, 1, 0.3, 1), opacity 300ms ease-out',
        zIndex: 9999,
        pointerEvents: 'none',
      }}
    />
  );
}
