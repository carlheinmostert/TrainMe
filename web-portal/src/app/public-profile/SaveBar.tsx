'use client';

import { useEffect, useState } from 'react';

type Props = {
  pending: boolean;
  error: string | null;
  savedAt: number | null;
  onSave: () => void;
  disabled?: boolean;
  label?: string;
};

/**
 * Shared save-button row used by both BrandingPanel and IdentityPanel.
 * "Saved" confirmation auto-fades after 3 s; errors stay visible until
 * the next save attempt.
 */
export function SaveBar({
  pending,
  error,
  savedAt,
  onSave,
  disabled,
  label,
}: Props) {
  const [visibleConfirm, setVisibleConfirm] = useState<number | null>(savedAt);

  useEffect(() => {
    if (!savedAt) return;
    setVisibleConfirm(savedAt);
    const t = setTimeout(() => setVisibleConfirm(null), 3000);
    return () => clearTimeout(t);
  }, [savedAt]);

  return (
    <div className="mt-4 flex items-center gap-3">
      <button
        type="button"
        onClick={onSave}
        disabled={pending || disabled}
        className="rounded-md bg-brand px-4 py-2 text-sm font-semibold text-surface-bg hover:bg-brand-light disabled:cursor-not-allowed disabled:opacity-50"
      >
        {pending ? 'Saving…' : (label ?? 'Save')}
      </button>
      {visibleConfirm && !error && (
        <span className="text-xs text-ink-muted">
          Saved · {new Date(visibleConfirm).toLocaleTimeString()}
        </span>
      )}
      {error && <span className="text-xs text-error">{error}</span>}
    </div>
  );
}
