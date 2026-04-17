// Brand tokens shared across the portal. Mirror of:
//   app/lib/theme.dart          (Flutter)
//   web-player/styles.css :root  (web player)
// If you change a token here, sync it in the other two surfaces.

export const brand = {
  primary: '#FF6B35',
  primaryDark: '#E85A24',
  primaryLight: '#FF8F5E',
  primarySurface: '#FFF3ED',
} as const;

export const surface = {
  bg: '#0F1117',
  base: '#1A1D27',
  raised: '#242733',
  border: '#2E3140',
} as const;

export const ink = {
  primary: '#F0F0F5',
  muted: '#9CA3AF',
  dim: '#6B7280',
} as const;

export const semantic = {
  ok: '#22C55E',
  warn: '#F59E0B',
  err: '#EF4444',
  rest: '#64748B',
} as const;

// Pulse Mark path — heartbeat line tracing a house roof silhouette.
// Lifted from web-player/index.html so all surfaces render an identical mark.
export const PULSE_MARK_PATH =
  'M2.6 25.2 L13 25.2 L18.2 7.2 L26 28.8 L33.8 7.2 L39 25.2 L49.4 25.2';
export const PULSE_MARK_VIEWBOX = '0 0 52 36';
