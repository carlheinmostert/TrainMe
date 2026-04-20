/**
 * PngPlaceholder — Phase 3 hook.
 *
 * Renders a neutral gray block at the 1080×1350 aspect ratio so the
 * `/network` layout is already accounting for the PNG share card
 * slot. Phase 3 replaces this component with a real CSS render (and
 * eventually a server-side PNG generator).
 *
 * Intentionally boring. No animations, no coral, no faux content. The
 * caption makes the unfinished state explicit so reviewers don't think
 * it's styled-but-broken.
 */
export function PngPlaceholder({ className }: { className?: string }) {
  return (
    <div className={className}>
      <div
        className="flex items-center justify-center rounded-xl border border-dashed border-surface-border bg-surface-raised/60 text-center"
        style={{ aspectRatio: '4 / 5' }}
        role="img"
        aria-label="PNG share card preview — coming in Phase 3"
      >
        <div className="px-6">
          <div className="font-mono text-[10px] uppercase tracking-wider text-ink-dim">
            1080 × 1350 · PNG
          </div>
          <p className="mt-2 font-heading text-sm font-semibold text-ink-muted">
            Share card preview
          </p>
          <p className="mt-1 text-xs text-ink-dim">
            Coming in Phase&nbsp;3
          </p>
        </div>
      </div>
    </div>
  );
}
