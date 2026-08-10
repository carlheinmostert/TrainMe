/**
 * Shared chevron arrow used by dashboard tiles. Translates right on
 * parent hover/focus so practitioners get a consistent "clickable"
 * affordance across every tile.
 *
 * Pass `className` to control size. Callers use Tailwind size utilities
 * directly so JIT picks them up: DashboardTile uses `h-4 w-4`,
 * DashboardAuditCard uses `h-3.5 w-3.5`.
 */
export function ChevronRight({ className = 'h-4 w-4' }: { className?: string }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={`${className} text-ink-dim transition group-hover:translate-x-0.5 group-hover:text-brand group-focus-visible:translate-x-0.5 group-focus-visible:text-brand`}
      aria-hidden="true"
    >
      <polyline points="9 18 15 12 9 6" />
    </svg>
  );
}
