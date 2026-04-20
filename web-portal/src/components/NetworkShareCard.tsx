'use client';

import { useState, useTransition } from 'react';
import {
  referralUrl,
  whatsappHref,
  imessageHref,
  mailtoHref,
} from '@/lib/referral-share';

type Props = {
  practiceId: string;
  initialCode: string | null;
};

type Toast = { kind: 'success' | 'undo'; text: string } | null;

// "Your network" card — share link + channels + regenerate.
// Voice: peer-to-peer ("practitioners in your network", "your referral link").
// R-01: regenerate fires immediately with an undo toast; no modal "are you sure".
// R-09: the copy button is obvious — clipboard icon + text, single tap.
export function NetworkShareCard({ practiceId, initialCode }: Props) {
  const [code, setCode] = useState<string | null>(initialCode);
  const [toast, setToast] = useState<Toast>(null);
  const [copyState, setCopyState] = useState<'idle' | 'copied'>('idle');
  const [pending, startTransition] = useTransition();

  const link = code ? referralUrl(code) : '';

  async function handleCopy() {
    if (!code) return;
    try {
      await navigator.clipboard.writeText(link);
      setCopyState('copied');
      setTimeout(() => setCopyState('idle'), 2000);
    } catch {
      setCopyState('idle');
    }
  }

  async function handleRegenerate() {
    if (!code) return;
    const previous = code;
    setCode(null);

    startTransition(async () => {
      const res = await fetch('/api/referral/regenerate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ practiceId }),
      });
      const body = (await res.json().catch(() => null)) as {
        code?: string;
      } | null;

      if (res.ok && body?.code) {
        setCode(body.code);
        setToast({
          kind: 'undo',
          text: 'Code rotated. The old link stopped working.',
        });
      } else {
        // Failed — roll back. No modal, no shame — just restore + inform.
        setCode(previous);
        setToast({ kind: 'success', text: "Couldn't rotate the code. Try again." });
      }

      setTimeout(() => setToast(null), 5000);
    });
  }

  return (
    <section
      className="rounded-lg border border-surface-border bg-surface-base p-5"
      aria-labelledby="network-share-heading"
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 id="network-share-heading" className="font-heading text-lg font-semibold">
            Your network
          </h2>
          <p className="mt-1 text-sm text-ink-muted">
            Share your link with colleagues. They get +10 starter credits when
            they make their first purchase. You get a 5% lifetime rebate on
            everything they spend, paid in free credits.
          </p>
        </div>
      </div>

      {/* Copyable URL */}
      <div className="mt-5">
        <label className="text-xs font-medium uppercase tracking-wider text-ink-muted">
          Your link
        </label>
        <div className="mt-2 flex items-stretch gap-2">
          <input
            readOnly
            aria-label="Referral link"
            value={link}
            className="flex-1 rounded-md border border-surface-border bg-surface-raised px-3 py-2 font-mono text-sm text-ink focus:border-brand focus:outline-none"
          />
          <button
            type="button"
            onClick={handleCopy}
            disabled={!code}
            className="inline-flex items-center justify-center gap-2 rounded-md bg-brand px-3 py-2 text-sm font-semibold text-surface-bg transition hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-60"
          >
            <ClipboardIcon />
            {copyState === 'copied' ? 'Copied' : 'Copy'}
          </button>
        </div>
      </div>

      {/* Share channels */}
      <div className="mt-5">
        <p className="text-xs font-medium uppercase tracking-wider text-ink-muted">
          Share via
        </p>
        <div className="mt-2 flex flex-wrap gap-2">
          <ChannelButton
            href={code ? whatsappHref(code) : '#'}
            disabled={!code}
            label="WhatsApp"
            external
          />
          <ChannelButton
            href={code ? imessageHref(code) : '#'}
            disabled={!code}
            label="iMessage"
          />
          <ChannelButton
            href={code ? mailtoHref(code) : '#'}
            disabled={!code}
            label="Email"
          />
        </div>
      </div>

      {/* Regenerate */}
      <div className="mt-5 border-t border-surface-border pt-4">
        <button
          type="button"
          onClick={handleRegenerate}
          disabled={!code || pending}
          className="text-xs text-ink-muted underline-offset-4 transition hover:text-brand hover:underline disabled:cursor-not-allowed disabled:opacity-60"
        >
          {pending ? 'Rotating\u2026' : 'Regenerate code'}
        </button>
        <p className="mt-1 text-xs text-ink-dim">
          Rotating your code stops the old link from working. Anyone already
          in your network stays linked.
        </p>
      </div>

      {/* Undo toast — per R-01, destructive path uses toast not modal. */}
      {toast && (
        <div
          role="status"
          aria-live="polite"
          className="pointer-events-none fixed inset-x-0 bottom-6 z-50 flex justify-center px-4"
        >
          <div className="pointer-events-auto rounded-md border border-surface-border bg-surface-raised px-4 py-3 text-sm text-ink shadow-focus-ring">
            {toast.text}
          </div>
        </div>
      )}
    </section>
  );
}

function ChannelButton({
  href,
  label,
  disabled,
  external,
}: {
  href: string;
  label: string;
  disabled: boolean;
  external?: boolean;
}) {
  const cls =
    'inline-flex items-center gap-2 rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm font-medium text-ink transition hover:border-brand hover:text-brand';
  if (disabled) {
    return (
      <span
        aria-disabled="true"
        className={`${cls} cursor-not-allowed opacity-50`}
      >
        {label}
      </span>
    );
  }
  return (
    <a
      href={href}
      className={cls}
      {...(external ? { target: '_blank', rel: 'noreferrer noopener' } : {})}
    >
      {label}
    </a>
  );
}

function ClipboardIcon() {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      className="h-4 w-4"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}
