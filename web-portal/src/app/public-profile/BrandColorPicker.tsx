'use client';

import { useMemo } from 'react';

type Props = {
  value: string | null;
  onChange: (hex: string | null) => void;
  isOwner: boolean;
};

const CORAL = '#FF6B35';

/**
 * Brand-color picker with a live preview strip mimicking the player's
 * progress-pill matrix + prep countdown. The preview swaps a scoped
 * `--c-brand` CSS variable so the preview reads exactly what the
 * mobile + web player surfaces will read in Tasks 10-15.
 *
 * Surfaces a soft WCAG-AA tip when the chosen colour falls below 4.5:1
 * against the canonical dark surface (#0F1117). The save is still
 * allowed — Carl wants warning, not hard block.
 */
export function BrandColorPicker({ value, onChange, isOwner }: Props) {
  const active = value ?? CORAL;
  const isDefault = value === null;

  const contrast = useMemo(() => contrastAgainstDarkBg(active), [active]);
  const lowContrast = contrast < 4.5;

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-3">
        <input
          type="color"
          value={active}
          onChange={(e) => onChange(e.target.value.toUpperCase())}
          disabled={!isOwner}
          className="h-10 w-10 cursor-pointer rounded-md border border-surface-border bg-transparent disabled:cursor-not-allowed disabled:opacity-50"
          aria-label="Brand color"
        />
        <code className="text-sm text-ink">{active}</code>
        {!isDefault && isOwner && (
          <button
            type="button"
            onClick={() => onChange(null)}
            className="text-xs text-ink-muted underline decoration-dotted hover:text-brand"
          >
            Reset to coral
          </button>
        )}
      </div>
      {/* Live preview strip — mimics the player's pill matrix + countdown. */}
      <div
        className="rounded-lg border border-surface-border bg-surface-bg p-3"
        style={{ ['--c-brand' as string]: active } as React.CSSProperties}
      >
        <div className="mb-2 text-[10px] uppercase tracking-wide text-ink-muted">
          Live preview
        </div>
        <div className="flex items-center gap-1.5">
          {[0, 1, 2, 3, 4].map((i) => (
            <div
              key={i}
              className="h-2.5 flex-1 rounded-full"
              style={{
                background:
                  i < 2
                    ? 'var(--c-brand)'
                    : i === 2
                      ? 'transparent'
                      : 'rgba(255,255,255,0.08)',
                border:
                  i === 2
                    ? '2px solid var(--c-brand)'
                    : '1px solid rgba(255,255,255,0.06)',
              }}
            />
          ))}
        </div>
        <div className="mt-3 text-center text-xs">
          <div className="text-ink-muted">Workout starts in</div>
          <div
            className="text-3xl font-bold"
            style={{ color: 'var(--c-brand)' }}
          >
            5
          </div>
        </div>
      </div>
      {lowContrast && (
        <p className="text-xs text-ink-muted">
          Tip: this color may be hard to read on dark surfaces. Contrast{' '}
          {contrast.toFixed(1)}:1 is below the WCAG AA threshold (4.5:1). You
          can still save.
        </p>
      )}
    </div>
  );
}

// Relative luminance per WCAG 2.x.
function luminance(hex: string): number {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  const ch = (c: number) =>
    c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b);
}

function contrastAgainstDarkBg(hex: string): number {
  // Dark surface = #0F1117 → luminance ≈ 0.0066
  const L_bg = 0.0066;
  const L_fg = luminance(hex);
  const [lighter, darker] = L_fg > L_bg ? [L_fg, L_bg] : [L_bg, L_fg];
  return (lighter + 0.05) / (darker + 0.05);
}
