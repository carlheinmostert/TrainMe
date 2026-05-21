'use client';

import { useState, type KeyboardEvent } from 'react';

const MAX_CHIPS = 8;

type Props = {
  value: string[];
  onChange: (next: string[]) => void;
  isOwner: boolean;
};

/**
 * Chip-style specialties editor. Enter adds the trimmed draft as a
 * chip (deduped); Backspace on an empty input removes the last chip.
 * Capped at 8 entries to match the migration's `specialties_max`
 * CHECK constraint.
 */
export function SpecialtiesEditor({ value, onChange, isOwner }: Props) {
  const [draft, setDraft] = useState('');

  const add = () => {
    const trimmed = draft.trim();
    if (!trimmed) return;
    if (value.includes(trimmed)) {
      setDraft('');
      return;
    }
    if (value.length >= MAX_CHIPS) return;
    onChange([...value, trimmed]);
    setDraft('');
  };

  const remove = (chip: string) => {
    onChange(value.filter((c) => c !== chip));
  };

  const onKey = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      add();
    }
    if (e.key === 'Backspace' && draft === '' && value.length > 0) {
      remove(value[value.length - 1]);
    }
  };

  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-wrap gap-2">
        {value.map((chip) => (
          <span
            key={chip}
            className="inline-flex items-center gap-2 rounded-full border border-surface-border bg-surface-raised px-3 py-1 text-sm text-ink"
          >
            {chip}
            {isOwner && (
              <button
                type="button"
                onClick={() => remove(chip)}
                className="text-ink-muted hover:text-error"
                aria-label={`Remove ${chip}`}
              >
                ×
              </button>
            )}
          </span>
        ))}
      </div>
      {isOwner && (
        <div className="flex items-center gap-2">
          <input
            type="text"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onKey}
            placeholder={
              value.length >= MAX_CHIPS
                ? 'Max 8 reached'
                : 'Add a specialty + Enter'
            }
            disabled={value.length >= MAX_CHIPS}
            className="flex-1 rounded-md border border-surface-border bg-surface-bg px-3 py-2 text-sm text-ink placeholder:text-ink-muted focus:border-brand focus:outline-none disabled:opacity-50"
          />
          <span className="text-xs text-ink-muted">
            {value.length} / {MAX_CHIPS}
          </span>
        </div>
      )}
    </div>
  );
}
