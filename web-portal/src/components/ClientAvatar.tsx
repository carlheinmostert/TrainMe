/**
 * ClientAvatar — Wave 40 P6 + P8.
 *
 * Compact circular avatar matching the mobile SessionCard / ClientCard
 * treatment. For now it renders the practitioner's initials over a
 * coral-tinted disc; once the portal RPC starts threading
 * `clients.avatar_path` (Wave 30 schema column, mobile-only writer
 * today) the image variant lights up automatically — pass the resolved
 * URL via `imageUrl` and the component will show the body-focus blur
 * crop instead of initials.
 *
 * Sizing:
 *   - `sm` (28px) — inline list rows
 *   - `md` (40px) — default; client list cards
 *   - `lg` (56px) — header / detail
 *
 * No emoji, no decorative SVG; one disc, one mono-spaced glyph. Keeps
 * the dashboard-flat brand language consistent across both surfaces.
 */
type Props = {
  /** Display name. Falls back to a single dash if blank/whitespace. */
  name: string;
  /** Body-focus avatar URL (Wave 30). When supplied, renders the image
   *  cropped into the disc; otherwise falls back to initials. */
  imageUrl?: string | null;
  /** Diameter token. Default 'md'. */
  size?: 'sm' | 'md' | 'lg';
  /** Optional title attribute override (defaults to the display name). */
  title?: string;
};

const SIZE_CLASS: Record<NonNullable<Props['size']>, string> = {
  sm: 'h-7 w-7 text-[10px]',
  md: 'h-10 w-10 text-xs',
  lg: 'h-14 w-14 text-base',
};

export function ClientAvatar({
  name,
  imageUrl,
  size = 'md',
  title,
}: Props) {
  const initials = computeInitials(name);
  const tooltip = title ?? name;
  const dim = SIZE_CLASS[size];

  if (imageUrl) {
    return (
      <span
        title={tooltip}
        className={`relative inline-flex shrink-0 overflow-hidden rounded-full border border-surface-border bg-surface-raised ${dim}`}
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={imageUrl}
          alt=""
          className="h-full w-full object-cover"
          loading="lazy"
        />
      </span>
    );
  }

  return (
    <span
      title={tooltip}
      aria-hidden="true"
      className={`inline-flex shrink-0 select-none items-center justify-center rounded-full border border-brand/40 bg-brand-tint-bg font-heading font-semibold uppercase tracking-wide text-brand ${dim}`}
    >
      {initials}
    </span>
  );
}

function computeInitials(name: string): string {
  const trimmed = (name ?? '').trim();
  if (!trimmed) return '–';
  // Up to 2 letters: first of first word + first of last word.
  const parts = trimmed.split(/\s+/).filter(Boolean);
  if (parts.length === 1) {
    return parts[0].charAt(0).toUpperCase();
  }
  const first = parts[0].charAt(0);
  const last = parts[parts.length - 1].charAt(0);
  return `${first}${last}`.toUpperCase();
}
