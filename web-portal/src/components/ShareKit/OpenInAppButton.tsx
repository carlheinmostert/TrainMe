'use client';

/**
 * OpenInAppButton — secondary sibling to <CopyButton/> that fires a
 * Phase 2 intent URL (`wa.me` / `mailto:`) via a native anchor click.
 *
 * Why an `<a>` and not `window.open`?
 *   - `mailto:` destinations are handled by the OS, not the browser —
 *     `window.open('mailto:…')` can open a blank tab + trigger popup
 *     blockers. A real anchor with `href="mailto:…"` avoids both.
 *   - `wa.me` links open the native WhatsApp app when installed; a
 *     direct anchor lets the browser pick the right handler instead
 *     of forcing a new tab.
 *
 * Styling mirrors <CopyButton/>'s secondary variant (border + ink) so
 * the two CTAs read as a pair on every format card. The button label
 * is voice-locked (R-06) — "Open in WhatsApp" / "Open in mail client".
 *
 * `href` is a thunk like <CopyButton/>'s `getText`: the caller can
 * rebuild the URL per-render (e.g. when the 1:1 card's colleague name
 * input changes) without forcing a parent-level state machine.
 */
export function OpenInAppButton({
  getHref,
  label,
  ariaLabel,
  glyph,
  target,
  rel,
  onOpen,
}: {
  /** Lazy URL builder — invoked on click. */
  getHref: () => string;
  /** Voice-locked button label. */
  label: string;
  /** Optional accessible label override; defaults to `label`. */
  ariaLabel?: string;
  /** Leading SVG glyph — WhatsApp or send/mail icon. */
  glyph: React.ReactNode;
  /**
   * Anchor target. Omit for `mailto:` so the OS handler owns the
   * navigation; set to "_blank" for `wa.me` where desktop users may
   * benefit from a new tab (noreferrer keeps WhatsApp Web honest).
   */
  target?: '_blank';
  rel?: string;
  /**
   * Optional fire-and-forget callback invoked on click, before the
   * browser follows the href. Wave 10 Phase 3 uses it to log a
   * `share_events` row (channel = whatsapp / email, event_kind =
   * open_intent). Do NOT await inside — analytics must not delay the
   * native handler hand-off.
   */
  onOpen?: () => void;
}) {
  const base =
    'inline-flex items-center justify-center gap-2 rounded-full px-4 h-10 text-sm font-semibold transition duration-fast ease-standard focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40';
  const variantCls =
    'border border-surface-border bg-transparent text-ink hover:border-brand-tint-border hover:text-brand-light';

  // React event handlers on anchors run before the browser follows the
  // href, so we resolve the current URL at click time. This lets the
  // colleague-name input drive the 1:1 intent URL without re-rendering
  // the anchor's `href` attribute on every keystroke.
  function handleClick(event: React.MouseEvent<HTMLAnchorElement>) {
    const resolved = getHref();
    if (event.currentTarget.href !== resolved) {
      event.currentTarget.href = resolved;
    }
    // Fire-and-forget analytics. Swallowed errors so a flaky RPC doesn't
    // block the navigation.
    if (onOpen) {
      try {
        onOpen();
      } catch {
        // Intentionally silent.
      }
    }
  }

  return (
    <a
      // We seed `href` with an initial resolve so keyboard users and
      // right-click "copy link" see a real destination before the
      // onClick runs.
      href={getHref()}
      onClick={handleClick}
      target={target}
      rel={rel}
      aria-label={ariaLabel ?? label}
      className={`${base} ${variantCls}`}
    >
      {glyph}
      {label}
    </a>
  );
}

/** Small paper-plane glyph reused by the email CTA. */
export function SendGlyph() {
  return (
    <svg
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className="h-3.5 w-3.5"
    >
      <path d="M12.5 1.5 6 8M12.5 1.5 8.5 12.5 6 8 1.5 6Z" />
    </svg>
  );
}

/** Compact WhatsApp bubble glyph; same outline as the card's header. */
export function WhatsAppOutboundGlyph() {
  return (
    <svg
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className="h-3.5 w-3.5"
    >
      <path d="M7 1.5a5.5 5.5 0 0 0-4.8 8.2L1.5 12.5l2.9-0.7A5.5 5.5 0 1 0 7 1.5Z" />
    </svg>
  );
}
