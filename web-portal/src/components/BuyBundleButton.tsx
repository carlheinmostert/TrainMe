'use client';

import { useState } from 'react';

type Props = {
  bundleKey: string;
  bundleName: string;
  practiceId: string;
};

// Client-side Buy button. Posts to /credits/purchase which returns a signed
// PayFast checkout URL; we then redirect the top-level window to it.
//
// We avoid a plain <form action=post> so we can show a loading / error state
// and so the 302-to-external-domain doesn't cross a Next.js server action.
export function BuyBundleButton({ bundleKey, bundleName, practiceId }: Props) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleClick() {
    if (loading) return;
    setLoading(true);
    setError(null);
    try {
      const res = await fetch('/credits/purchase', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ bundleKey, practiceId }),
      });
      if (!res.ok) {
        const body = (await res.json().catch(() => ({}))) as {
          error?: string;
        };
        throw new Error(body.error ?? `HTTP ${res.status}`);
      }
      const body = (await res.json()) as { checkoutUrl?: string };
      if (!body.checkoutUrl) {
        throw new Error('no checkout URL returned');
      }
      window.location.href = body.checkoutUrl;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Something went wrong');
      setLoading(false);
    }
  }

  return (
    <div className="mt-6">
      <button
        type="button"
        onClick={handleClick}
        disabled={loading || !practiceId}
        className="w-full rounded-md bg-brand px-4 py-2.5 text-sm font-semibold text-surface-bg transition hover:bg-brand-light focus-visible:outline-brand disabled:cursor-not-allowed disabled:opacity-60"
      >
        {loading ? 'Redirecting to PayFast…' : `Buy ${bundleName}`}
      </button>
      {error && (
        <p className="mt-2 text-xs text-warning" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}
