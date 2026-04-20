import { HomefitLogo } from '@/components/HomefitLogo';

/**
 * OgPreview — WhatsApp unfurl visual reference.
 *
 * Shape mirrors the mockup's `.og-preview` block: a 1.91:1 hero tile
 * with the matrix logo + kicker/title/sub, plus a meta strip below
 * showing domain + title + description.
 *
 * **Not interactive.** Phase 1 keeps this as a static visual so the
 * practitioner sees what WhatsApp will render when the colleague
 * receives the link. The real OG card is served by the
 * `web-player/middleware.js` Edge Middleware — we don't duplicate that
 * pipeline here, we just mirror the look.
 */
export function OgPreview({
  kicker,
  title,
  sub,
}: {
  kicker: string;
  title: string;
  sub: string;
}) {
  return (
    <div
      className="overflow-hidden rounded-md border border-surface-border bg-surface-raised"
      aria-hidden="true"
    >
      {/* 1.91:1 image tile — coral radial glow + grid texture.
          Kept inline-styled for the gradients because Tailwind doesn't
          express radial gradients as atomic utilities. */}
      <div
        className="relative flex items-center gap-4 px-6 py-5"
        style={{
          aspectRatio: '1.91 / 1',
          background:
            'radial-gradient(120% 80% at 80% 20%, rgba(255, 107, 53, 0.22) 0%, rgba(255, 107, 53, 0.04) 40%, transparent 70%), linear-gradient(180deg, #131621 0%, #0F1117 100%)',
        }}
      >
        {/* Grid texture overlay — same idea as the mockup's ::before */}
        <div
          className="pointer-events-none absolute inset-0"
          style={{
            backgroundImage:
              'linear-gradient(rgba(255, 107, 53, 0.05) 1px, transparent 1px), linear-gradient(90deg, rgba(255, 107, 53, 0.05) 1px, transparent 1px)',
            backgroundSize: '24px 24px',
            maskImage:
              'linear-gradient(180deg, transparent, black 30%, black 70%, transparent)',
            WebkitMaskImage:
              'linear-gradient(180deg, transparent, black 30%, black 70%, transparent)',
          }}
        />

        <div
          className="relative flex-shrink-0"
          style={{
            width: 96,
            height: 19,
            filter: 'drop-shadow(0 0 8px rgba(255, 107, 53, 0.35))',
          }}
        >
          <HomefitLogo className="h-full w-full" />
        </div>

        <div className="relative z-10">
          <div className="text-[10px] font-semibold uppercase tracking-[1px] text-brand">
            {kicker}
          </div>
          <p className="mt-1 font-heading text-lg font-extrabold leading-tight tracking-tight text-ink">
            {title}
          </p>
          <p className="mt-1 text-[11px] text-ink-muted">{sub}</p>
        </div>
      </div>

      {/* Meta strip — domain + title + desc. Matches WhatsApp's two-line
          unfurl shape beneath the hero image. */}
      <div className="flex flex-col gap-0.5 border-t border-surface-border bg-surface-raised px-3.5 py-2.5">
        <div className="font-mono text-[10px] uppercase tracking-wider text-ink-dim">
          session.homefit.studio
        </div>
        <p className="text-sm font-semibold text-ink">
          homefit.studio — visual home programmes
        </p>
        <p className="text-[11px] text-ink-muted">
          Capture once. Share anywhere. Credits land when you sign up.
        </p>
      </div>
    </div>
  );
}
